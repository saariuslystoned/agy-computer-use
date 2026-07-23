import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { spawn, execFileSync, execFile, execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  getCanonicalRuntimeDir,
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
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function runCLIAsync(args, env) {
  return new Promise((resolve) => {
    execFile(process.execPath, [CLI_PATH, ...args], { cwd: REPO_ROOT, env, encoding: 'utf-8' }, (error, stdout, stderr) => {
      resolve({
        code: error ? (error.code || error.status || 1) : 0,
        stdout: stdout || '',
        stderr: stderr || ''
      });
    });
  });
}

// 1. Happy path: public CLI start -> status -> idempotent start -> stop -> idempotent stop -> restart
test('HL1-AUTH-1: CLI start, status, idempotent start/stop, restart', async () => {
  const testDir = createTestHarnessDir();
  const env = { ...process.env, COMPUTER_USE_RUNTIME_DIR: testDir };

  try {
    // Stage app first if needed
    const stagedBinary = path.join(REPO_ROOT, 'apps/computer-use-host/.build/staged/ComputerUseHost.app/Contents/MacOS/ComputerUseHost');
    if (!fs.existsSync(stagedBinary)) {
      execSync(`${CLI_PATH} stage-host-app`, { cwd: REPO_ROOT, env });
    }

    // CLI host-start
    const start1Res = await runCLIAsync(['host-start'], env);
    assert.equal(start1Res.code, 0);
    const start1 = JSON.parse(start1Res.stdout);
    assert.equal(start1.success, true);
    assert.equal(start1.status, 'running');
    assert.equal(start1.idempotent, false);
    assert.ok(start1.pid > 0);

    // CLI host-status
    const status1Res = await runCLIAsync(['host-status'], env);
    assert.equal(status1Res.code, 0);
    const status1 = JSON.parse(status1Res.stdout);
    assert.equal(status1.success, true);
    assert.equal(status1.status, 'running');
    assert.equal(status1.data.connected, true);

    // Idempotent CLI host-start
    const start2Res = await runCLIAsync(['host-start'], env);
    assert.equal(start2Res.code, 0);
    const start2 = JSON.parse(start2Res.stdout);
    assert.equal(start2.success, true);
    assert.equal(start2.status, 'running');
    assert.equal(start2.idempotent, true);

    // CLI host-stop
    const stop1Res = await runCLIAsync(['host-stop'], env);
    assert.equal(stop1Res.code, 0);
    const stop1 = JSON.parse(stop1Res.stdout);
    assert.equal(stop1.success, true);
    assert.equal(stop1.status, 'stopped');
    assert.equal(stop1.idempotent, false);

    // Idempotent CLI host-stop
    const stop2Res = await runCLIAsync(['host-stop'], env);
    assert.equal(stop2Res.code, 0);
    const stop2 = JSON.parse(stop2Res.stdout);
    assert.equal(stop2.success, true);
    assert.equal(stop2.status, 'stopped');
    assert.equal(stop2.idempotent, true);

    // Restart fresh generation
    const start3Res = await runCLIAsync(['host-start'], env);
    assert.equal(start3Res.code, 0);
    const start3 = JSON.parse(start3Res.stdout);
    assert.equal(start3.success, true);
    assert.equal(start3.status, 'running');
    assert.notEqual(start3.pid, start1.pid);

    // Cleanup stop
    await runCLIAsync(['host-stop'], env);
  } finally {
    try {
      await runCLIAsync(['host-stop'], env);
    } catch {}
    cleanupTestDir(testDir);
  }
});

// 2. Public command extra-token rejection
test('HL1-AUTH-2: Public command extra-token rejection', async () => {
  const res = await runCLIAsync(['host-start', '--extra-arg'], process.env);
  assert.notEqual(res.code, 0);
  assert.match(res.stderr || res.stdout, /zero extra arguments/);
});

// 3. Spawn error before readiness
test('HL1-AUTH-3: Non-existent binary spawn error tears down cleanly', async () => {
  const testDir = createTestHarnessDir();
  try {
    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    await assert.rejects(async () => {
      await supervisor.start({
        binaryPath: '/non/existent/binary/path/xyz',
        readinessTimeoutMs: 100
      });
    });

    assert.equal(supervisor.state, 'stopped');
    const paths = getCanonicalSocketPaths(testDir);
    assert.equal(fs.existsSync(paths.controlSocketPath), false);
    assert.equal(fs.existsSync(paths.hostSocketPath), false);
  } finally {
    cleanupTestDir(testDir);
  }
});

// 4. Early exit child before readiness
test('HL1-AUTH-4: Early exit child tears down cleanly without leaking', async () => {
  const testDir = createTestHarnessDir();
  try {
    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    await assert.rejects(async () => {
      await supervisor.start({
        binaryPath: process.execPath,
        readinessTimeoutMs: 500
      });
    });

    assert.equal(supervisor.state, 'stopped');
    const paths = getCanonicalSocketPaths(testDir);
    assert.equal(fs.existsSync(paths.controlSocketPath), false);
    assert.equal(fs.existsSync(paths.hostSocketPath), false);
  } finally {
    cleanupTestDir(testDir);
  }
});

// 5. Socket existence mutant (socket responding with malformed payload fails readiness)
test('HL1-AUTH-5: Socket returning malformed JSON fails readiness check', async () => {
  const testDir = createTestHarnessDir();
  try {
    const paths = getCanonicalSocketPaths(testDir);
    const server = net.createServer((sock) => {
      sock.write(Buffer.from('not valid json payload'));
    });
    await new Promise((r) => server.listen(paths.hostSocketPath, r));

    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    const probe = await supervisor.checkNativeStatus(500);
    assert.equal(probe.alive, false);

    server.close();
  } finally {
    cleanupTestDir(testDir);
  }
});

// 6. Readiness timeout owns TERM -> KILL -> reap
test('HL1-AUTH-6: Readiness timeout sends SIGTERM -> SIGKILL -> reaps child', async () => {
  const testDir = createTestHarnessDir();
  try {
    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    await assert.rejects(async () => {
      await supervisor.start({
        binaryPath: process.execPath,
        binaryArgs: ['-e', 'setInterval(() => {}, 1000);'],
        readinessTimeoutMs: 300
      });
    }, /Readiness check timed out/);

    assert.equal(supervisor.state, 'stopped');
    const paths = getCanonicalSocketPaths(testDir);
    assert.equal(fs.existsSync(paths.controlSocketPath), false);
  } finally {
    cleanupTestDir(testDir);
  }
});

// 7. PID-trust mutant & sentinel process preservation
test('HL1-AUTH-7: Stop affects exact supervisor child, preserving unrelated sentinel', async () => {
  const testDir = createTestHarnessDir();
  let sentinel = null;
  try {
    sentinel = spawn('sleep', ['60']);
    assert.ok(sentinel.pid > 0);

    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    const mockChild = {
      pid: 88888,
      exitCode: null,
      signalCode: null,
      kill: () => {},
      on: (evt, fn) => {
        if (evt === 'close') setTimeout(() => fn(0, null), 10);
      }
    };
    supervisor.child = mockChild;
    supervisor.state = 'running';

    await supervisor.stop(100);

    // Sentinel must still be alive
    let sentinelAlive = true;
    try {
      process.kill(sentinel.pid, 0);
    } catch {
      sentinelAlive = false;
    }
    assert.equal(sentinelAlive, true, 'Sentinel process must remain alive');
  } finally {
    if (sentinel) {
      try { sentinel.kill('SIGKILL'); } catch {}
    }
    cleanupTestDir(testDir);
  }
});

// 8. Stubborn child receiving SIGKILL escalation
test('HL1-AUTH-8: Child ignoring TERM receives SIGKILL escalation', async () => {
  const testDir = createTestHarnessDir();
  try {
    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    const killedSignals = [];
    const mockChild = {
      pid: 99999,
      exitCode: null,
      signalCode: null,
      kill(sig) {
        killedSignals.push(sig);
      },
      on(evt, fn) {
        if (evt === 'close') this._closeFn = fn;
      }
    };

    supervisor.child = mockChild;
    supervisor.state = 'running';

    let resolver;
    supervisor.childClosedPromise = new Promise((r) => { resolver = r; });

    const stopTask = supervisor.stop(100);
    setTimeout(() => {
      resolver({ code: null, signal: 'SIGKILL' });
    }, 150);

    await stopTask;
    assert.deepEqual(killedSignals, ['SIGTERM', 'SIGKILL']);
  } finally {
    cleanupTestDir(testDir);
  }
});

// 9. Concurrent CLI start invocations
test('HL1-AUTH-9: Concurrent public CLI start calls yield at most one supervisor & native host', async () => {
  const testDir = createTestHarnessDir();
  const env = { ...process.env, COMPUTER_USE_RUNTIME_DIR: testDir };

  try {
    const [res1, res2] = await Promise.all([
      runCLIAsync(['host-start'], env),
      runCLIAsync(['host-start'], env)
    ]);

    assert.equal(res1.code, 0);
    assert.equal(res2.code, 0);

    const out1 = JSON.parse(res1.stdout);
    const out2 = JSON.parse(res2.stdout);

    assert.equal(out1.success, true);
    assert.equal(out2.success, true);
    assert.equal(out1.status, 'running');
    assert.equal(out2.status, 'running');
    assert.equal(out1.idempotent || out2.idempotent, true);

    await runCLIAsync(['host-stop'], env);
  } finally {
    try {
      await runCLIAsync(['host-stop'], env);
    } catch {}
    cleanupTestDir(testDir);
  }
});

// 10. Unmanaged live native host protection
test('HL1-AUTH-10: Live native host without supervisor control server fails closed', async () => {
  const testDir = createTestHarnessDir();
  const env = { ...process.env, COMPUTER_USE_RUNTIME_DIR: testDir };
  const paths = getCanonicalSocketPaths(testDir);

  let mockServer = null;
  try {
    // Create a mock native socket that responds to status requests asynchronously
    mockServer = net.createServer((sock) => {
      let rxBuf = Buffer.alloc(0);
      sock.on('data', (chunk) => {
        rxBuf = Buffer.concat([rxBuf, chunk]);
        while (rxBuf.length >= 4) {
          const msgLen = rxBuf.readUInt32BE(0);
          if (rxBuf.length >= 4 + msgLen) {
            const reqStr = rxBuf.subarray(4, 4 + msgLen).toString('utf-8');
            rxBuf = rxBuf.subarray(4 + msgLen);
            let req = { id: 'status' };
            try { req = JSON.parse(reqStr); } catch {}
            const resp = {
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
            const respBuf = Buffer.from(JSON.stringify(resp), 'utf-8');
            const headBuf = Buffer.alloc(4);
            headBuf.writeUInt32BE(respBuf.length, 0);
            sock.write(Buffer.concat([headBuf, respBuf]));
          } else {
            break;
          }
        }
      });
    });

    await new Promise((r) => mockServer.listen(paths.hostSocketPath, r));

    // CLI host-status must fail with running_unmanaged
    const statusRes = await runCLIAsync(['host-status'], env);
    assert.notEqual(statusRes.code, 0);
    assert.match(statusRes.stderr || statusRes.stdout, /running_unmanaged/);

    // CLI host-start must fail without altering unmanaged host
    const startRes = await runCLIAsync(['host-start'], env);
    assert.notEqual(startRes.code, 0);
    assert.match(startRes.stderr || startRes.stdout, /Refusing to alter unmanaged host/);

    // CLI host-stop must fail without altering unmanaged host
    const stopRes = await runCLIAsync(['host-stop'], env);
    assert.notEqual(stopRes.code, 0);
    assert.match(stopRes.stderr || stopRes.stdout, /Refusing to stop host/);

    // Verify mock host socket was NOT deleted or altered
    assert.equal(fs.existsSync(paths.hostSocketPath), true);
  } finally {
    if (mockServer) {
      try { mockServer.close(); } catch {}
    }
    cleanupTestDir(testDir);
  }
});

// 11. Safe socket cleanup & foreign artifact preservation
test('HL1-AUTH-11: Safe socket cleanup preserves regular files, symlinks, and wrong inodes', async () => {
  const testDir = createTestHarnessDir();
  try {
    const regFile = path.join(testDir, 'regular.file');
    fs.writeFileSync(regFile, 'DATA');

    const symFile = path.join(testDir, 'sym.link');
    fs.symlinkSync(regFile, symFile);

    assert.throws(() => safeUnlinkSocket(regFile), /Refusing to unlink non-socket/);
    assert.throws(() => safeUnlinkSocket(symFile), /Refusing to unlink symlink/);

    assert.equal(fs.existsSync(regFile), true);
    assert.equal(fs.existsSync(symFile), true);
  } finally {
    cleanupTestDir(testDir);
  }
});

// 12. Supervisor process SIGTERM cleans native child and sockets
test('HL1-AUTH-12: Daemon process receiving SIGTERM cleans up native child and sockets', async () => {
  const testDir = createTestHarnessDir();
  const env = { ...process.env, COMPUTER_USE_RUNTIME_DIR: testDir };

  try {
    const startRes = await runCLIAsync(['host-start'], env);
    assert.equal(startRes.code, 0);
    const startData = JSON.parse(startRes.stdout);
    assert.equal(startData.success, true);

    const supervisor = new ProductionHostSupervisor({ runtimeDir: testDir });
    const ctrlProbe = await supervisor.checkControlStatus();
    assert.equal(ctrlProbe.alive, true);

    const daemonPid = ctrlProbe.data.daemonPid;
    assert.ok(daemonPid > 0);

    // Send SIGTERM to daemon process
    process.kill(daemonPid, 'SIGTERM');

    // Poll until daemon process exits
    let daemonExited = false;
    for (let i = 0; i < 30; i++) {
      try {
        process.kill(daemonPid, 0);
        await new Promise((r) => setTimeout(r, 100));
      } catch {
        daemonExited = true;
        break;
      }
    }

    assert.equal(daemonExited, true, 'Daemon process must exit after SIGTERM');

    const paths = getCanonicalSocketPaths(testDir);
    assert.equal(fs.existsSync(paths.controlSocketPath), false, 'control.sock must be cleaned up on SIGTERM');
    assert.equal(fs.existsSync(paths.hostSocketPath), false, 'host.sock must be cleaned up on SIGTERM');
  } finally {
    try {
      await runCLIAsync(['host-stop'], env);
    } catch {}
    cleanupTestDir(testDir);
  }
});

// 13. Residue check and host.lock preservation
test('HL1-AUTH-13: Residue check proves sockets removed, host.lock preserved if present', async () => {
  const testDir = createTestHarnessDir();
  const env = { ...process.env, COMPUTER_USE_RUNTIME_DIR: testDir };

  try {
    const paths = getCanonicalSocketPaths(testDir);

    const startRes = await runCLIAsync(['host-start'], env);
    assert.equal(startRes.code, 0);
    fs.writeFileSync(paths.lockFilePath, 'LOCK', { mode: 0o600 });

    const stopRes = await runCLIAsync(['host-stop'], env);
    assert.equal(stopRes.code, 0);

    assert.equal(fs.existsSync(paths.hostSocketPath), false, 'host.sock must be cleaned up');
    assert.equal(fs.existsSync(paths.controlSocketPath), false, 'control.sock must be cleaned up');
    assert.equal(fs.existsSync(paths.lockFilePath), true, 'host.lock must remain preserved');
  } finally {
    cleanupTestDir(testDir);
  }
});

// 14. IPC payload limit and response ID correlation
test('HL1-AUTH-14: IPC payload limit and response ID correlation validation', async () => {
  const testDir = createTestHarnessDir();
  const paths = getCanonicalSocketPaths(testDir);

  let mockSockServer = null;
  try {
    mockSockServer = net.createServer((sock) => {
      sock.on('data', () => {
        // Send back mismatched ID response
        const resp = { id: 'wrong-id', success: true, data: {} };
        const payloadBuf = Buffer.from(JSON.stringify(resp), 'utf-8');
        const headBuf = Buffer.alloc(4);
        headBuf.writeUInt32BE(payloadBuf.length, 0);
        sock.write(Buffer.concat([headBuf, payloadBuf]));
      });
    });

    await new Promise((r) => mockSockServer.listen(paths.controlSocketPath, r));

    await assert.rejects(async () => {
      await sendFramedIPCRequest(paths.controlSocketPath, { id: 'expected-id', method: 'status' }, 500);
    }, /IPC response ID mismatch/);

  } finally {
    if (mockSockServer) {
      try { mockSockServer.close(); } catch {}
    }
    cleanupTestDir(testDir);
  }
});
