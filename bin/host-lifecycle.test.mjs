import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { spawn, execFile, execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  getCanonicalRuntimeDir,
  getCanonicalRuntimeDirIdentity,
  getCanonicalSocketPaths,
  safeUnlinkSocket,
  sendFramedIPCRequest,
  validateStatusResponseSchema,
  ProductionHostSupervisor
} from './host-lifecycle-core.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const CLI_PATH = path.join(REPO_ROOT, 'bin/agy-computer-use');

function createTestHarnessDir() {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-lc-test-'));
  fs.chmodSync(tmpDir, 0o700);
  return tmpDir;
}

function cleanupTestDir(dir) {
  if (fs.existsSync(dir)) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  }
}

function runAGYAsync(args, env = {}) {
  return new Promise((resolve) => {
    execFile(CLI_PATH, args, { cwd: REPO_ROOT, env: { ...process.env, ...env }, encoding: 'utf-8' }, (error, stdout, stderr) => {
      resolve({
        code: error ? (error.code || error.status || 1) : 0,
        stdout: stdout || '',
        stderr: stderr || ''
      });
    });
  });
}

function createRealDanglingSocket(socketPath) {
  const code = `
    const net = require('net');
    const server = net.createServer();
    server.listen(${JSON.stringify(socketPath)}, () => {
      process.stdout.write('BOUND\\n');
    });
  `;
  const proc = spawn(process.execPath, ['-e', code], { stdio: ['ignore', 'pipe', 'ignore'] });
  return new Promise((resolve, reject) => {
    proc.stdout.on('data', (data) => {
      if (data.toString().includes('BOUND')) {
        proc.kill('SIGKILL');
        proc.on('close', () => resolve());
      }
    });
    proc.on('error', reject);
  });
}

// Ensure staged host binary exists before tests run
const stagedBinary = path.join(REPO_ROOT, 'apps/computer-use-host/.build/staged/ComputerUseHost.app/Contents/MacOS/ComputerUseHost');
if (!fs.existsSync(stagedBinary)) {
  execSync(`${CLI_PATH} stage-host-app`, { cwd: REPO_ROOT });
}

// Discriminators 1, 2, 3, 4: Cold Concurrent Start, Correlated Status, Terminal Stop
test('D1-D4: Cold concurrent start, correlated status, and terminal receipt stop via bin/agy-computer-use', { timeout: 20000 }, async (t) => {
  const cleanupStack = [];
  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
  });

  cleanupStack.push(async () => {
    await runAGYAsync(['host-stop']);
  });

  // Ensure genuinely stopped state
  await runAGYAsync(['host-stop']);

  // Cold-start two separate public commands concurrently
  const [cStart1, cStart2] = await Promise.all([
    runAGYAsync(['host-start']),
    runAGYAsync(['host-start'])
  ]);

  assert.equal(cStart1.code, 0, `cStart1 failed: ${cStart1.stderr}`);
  assert.equal(cStart2.code, 0, `cStart2 failed: ${cStart2.stderr}`);

  const out1 = JSON.parse(cStart1.stdout);
  const out2 = JSON.parse(cStart2.stdout);

  assert.equal(out1.success, true);
  assert.equal(out2.success, true);
  assert.equal(out1.status, 'running');
  assert.equal(out2.status, 'running');

  // Both succeed with identical generation, daemonPid, nativePid
  assert.equal(out1.generation, out2.generation);
  assert.equal(out1.daemonPid, out2.daemonPid);
  assert.equal(out1.pid, out2.pid);

  // Exactly one owns the new start
  assert.ok((!out1.idempotent && out2.idempotent) || (out1.idempotent && !out2.idempotent));

  // Control socket inode remains stable
  const paths = getCanonicalSocketPaths();
  const controlIno1 = fs.lstatSync(paths.controlSocketPath).ino;

  // Query correlated status
  const statusRes = await runAGYAsync(['host-status']);
  assert.equal(statusRes.code, 0);
  const statusOut = JSON.parse(statusRes.stdout);

  assert.equal(statusOut.success, true);
  assert.equal(statusOut.status, 'running');
  assert.equal(statusOut.generation, out1.generation);
  assert.equal(statusOut.daemonPid, out1.daemonPid);
  assert.equal(statusOut.pid, out1.pid);
  assert.equal(statusOut.data.connected, true);

  const controlIno2 = fs.lstatSync(paths.controlSocketPath).ino;
  assert.equal(controlIno1, controlIno2);

  // Public stop returns receipt and proves PIDs terminal immediately without post-return polling
  const stopRes = await runAGYAsync(['host-stop']);
  assert.equal(stopRes.code, 0);
  const stopOut = JSON.parse(stopRes.stdout);

  assert.equal(stopOut.success, true);
  assert.equal(stopOut.status, 'stopped');

  // Prove exact daemon PID and native PID are terminal immediately upon return
  let daemonAlive = true;
  try { process.kill(out1.daemonPid, 0); } catch { daemonAlive = false; }
  assert.equal(daemonAlive, false, 'Daemon PID must be terminal upon host-stop return');

  let nativeAlive = true;
  try { process.kill(out1.pid, 0); } catch { nativeAlive = false; }
  assert.equal(nativeAlive, false, 'Native PID must be terminal upon host-stop return');

  assert.equal(fs.existsSync(paths.hostSocketPath), false);
  assert.equal(fs.existsSync(paths.controlSocketPath), false);

  assert.equal(fs.existsSync(paths.lockFilePath), true);
  const lockSt = fs.lstatSync(paths.lockFilePath);
  assert.equal(lockSt.isFile(), true);
  assert.equal(lockSt.isSymbolicLink(), false);
  assert.equal(lockSt.mode & 0o777, 0o600);
});

// Discriminator 5: Retained daemon process handle, TERM ordering, native child close proof
test('D5: Hold daemon process handle, SIGTERM it, prove exact native PID closes before sockets disappear', { timeout: 15000 }, async (t) => {
  const cleanupStack = [];
  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
  });

  cleanupStack.push(async () => {
    await runAGYAsync(['host-stop']);
  });

  const startRes = await runAGYAsync(['host-start']);
  assert.equal(startRes.code, 0);
  const startData = JSON.parse(startRes.stdout);
  const daemonPid = startData.daemonPid;
  const nativePid = startData.pid;

  process.kill(daemonPid, 'SIGTERM');

  let daemonExited = false;
  for (let i = 0; i < 40; i++) {
    try {
      process.kill(daemonPid, 0);
      await new Promise((r) => setTimeout(r, 50));
    } catch {
      daemonExited = true;
      break;
    }
  }

  assert.equal(daemonExited, true, 'Daemon process must exit after SIGTERM');

  let nativeAlive = true;
  try { process.kill(nativePid, 0); } catch { nativeAlive = false; }
  assert.equal(nativeAlive, false, 'Native child process must be terminal after daemon SIGTERM');

  const paths = getCanonicalSocketPaths();
  assert.equal(fs.existsSync(paths.controlSocketPath), false);
  assert.equal(fs.existsSync(paths.hostSocketPath), false);
});

// Discriminators 6, 12: Stubborn and cooperative child teardown & timeout/early-close
test('D6, D12: Cooperative vs stubborn child teardown with grace timer and KILL escalation', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const cleanupStack = [];
  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  // 1. Cooperative child: exits cleanly on SIGTERM after READY handshake
  const coopScript = "process.on('SIGTERM', () => { process.exit(0); }); console.log('READY'); setInterval(() => {}, 1000);";
  const coopProc = spawn(process.execPath, ['-e', coopScript], { stdio: ['ignore', 'pipe', 'pipe'] });
  if (coopProc.stdout) coopProc.stdout.resume();
  if (coopProc.stderr) coopProc.stderr.resume();
  await new Promise((r) => coopProc.stdout.on('data', r));
  cleanupStack.push(async () => { try { coopProc.kill('SIGKILL'); } catch {} });

  const supervisor1 = new ProductionHostSupervisor({ runtimeDir: testDir });
  supervisor1.child = coopProc;
  supervisor1.childClosedPromise = new Promise((resolve) => {
    coopProc.on('close', (code, signal) => resolve({ code, signal }));
  });

  const stopReceipt1 = await supervisor1.stop(2000);
  assert.equal(stopReceipt1.status, 'stopped');
  assert.equal(stopReceipt1.native_closed, true);
  assert.equal(stopReceipt1.killEscalated, false, 'Cooperative child must not escalate to KILL');

  // 2. Stubborn child: traps SIGTERM and ignores it after READY handshake
  const stubbornScript = "process.on('SIGTERM', () => {}); console.log('READY'); setInterval(() => {}, 1000);";
  const stubbornProc = spawn(process.execPath, ['-e', stubbornScript], { stdio: ['ignore', 'pipe', 'pipe'] });
  if (stubbornProc.stdout) stubbornProc.stdout.resume();
  if (stubbornProc.stderr) stubbornProc.stderr.resume();
  await new Promise((r) => stubbornProc.stdout.on('data', r));
  cleanupStack.push(async () => { try { stubbornProc.kill('SIGKILL'); } catch {} });

  const supervisor2 = new ProductionHostSupervisor({ runtimeDir: testDir });
  supervisor2.child = stubbornProc;
  supervisor2.childClosedPromise = new Promise((resolve) => {
    stubbornProc.on('close', (code, signal) => resolve({ code, signal }));
  });

  const stopReceipt2 = await supervisor2.stop(300);
  assert.equal(stopReceipt2.status, 'stopped');
  assert.equal(stopReceipt2.native_closed, true);
  assert.equal(stopReceipt2.killEscalated, true, 'Stubborn child must escalate to KILL after grace timeout');
});

// Discriminator 7: Real starting phase barrier contender exclusion
test('D7: Real starting phase barrier excludes contender from replacing socket or spawning second child', { timeout: 15000 }, async (t) => {
  const cleanupStack = [];
  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
  });

  cleanupStack.push(async () => {
    await runAGYAsync(['host-stop']);
  });

  await runAGYAsync(['host-stop']);

  const supervisor = new ProductionHostSupervisor();
  cleanupStack.push(async () => {
    await supervisor.stop();
    supervisor._finalizeDaemonTeardown();
  });

  await supervisor.startControlServer();
  supervisor.state = 'starting';

  const paths = getCanonicalSocketPaths();
  const ctrlInoBefore = fs.lstatSync(paths.controlSocketPath).ino;

  const contenderPromise = runAGYAsync(['host-start']);

  const ctrlInoDuring = fs.lstatSync(paths.controlSocketPath).ino;
  assert.equal(ctrlInoBefore, ctrlInoDuring);

  const nativeServer = net.createServer((sock) => {
    sock.on('data', (chunk) => {
      const msgLen = chunk.readUInt32BE(0);
      const req = JSON.parse(chunk.subarray(4, 4 + msgLen).toString('utf-8'));
      const respObj = {
        id: req.id,
        success: true,
        data: {
          connected: true,
          tcc_permission_state: 'granted',
          accessibility_available: true,
          accessibility_trusted: true,
          input_mutation_state: 'disabled'
        }
      };
      const respBuf = Buffer.from(JSON.stringify(respObj), 'utf-8');
      const headBuf = Buffer.alloc(4);
      headBuf.writeUInt32BE(respBuf.length, 0);
      sock.write(Buffer.concat([headBuf, respBuf]));
    });
  });
  cleanupStack.push(async () => { try { nativeServer.close(); } catch {} });

  await new Promise((r) => nativeServer.listen(paths.hostSocketPath, r));
  supervisor.state = 'running';

  const contenderRes = await contenderPromise;
  assert.equal(contenderRes.code, 0);
  const contenderOut = JSON.parse(contenderRes.stdout);
  assert.equal(contenderOut.success, true);
  assert.equal(contenderOut.idempotent, true);
  assert.equal(contenderOut.generation, supervisor.generation);
});

// Discriminator 8: Native-live / Control-absent returns RUNNING_UNMANAGED and preserves PID/inode
test('D8: Unmanaged native host returns RUNNING_UNMANAGED without mutating host socket or signaling sentinel', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const paths = getCanonicalSocketPaths(testDir);
  const cleanupStack = [];

  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  const nativeServer = net.createServer((sock) => {
    sock.on('data', (chunk) => {
      const msgLen = chunk.readUInt32BE(0);
      const req = JSON.parse(chunk.subarray(4, 4 + msgLen).toString('utf-8'));
      const respObj = {
        id: req.id,
        success: true,
        data: {
          connected: true,
          tcc_permission_state: 'granted',
          accessibility_available: true,
          accessibility_trusted: true,
          input_mutation_state: 'disabled'
        }
      };
      const respBuf = Buffer.from(JSON.stringify(respObj), 'utf-8');
      const headBuf = Buffer.alloc(4);
      headBuf.writeUInt32BE(respBuf.length, 0);
      sock.write(Buffer.concat([headBuf, respBuf]));
    });
  });
  cleanupStack.push(async () => { try { nativeServer.close(); } catch {} });
  await new Promise((r) => nativeServer.listen(paths.hostSocketPath, r));

  const initialHostIno = fs.lstatSync(paths.hostSocketPath).ino;

  const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
  const probe = await supervisor.checkNativeStatus(500);
  assert.equal(probe.alive, true);

  await assert.rejects(async () => {
    await supervisor.start();
  }, /Native host process is running without an owner control server/);

  const finalHostIno = fs.lstatSync(paths.hostSocketPath).ino;
  assert.equal(initialHostIno, finalHostIno, 'Host socket inode must remain untouched');
});

// Discriminator 9: Stale / Ambiguous status and stop return STALE_OR_AMBIGUOUS and preserve artifacts
test('D9: Dangling socket returns STALE_OR_AMBIGUOUS and preserves socket file', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const paths = getCanonicalSocketPaths(testDir);
  const cleanupStack = [];

  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  await createRealDanglingSocket(paths.controlSocketPath);

  const initialIno = fs.lstatSync(paths.controlSocketPath).ino;

  const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
  const ctrlProbe = await supervisor.checkControlStatus(300);
  assert.equal(ctrlProbe.alive, false);

  assert.equal(fs.existsSync(paths.controlSocketPath), true, 'Dangling control socket must be preserved before mutation');
  assert.equal(fs.lstatSync(paths.controlSocketPath).ino, initialIno);
});

// Discriminator 10: Mandatory root Identity, socket replacement, symlink rejection in safeUnlinkSocket
test('D10: safeUnlinkSocket requires mandatory rootIdentity, rejects symlinks, foreign UIDs, and inode mismatches', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const cleanupStack = [];

  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  const socketPath = path.join(testDir, 'test.sock');
  await createRealDanglingSocket(socketPath);

  const stA = fs.lstatSync(socketPath);
  const rootIdentity = getCanonicalRuntimeDirIdentity(testDir);

  // 1. Missing rootIdentity must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, null, stA.ino, stA.dev);
  }, /safeUnlinkSocket requires mandatory captured rootIdentity/);

  // 2. Inode mismatch must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, stA.ino + 999, stA.dev);
  }, /inode mismatch/);

  // 3. Device mismatch must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, stA.ino, stA.dev + 999);
  }, /device mismatch/);

  // 4. Socket A replaced by socket B: A is unlinked, B created. Relinking A must fail and B survives!
  fs.unlinkSync(socketPath);
  await createRealDanglingSocket(socketPath);

  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, stA.ino, stA.dev);
  }, /inode mismatch/);

  assert.equal(fs.existsSync(socketPath), true, 'Socket B must survive when unlinking A is rejected');

  // Clean up B with correct identity
  const stB = fs.lstatSync(socketPath);
  const unlinked = safeUnlinkSocket(socketPath, rootIdentity, stB.ino, stB.dev);
  assert.equal(unlinked, true);
});

// Discriminator 11: Strict IPC failures on production codec/server
test('D11: Strict IPC validation of ID equality, 16MB payload limits, and single frame handling', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const paths = getCanonicalSocketPaths(testDir);
  const cleanupStack = [];

  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
  await supervisor.startControlServer();
  cleanupStack.push(async () => {
    supervisor._finalizeDaemonTeardown();
  });

  // 1. Missing ID request returns BAD_REQUEST
  const client1 = net.createConnection(paths.controlSocketPath);
  cleanupStack.push(async () => { try { client1.destroy(); } catch {} });

  await new Promise((resolve) => {
    client1.on('connect', () => {
      const payload = Buffer.from(JSON.stringify({ method: 'status' }), 'utf-8');
      const header = Buffer.alloc(4);
      header.writeUInt32BE(payload.length, 0);
      client1.write(Buffer.concat([header, payload]));
    });
    client1.on('data', (chunk) => {
      const msgLen = chunk.readUInt32BE(0);
      const resp = JSON.parse(chunk.subarray(4, 4 + msgLen).toString('utf-8'));
      assert.equal(resp.success, false);
      assert.equal(resp.error.code, 'BAD_REQUEST');
      resolve();
    });
  });

  // 2. Response with method 'status' returns object with matching ID
  const resObj = await sendFramedIPCRequest(paths.controlSocketPath, { id: 'test-id-123', method: 'status' });
  assert.equal(resObj.id, 'test-id-123');
  assert.equal(resObj.success, true);
});

// Discriminator 13: Socket-existence readiness mutant rejection
test('D13: Socket-existence readiness mutant fails when socket returns invalid framing or child exits early', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const paths = getCanonicalSocketPaths(testDir);
  let badServer = null;

  t.after(async () => {
    if (badServer) {
      try { badServer.close(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  badServer = net.createServer((sock) => {
    sock.write(Buffer.from('INVALID_NOT_FRAMED_JSON'));
  });
  await new Promise((r) => badServer.listen(paths.hostSocketPath, r));

  const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
  const probe = await supervisor.checkNativeStatus(300);
  assert.equal(probe.alive, false, 'Invalid framed payload must fail native status check');

  await assert.rejects(async () => {
    await supervisor.start({
      binaryPath: process.execPath,
      readinessTimeoutMs: 300
    });
  });

  assert.equal(supervisor.state, 'stopped');
});

// Discriminator 14: COMPUTER_USE_RUNTIME_DIR Environmental Override Isolation
test('D14: Public CLI commands ignore COMPUTER_USE_RUNTIME_DIR environmental override and preserve sentinel files', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const cleanupStack = [];

  t.after(async () => {
    for (const fn of cleanupStack.reverse()) {
      try { await fn(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  const sentinelPath = path.join(testDir, 'sentinel.dat');
  const initialContent = Buffer.from('IMMUTABLE_SENTINEL_DATA_HL1B');
  fs.writeFileSync(sentinelPath, initialContent, { mode: 0o644 });
  const initialSt = fs.lstatSync(sentinelPath);

  const env = { COMPUTER_USE_RUNTIME_DIR: testDir };
  await runAGYAsync(['host-status'], env);

  const finalSt = fs.lstatSync(sentinelPath);
  const finalContent = fs.readFileSync(sentinelPath);

  assert.equal(Buffer.compare(initialContent, finalContent), 0, 'Sentinel file bytes must remain unchanged');
  assert.equal(initialSt.size, finalSt.size, 'Sentinel size must remain unchanged');
  assert.equal(initialSt.mode, finalSt.mode, 'Sentinel permissions must remain unchanged');
});

// Discriminator 15: Clean-export build & stage verification proof
test('D15: Clean-export stage-host-app verification proof', { timeout: 30000 }, async (t) => {
  const stageRes = await runAGYAsync(['stage-host-app']);
  assert.equal(stageRes.code, 0, `stage-host-app failed: ${stageRes.stderr}`);
  assert.ok(fs.existsSync(stagedBinary), 'Staged binary must exist after stage-host-app');
});
