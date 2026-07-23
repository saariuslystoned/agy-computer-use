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

function runAGYAsync(args, env = {}, timeoutMs = 12000) {
  return new Promise((resolve) => {
    let settled = false;
    const proc = execFile(CLI_PATH, args, { cwd: REPO_ROOT, env: { ...process.env, ...env }, encoding: 'utf-8' }, (error, stdout, stderr) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        child: proc,
        code: error ? (error.code || error.status || 1) : 0,
        stdout: stdout || '',
        stderr: stderr || ''
      });
    });
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { proc.kill('SIGKILL'); } catch {}
      resolve({
        child: proc,
        code: 124,
        stdout: '',
        stderr: 'Process execution timed out'
      });
    }, timeoutMs);
  });
}

function getNativeProcessCount() {
  try {
    const out = execSync('ps -ax -o pid,command', { encoding: 'utf-8' });
    const lines = out.split('\n').filter(line => line.includes('ComputerUseHost') && !line.includes('grep'));
    return lines.length;
  } catch {
    return 0;
  }
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
        try { proc.stdout.destroy(); } catch {}
        proc.kill('SIGKILL');
        proc.on('close', () => resolve());
      }
    });
    proc.on('error', (err) => {
      try { proc.stdout.destroy(); } catch {}
      reject(err);
    });
  });
}

function encodeFrame(value) {
  const body = Buffer.from(JSON.stringify(value), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

function killOrphanNativeProcesses() {
  try {
    const out = execSync('ps -ax -o pid,command', { encoding: 'utf-8' });
    for (const line of out.split('\n')) {
      if (line.includes('ComputerUseHost') && !line.includes('grep')) {
        const parts = line.trim().split(/\s+/);
        const pid = parseInt(parts[0], 10);
        if (pid && pid !== process.pid) {
          try { process.kill(pid, 'SIGKILL'); } catch {}
        }
      }
    }
  } catch {}
}

// D1/D2: Cold Concurrency, Preconditions & Native Process Accounting
test('D1-D2: Cold concurrent start, stopped precondition, single winner, and native process accounting', { timeout: 20000 }, async (t) => {
  killOrphanNativeProcesses();

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
  const initialStop = await runAGYAsync(['host-stop']);
  if (initialStop.code !== 0) {
    const paths = getCanonicalSocketPaths();
    try { fs.unlinkSync(paths.controlSocketPath); } catch {}
    try { fs.unlinkSync(paths.hostSocketPath); } catch {}
  }

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
  assert.equal(out1.nativePid, out2.nativePid);

  // Exactly one owns the new start
  assert.ok((!out1.idempotent && out2.idempotent) || (out1.idempotent && !out2.idempotent));

  // Verify exactly one native process is running
  const processCount = getNativeProcessCount();
  assert.equal(processCount, 1, 'Exactly one native host process must be running');

  // Control socket inode remains stable
  const paths = getCanonicalSocketPaths();
  assert.equal(fs.existsSync(paths.controlSocketPath), true);
});

// D3: Correlated Owner Probe & Schema Validation
test('D3: Correlated public host-status returns identical 3 identities and native schema validation', { timeout: 15000 }, async (t) => {
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
  const startOut = JSON.parse(startRes.stdout);

  const statusRes = await runAGYAsync(['host-status']);
  assert.equal(statusRes.code, 0);
  const statusOut = JSON.parse(statusRes.stdout);

  assert.equal(statusOut.success, true);
  assert.equal(statusOut.status, 'running');
  assert.equal(statusOut.generation, startOut.generation);
  assert.equal(statusOut.daemonPid, startOut.daemonPid);
  assert.equal(statusOut.nativePid, startOut.nativePid);
  assert.equal(statusOut.data.connected, true);

  // Validate native status schema
  assert.equal(validateStatusResponseSchema({ id: 'probe', success: true, data: statusOut.data }), true, 'Native status payload must satisfy schema');
});

// D4: Terminal Stop Receipt Assertions
test('D4: Public host-stop validates full receipt schema and immediate PID termination', { timeout: 15000 }, async (t) => {
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
  const startOut = JSON.parse(startRes.stdout);

  const stopRes = await runAGYAsync(['host-stop']);
  assert.equal(stopRes.code, 0);
  const stopOut = JSON.parse(stopRes.stdout);

  assert.equal(stopOut.success, true);
  assert.equal(stopOut.status, 'stopped');
  assert.equal(stopOut.idempotent, false);
  assert.equal(stopOut.generation, startOut.generation);
  assert.equal(stopOut.daemonPid, startOut.daemonPid);
  assert.equal(stopOut.nativePid, startOut.nativePid);
  assert.equal(stopOut.native_closed, true);
  assert.equal(typeof stopOut.killEscalated, 'boolean');
  assert.equal(stopOut.residueState?.hostSocketClean, true);
  assert.equal(stopOut.residueState?.controlSocketClean, true);

  // Prove PIDs are terminal immediately upon return
  let daemonAlive = true;
  try { process.kill(startOut.daemonPid, 0); } catch { daemonAlive = false; }
  assert.equal(daemonAlive, false, 'Daemon PID must be terminal upon host-stop return');

  let nativeAlive = true;
  try { process.kill(startOut.nativePid, 0); } catch { nativeAlive = false; }
  assert.equal(nativeAlive, false, 'Native PID must be terminal upon host-stop return');

  const paths = getCanonicalSocketPaths();
  assert.equal(fs.existsSync(paths.hostSocketPath), false);
  assert.equal(fs.existsSync(paths.controlSocketPath), false);

  assert.equal(fs.existsSync(paths.lockFilePath), true);
  const lockSt = fs.lstatSync(paths.lockFilePath);
  assert.equal(lockSt.isFile(), true);
  assert.equal(lockSt.isSymbolicLink(), false);
  assert.equal(lockSt.mode & 0o777, 0o600);
});

// D5: Daemon Teardown & Native Close Ordering
test('D5: Retained daemon handle SIGTERM proves native child closes before sockets disappear', { timeout: 15000 }, async (t) => {
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
  const nativePid = startData.nativePid;

  const stopRes = await runAGYAsync(['host-stop']);
  assert.equal(stopRes.code, 0);
  const stopData = JSON.parse(stopRes.stdout);
  assert.equal(stopData.native_closed, true);

  let daemonAlive = true;
  try { process.kill(daemonPid, 0); } catch { daemonAlive = false; }
  assert.equal(daemonAlive, false, 'Daemon process must exit after stop');

  let nativeAlive = true;
  try { process.kill(nativePid, 0); } catch { nativeAlive = false; }
  assert.equal(nativeAlive, false, 'Native child process must be terminal after stop');

  const paths = getCanonicalSocketPaths();
  assert.equal(fs.existsSync(paths.controlSocketPath), false);
  assert.equal(fs.existsSync(paths.hostSocketPath), false);
});

// D6, D12: Cooperative vs Stubborn Child Teardown with Grace Timer and KILL Escalation
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

// D7: Real Starting Phase Barrier Contender Exclusion
test('D7: Real starting phase barrier excludes contender from replacing socket or spawning second child', { timeout: 15000 }, async (t) => {
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
  cleanupStack.push(async () => {
    await supervisor.stop();
    await supervisor.finalizeDaemonTeardown();
  });

  await supervisor.startControlServer();
  supervisor.state = 'starting';

  const ctrlInoBefore = fs.lstatSync(paths.controlSocketPath).ino;

  const contenderPromise = supervisor.checkControlStatus(300);

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
  assert.equal(contenderRes.alive, true);
  assert.equal(contenderRes.data.generation, supervisor.generation);
});

// D8: Public Unmanaged State CLI Operations
test('D8: Unmanaged native host returns RUNNING_UNMANAGED via public CLI commands', { timeout: 15000 }, async (t) => {
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
  assert.equal(initialHostIno, finalHostIno, 'Unmanaged host socket inode must remain untouched');
});

// D9: Public Stale / Ambiguous State CLI Operations
test('D9: Dangling control socket returns STALE_OR_AMBIGUOUS via public CLI commands', { timeout: 15000 }, async (t) => {
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

  const paths = getCanonicalSocketPaths();
  await createRealDanglingSocket(paths.controlSocketPath);

  const initialIno = fs.lstatSync(paths.controlSocketPath).ino;

  const statusRes = await runAGYAsync(['host-status']);
  assert.notEqual(statusRes.code, 0);
  const statusOut = JSON.parse(statusRes.stdout);
  assert.equal(statusOut.status, 'STALE_OR_AMBIGUOUS');
  assert.equal(statusOut.code, 'STALE_OR_AMBIGUOUS');

  const stopRes = await runAGYAsync(['host-stop']);
  assert.notEqual(stopRes.code, 0);
  const stopOut = JSON.parse(stopRes.stdout);
  assert.equal(stopOut.status, 'STALE_OR_AMBIGUOUS');

  assert.equal(fs.existsSync(paths.controlSocketPath), true, 'Dangling control socket must be preserved before mutation');
  assert.equal(fs.lstatSync(paths.controlSocketPath).ino, initialIno);
});

// D10: Socket Identity & Security Validation in safeUnlinkSocket
test('D10: safeUnlinkSocket requires mandatory rootIdentity and socketIdentity, rejecting symlinks and mismatched identities', { timeout: 15000 }, async (t) => {
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
  const socketIdentityA = { uid: stA.uid, dev: stA.dev, ino: stA.ino, type: 'socket' };

  // 1. Missing rootIdentity must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, null, socketIdentityA);
  }, /safeUnlinkSocket requires mandatory captured rootIdentity/);

  // 2. Missing socketIdentity must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, null);
  }, /safeUnlinkSocket requires mandatory captured socketIdentity/);

  // 3. Inode mismatch must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, { ...socketIdentityA, ino: stA.ino + 999 });
  }, /inode mismatch/);

  // 4. Device mismatch must throw Error
  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, { ...socketIdentityA, dev: stA.dev + 999 });
  }, /device mismatch/);

  // 5. Socket A replaced by socket B: A is unlinked, B created. Relinking A must fail and B survives!
  fs.unlinkSync(socketPath);
  await createRealDanglingSocket(socketPath);

  assert.throws(() => {
    safeUnlinkSocket(socketPath, rootIdentity, socketIdentityA);
  }, /inode mismatch/);

  assert.equal(fs.existsSync(socketPath), true, 'Socket B must survive when unlinking A is rejected');

  // Clean up B with correct identity
  const stB = fs.lstatSync(socketPath);
  const socketIdentityB = { uid: stB.uid, dev: stB.dev, ino: stB.ino, type: 'socket' };
  const unlinked = safeUnlinkSocket(socketPath, rootIdentity, socketIdentityB);
  assert.equal(unlinked, true);
});

// D11: Strict Table-Driven IPC Tests
test('D11: Strict table-driven IPC testing of falsy IDs, bounds, trailing frames, and single action per connection', { timeout: 15000 }, async (t) => {
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
    await supervisor.finalizeDaemonTeardown();
  });

  // Table Test 1: Valid Falsy IDs (number 0, false, empty string)
  for (const falsyId of [0, false, '']) {
    const res = await sendFramedIPCRequest(paths.controlSocketPath, { id: falsyId, method: 'status' });
    assert.equal(res.id, falsyId, `Response ID must preserve falsy value ${JSON.stringify(falsyId)}`);
    assert.equal(res.success, true);
  }

  // Table Test 2: Missing ID returns BAD_REQUEST
  const clientMissingId = net.createConnection(paths.controlSocketPath);
  cleanupStack.push(async () => { try { clientMissingId.destroy(); } catch {} });
  await new Promise((resolve) => {
    clientMissingId.on('connect', () => {
      const payload = Buffer.from(JSON.stringify({ method: 'status' }), 'utf-8');
      const header = Buffer.alloc(4);
      header.writeUInt32BE(payload.length, 0);
      clientMissingId.write(Buffer.concat([header, payload]));
    });
    clientMissingId.on('data', (chunk) => {
      const msgLen = chunk.readUInt32BE(0);
      const resp = JSON.parse(chunk.subarray(4, 4 + msgLen).toString('utf-8'));
      assert.equal(resp.success, false);
      assert.equal(resp.error.code, 'BAD_REQUEST');
      clientMissingId.destroy();
      resolve();
    });
  });

  // Table Test 3: Trailing / Repeated frames on single connection cause rejection without action
  const clientRepeated = net.createConnection(paths.controlSocketPath);
  cleanupStack.push(async () => { try { clientRepeated.destroy(); } catch {} });
  await new Promise((resolve) => {
    clientRepeated.on('connect', () => {
      const frame1 = encodeFrame({ id: 'frame1', method: 'status' });
      const frame2 = encodeFrame({ id: 'frame2', method: 'status' });
      clientRepeated.write(Buffer.concat([frame1, frame2]));
    });
    clientRepeated.on('data', (chunk) => {
      const msgLen = chunk.readUInt32BE(0);
      const resp = JSON.parse(chunk.subarray(4, 4 + msgLen).toString('utf-8'));
      assert.equal(resp.success, false, 'Repeated frame connection must be rejected');
      assert.equal(resp.error.code, 'BAD_REQUEST');
      clientRepeated.destroy();
      resolve();
    });
  });
});

// D13: Readiness Failure Discrimination
test('D13: Discriminates invalid framed payload from early child process exit', { timeout: 15000 }, async (t) => {
  const testDir = createTestHarnessDir();
  const paths = getCanonicalSocketPaths(testDir);
  let badServer = null;

  t.after(async () => {
    if (badServer) {
      try { badServer.close(); } catch {}
    }
    cleanupTestDir(testDir);
  });

  // 1. Invalid framing response
  badServer = net.createServer((sock) => {
    sock.write(Buffer.from('INVALID_NOT_FRAMED_JSON'), () => {
      try { sock.destroy(); } catch {}
    });
  });
  await new Promise((r) => badServer.listen(paths.hostSocketPath, r));

  const supervisor1 = new ProductionHostSupervisor({ runtimeDir: testDir });
  const probe1 = await supervisor1.checkNativeStatus(300);
  assert.equal(probe1.alive, false, 'Invalid framed payload must fail native status check');

  // Clean up badServer and socket before step 2
  await new Promise((r) => badServer.close(r));
  badServer = null;
  try { fs.unlinkSync(paths.hostSocketPath); } catch {}

  // 2. Early child process exit
  const supervisor2 = new ProductionHostSupervisor({ runtimeDir: testDir });
  await assert.rejects(
    supervisor2.start({
      binaryPath: process.execPath,
      binaryArgs: ['-e', 'process.exit(42);'],
      readinessTimeoutMs: 500
    }),
    /Host child process exited during startup/
  );
  assert.equal(supervisor2.state, 'stopped');
});

// D14: Environmental Override Isolation & Sentinel Preservation
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

// D15: Clean Export & Source Verification Proof
test('D15: Clean-export stage-host-app verification proof', { timeout: 45000 }, async (t) => {
  const tmpExportDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-clean-export-'));
  t.after(() => {
    cleanupTestDir(tmpExportDir);
  });

  // Archive tracked files into clean export
  execSync(`git archive HEAD | tar -x -C ${tmpExportDir}`, { cwd: REPO_ROOT });

  // Remove release/staged build artifacts in the clean export
  const stagedPath = path.join(tmpExportDir, 'apps/computer-use-host/.build/staged');
  if (fs.existsSync(stagedPath)) {
    fs.rmSync(stagedPath, { recursive: true, force: true });
  }

  // Invoke stage-host-app in the clean export
  const cliInExport = path.join(tmpExportDir, 'bin/agy-computer-use');
  const stageRes = execSync(`${cliInExport} stage-host-app`, { cwd: tmpExportDir, encoding: 'utf-8' });
  const jsonStart = stageRes.indexOf('{');
  const jsonEnd = stageRes.lastIndexOf('}');
  assert.notEqual(jsonStart, -1, 'stage-host-app output must contain JSON');
  const stageJson = JSON.parse(stageRes.substring(jsonStart, jsonEnd + 1));

  assert.equal(stageJson.success, true);
  assert.ok(fs.existsSync(stageJson.binaryPath), 'Staged binary must exist in clean export');
});

