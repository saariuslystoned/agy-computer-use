#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
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

function fail(msg, code = 1) {
  const errOutput = { success: false, error: msg };
  console.error(JSON.stringify(errOutput, null, 2));
  process.exit(code);
}

function validateCLIArgs(argv) {
  // argv: [node, script, command, ...extra]
  if (argv.length > 3) {
    fail(`Lifecycle commands accept zero extra arguments or flags. Received ${argv.length - 3} extra argument(s).`);
  }
}

export async function executeHostStart(customSupervisor) {
  const runtimeDir = customSupervisor?.runtimeDir || getCanonicalRuntimeDir();
  const paths = getCanonicalSocketPaths(runtimeDir);
  const supervisor = customSupervisor || new ProductionHostSupervisor({ runtimeDir });

  // 1. Probe control server status
  const ctrlProbe = await supervisor.checkControlStatus(500);
  if (ctrlProbe.alive) {
    const nativeProbe = await supervisor.checkNativeStatus(500);
    if (nativeProbe.alive) {
      console.log(JSON.stringify({
        success: true,
        status: 'running',
        idempotent: true,
        message: 'Host app already running and healthy',
        tcc_permission_state: nativeProbe.data.tcc_permission_state
      }, null, 2));
      process.exit(0);
      return;
    }
  }

  // 2. Check if native host is active without control server (unmanaged)
  if (fs.existsSync(paths.hostSocketPath)) {
    const nativeProbe = await supervisor.checkNativeStatus(500);
    if (nativeProbe.alive) {
      fail('Native host process is running without an owner control server. Refusing to alter unmanaged host.', 1);
    }
  }

  // 3. Clean up any stale sockets if not alive
  if (fs.existsSync(paths.controlSocketPath)) {
    try { safeUnlinkSocket(paths.controlSocketPath); } catch {}
  }
  if (fs.existsSync(paths.hostSocketPath)) {
    try { safeUnlinkSocket(paths.hostSocketPath); } catch {}
  }

  // 4. Launch persistent supervisor daemon process
  if (customSupervisor) {
    // In-process start (for direct supervisor tests)
    try {
      const res = await supervisor.start();
      console.log(JSON.stringify({ success: true, ...res }, null, 2));
      process.exit(0);
    } catch (err) {
      fail(`host-start failed: ${err.message}`);
    }
    return;
  }

  const daemonScript = fileURLToPath(import.meta.url);
  const daemon = spawn(process.execPath, [daemonScript, 'daemon'], {
    cwd: REPO_ROOT,
    detached: true,
    stdio: 'ignore'
  });
  daemon.unref();

  const spawnedDaemonPid = daemon.pid;

  // 5. Handshake loop: poll control + native readiness
  const timeoutMs = 7000;
  const startTime = Date.now();
  let ctrlReady = false;
  let nativeData = null;

  while (Date.now() - startTime < timeoutMs) {
    const cProbe = await supervisor.checkControlStatus(300);
    if (cProbe.alive) {
      const nProbe = await supervisor.checkNativeStatus(300);
      if (nProbe.alive) {
        ctrlReady = true;
        nativeData = nProbe.data;
        break;
      }
    }
    await new Promise((r) => setTimeout(r, 150));
  }

  if (!ctrlReady) {
    fail('Host daemon failed to start or pass readiness check within timeout', 1);
  }

  const finalCtrl = await supervisor.checkControlStatus(300);
  const isWinningOwner = Boolean(spawnedDaemonPid && finalCtrl.data?.daemonPid === spawnedDaemonPid);

  console.log(JSON.stringify({
    success: true,
    status: 'running',
    idempotent: !isWinningOwner,
    pid: finalCtrl.data?.pid || null,
    socketPath: paths.hostSocketPath,
    tcc_permission_state: nativeData?.tcc_permission_state || 'unknown'
  }, null, 2));
  process.exit(0);
}

export async function executeHostStatus(customSupervisor) {
  const runtimeDir = customSupervisor?.runtimeDir || getCanonicalRuntimeDir();
  const paths = getCanonicalSocketPaths(runtimeDir);
  const supervisor = customSupervisor || new ProductionHostSupervisor({ runtimeDir });

  const ctrlProbe = await supervisor.checkControlStatus(1000);
  const nativeProbe = await supervisor.checkNativeStatus(1000);

  if (ctrlProbe.alive && nativeProbe.alive) {
    console.log(JSON.stringify({
      success: true,
      status: 'running',
      data: nativeProbe.data
    }, null, 2));
    process.exit(0);
    return;
  }

  if (!fs.existsSync(paths.controlSocketPath) && !fs.existsSync(paths.hostSocketPath)) {
    console.log(JSON.stringify({
      success: true,
      status: 'stopped',
      details: 'No host process or socket active'
    }, null, 2));
    process.exit(0);
    return;
  }

  if (nativeProbe.alive && !ctrlProbe.alive) {
    fail('Native host socket is active but supervisor control process is absent (running_unmanaged)', 1);
  }

  if (ctrlProbe.alive && !nativeProbe.alive) {
    fail('Supervisor control server is active but native host process is unresponsive', 1);
  }

  fail('Socket files exist but host and control endpoints are unresponsive (stale)', 1);
}

export async function executeHostStop(customSupervisor) {
  const runtimeDir = customSupervisor?.runtimeDir || getCanonicalRuntimeDir();
  const paths = getCanonicalSocketPaths(runtimeDir);
  const supervisor = customSupervisor || new ProductionHostSupervisor({ runtimeDir });

  const ctrlProbe = await supervisor.checkControlStatus(1000);

  if (ctrlProbe.alive) {
    try {
      const res = await sendFramedIPCRequest(
        paths.controlSocketPath,
        { id: `stop-cli-${Date.now()}`, method: 'stop' },
        4000
      );
      if (res && res.success) {
        console.log(JSON.stringify({ success: true, status: 'stopped', idempotent: false }, null, 2));
        process.exit(0);
        return;
      }
    } catch (err) {
      fail(`Failed to send stop request to active supervisor: ${err.message}`, 1);
    }
  }

  if (!fs.existsSync(paths.controlSocketPath) && !fs.existsSync(paths.hostSocketPath)) {
    console.log(JSON.stringify({ success: true, status: 'stopped', idempotent: true }, null, 2));
    process.exit(0);
    return;
  }

  if (fs.existsSync(paths.hostSocketPath)) {
    const nativeProbe = await supervisor.checkNativeStatus(500);
    if (nativeProbe.alive) {
      fail('Refusing to stop host: native host process exists without an active supervisor owner', 1);
    }
  }

  // Socket files exist but endpoints are dead - report stopped after safe cleanup
  if (fs.existsSync(paths.controlSocketPath)) {
    try { safeUnlinkSocket(paths.controlSocketPath); } catch {}
  }
  if (fs.existsSync(paths.hostSocketPath)) {
    try { safeUnlinkSocket(paths.hostSocketPath); } catch {}
  }

  console.log(JSON.stringify({ success: true, status: 'stopped', idempotent: true }, null, 2));
  process.exit(0);
}

async function runDaemon() {
  const supervisor = new ProductionHostSupervisor();
  try {
    await supervisor.start();
  } catch (err) {
    console.error(`[DAEMON-ERROR] Supervisor start failed: ${err.message}`);
    process.exit(1);
  }
}

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (command === 'daemon') {
    await runDaemon();
    return;
  }

  validateCLIArgs(process.argv);

  if (command === 'host-start') {
    await executeHostStart();
  } else if (command === 'host-status') {
    await executeHostStatus();
  } else if (command === 'host-stop') {
    await executeHostStop();
  } else {
    fail(`Unknown host lifecycle command '${command}'`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main().catch((err) => fail(err.message));
}
