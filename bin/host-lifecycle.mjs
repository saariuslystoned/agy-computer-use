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

export function fail(msg, status = 'error', code = 'ERROR', exitCode = 1) {
  const errOutput = { success: false, status, code, error: msg };
  console.log(JSON.stringify(errOutput, null, 2));
  process.exit(exitCode);
}

function validateCLIArgs(argv) {
  if (argv.length > 3) {
    fail(`Lifecycle commands accept zero extra arguments or flags. Received ${argv.length - 3} extra argument(s).`, 'error', 'INVALID_ARGS', 1);
  }
}

export async function executeHostStart(customSupervisor) {
  const supervisor = customSupervisor || new ProductionHostSupervisor();
  const runtimeDir = supervisor.runtimeDir;
  const paths = getCanonicalSocketPaths(runtimeDir, false);

  // 1. Probe control server status first
  const ctrlProbe = await supervisor.checkControlStatus(1000);
  if (ctrlProbe.alive) {
    const ownerStatus = ctrlProbe.data.status;
    const initialGen = ctrlProbe.data.generation;

    if (ownerStatus === 'running') {
      const native = ctrlProbe.data.native;
      if (native) {
        console.log(JSON.stringify({
          success: true,
          status: 'running',
          idempotent: true,
          generation: ctrlProbe.data.generation,
          daemonPid: ctrlProbe.data.daemonPid,
          nativePid: ctrlProbe.data.nativePid || ctrlProbe.data.pid || null,
          pid: ctrlProbe.data.nativePid || ctrlProbe.data.pid || null,
          socketPath: paths.hostSocketPath,
          tcc_permission_state: native.tcc_permission_state
        }, null, 2));
        process.exit(0);
        return;
      }
    }

    if (ownerStatus === 'stopping') {
      fail('Existing host daemon is currently stopping. Refusing to start over stopping host.', 'error', 'STOPPING_IN_PROGRESS', 1);
    }

    if (ownerStatus === 'starting') {
      // Live owner is currently starting - wait/probe that exact generation!
      const startWaitTimeoutMs = 7000;
      const startWaitBegin = Date.now();
      let readyRunning = false;
      let finalCtrlData = null;

      while (Date.now() - startWaitBegin < startWaitTimeoutMs) {
        const cProbe = await supervisor.checkControlStatus(300);
        if (cProbe.alive && cProbe.data.generation === initialGen) {
          if (cProbe.data.status === 'running' && cProbe.data.native) {
            readyRunning = true;
            finalCtrlData = cProbe.data;
            break;
          }
        } else if (!cProbe.alive) {
          break;
        }
        await new Promise((r) => setTimeout(r, 150));
      }

      if (readyRunning && finalCtrlData && finalCtrlData.native) {
        console.log(JSON.stringify({
          success: true,
          status: 'running',
          idempotent: true,
          generation: finalCtrlData.generation,
          daemonPid: finalCtrlData.daemonPid,
          nativePid: finalCtrlData.nativePid || finalCtrlData.pid || null,
          pid: finalCtrlData.nativePid || finalCtrlData.pid || null,
          socketPath: paths.hostSocketPath,
          tcc_permission_state: finalCtrlData.native.tcc_permission_state
        }, null, 2));
        process.exit(0);
        return;
      }

      fail('Existing starting host daemon failed to transition to running within timeout', 'error', 'START_TIMEOUT', 1);
    }
  }

  // 2. Check if native host is active without control server (unmanaged)
  let hostSocketExists = false;
  try {
    const st = fs.lstatSync(paths.hostSocketPath);
    if (st.isSocket()) hostSocketExists = true;
  } catch {}

  if (hostSocketExists) {
    const nativeProbe = await supervisor.checkNativeStatus(500);
    if (nativeProbe.alive) {
      fail('Native host process is running without an owner control server. Refusing to alter unmanaged host.', 'RUNNING_UNMANAGED', 'RUNNING_UNMANAGED', 1);
    }
  }

  // 3. In-process supervisor test path vs production CLI daemon spawn
  if (customSupervisor) {
    try {
      const res = await supervisor.start();
      console.log(JSON.stringify({ success: true, ...res }, null, 2));
      process.exit(0);
    } catch (err) {
      fail(`host-start failed: ${err.message}`, 'error', 'START_FAILED', 1);
    }
    return;
  }

  const daemonScript = fileURLToPath(import.meta.url);
  const daemon = spawn(process.execPath, [daemonScript, 'daemon'], {
    cwd: REPO_ROOT,
    detached: true,
    stdio: 'ignore'
  });

  const spawnedDaemonPid = daemon.pid;
  let daemonClosed = false;
  let daemonError = null;

  daemon.on('close', () => { daemonClosed = true; });
  daemon.on('error', (err) => { daemonError = err; daemonClosed = true; });

  // 4. Handshake loop: poll control + native readiness
  const timeoutMs = 7000;
  const startTime = Date.now();
  let ctrlReady = false;
  let nativeData = null;
  let finalCtrlData = null;

  while (Date.now() - startTime < timeoutMs) {
    const cProbe = await supervisor.checkControlStatus(300);
    if (cProbe.alive) {
      const nProbe = await supervisor.checkNativeStatus(300);
      if (nProbe.alive) {
        ctrlReady = true;
        nativeData = nProbe.data;
        finalCtrlData = cProbe.data;
        break;
      }
    } else if (daemonClosed || daemon.exitCode !== null || daemon.signalCode !== null) {
      break;
    }
    await new Promise((r) => setTimeout(r, 150));
  }

  if (!ctrlReady) {
    try { daemon.kill('SIGTERM'); } catch {}
    const killTimer = setTimeout(() => {
      try { daemon.kill('SIGKILL'); } catch {}
    }, 1500);
    if (!daemonClosed) {
      await new Promise((r) => daemon.on('close', r));
    }
    clearTimeout(killTimer);
    fail(`Host daemon failed to start or pass readiness check within timeout${daemonError ? `: ${daemonError.message}` : ''}`, 'error', 'START_TIMEOUT', 1);
  }

  daemon.unref();

  const isWinningOwner = Boolean(spawnedDaemonPid && finalCtrlData?.daemonPid === spawnedDaemonPid);

  console.log(JSON.stringify({
    success: true,
    status: 'running',
    idempotent: !isWinningOwner,
    generation: finalCtrlData?.generation,
    daemonPid: finalCtrlData?.daemonPid,
    nativePid: finalCtrlData?.nativePid || finalCtrlData?.pid || null,
    pid: finalCtrlData?.nativePid || finalCtrlData?.pid || null,
    socketPath: paths.hostSocketPath,
    tcc_permission_state: nativeData?.tcc_permission_state || 'unknown'
  }, null, 2));
  process.exit(0);
}

export async function executeHostStatus(customSupervisor) {
  const supervisor = customSupervisor || new ProductionHostSupervisor();
  const paths = getCanonicalSocketPaths(supervisor.runtimeDir, false);

  const ctrlProbe = await supervisor.checkControlStatus(1000);

  if (ctrlProbe.alive) {
    if (ctrlProbe.data.status === 'running') {
      console.log(JSON.stringify({
        success: true,
        status: 'running',
        generation: ctrlProbe.data.generation,
        daemonPid: ctrlProbe.data.daemonPid,
        nativePid: ctrlProbe.data.nativePid || ctrlProbe.data.pid || null,
        pid: ctrlProbe.data.nativePid || ctrlProbe.data.pid || null,
        data: ctrlProbe.data.native
      }, null, 2));
      process.exit(0);
      return;
    } else if (ctrlProbe.data.status === 'starting' || ctrlProbe.data.status === 'stopping') {
      console.log(JSON.stringify({
        success: true,
        status: ctrlProbe.data.status,
        generation: ctrlProbe.data.generation,
        daemonPid: ctrlProbe.data.daemonPid,
        nativePid: ctrlProbe.data.nativePid || ctrlProbe.data.pid || null,
        pid: ctrlProbe.data.nativePid || ctrlProbe.data.pid || null,
        data: ctrlProbe.data.native || null
      }, null, 2));
      process.exit(0);
      return;
    }
  }

  let ctrlSocketExists = false;
  let hostSocketExists = false;

  try {
    const st = fs.lstatSync(paths.controlSocketPath);
    if (st.isSocket() || st.isSymbolicLink() || st.isFile() || st.isDirectory()) ctrlSocketExists = true;
  } catch {}

  try {
    const st = fs.lstatSync(paths.hostSocketPath);
    if (st.isSocket() || st.isSymbolicLink() || st.isFile() || st.isDirectory()) hostSocketExists = true;
  } catch {}

  if (!ctrlSocketExists && !hostSocketExists) {
    console.log(JSON.stringify({
      success: true,
      status: 'stopped',
      details: 'No host process or socket active'
    }, null, 2));
    process.exit(0);
    return;
  }

  if (hostSocketExists && !ctrlSocketExists) {
    const nativeProbe = await supervisor.checkNativeStatus(500);
    if (nativeProbe.alive) {
      fail('Native host socket is active but supervisor control process is absent (RUNNING_UNMANAGED)', 'RUNNING_UNMANAGED', 'RUNNING_UNMANAGED', 1);
    }
  }

  if (ctrlSocketExists && !hostSocketExists) {
    fail('Supervisor control server is active but native host process is absent (STALE_OR_AMBIGUOUS)', 'STALE_OR_AMBIGUOUS', 'STALE_OR_AMBIGUOUS', 1);
  }

  fail('Socket files exist but host and control endpoints are unresponsive (stale)', 'STALE_OR_AMBIGUOUS', 'STALE_OR_AMBIGUOUS', 1);
}

export async function executeHostStop(customSupervisor) {
  const supervisor = customSupervisor || new ProductionHostSupervisor();
  const paths = getCanonicalSocketPaths(supervisor.runtimeDir, false);

  const ctrlProbe = await supervisor.checkControlStatus(1000);

  if (ctrlProbe.alive) {
    const ownerGen = ctrlProbe.data.generation;
    const ownerDaemonPid = ctrlProbe.data.daemonPid;
    const ownerNativePid = ctrlProbe.data.nativePid || ctrlProbe.data.pid || null;

    try {
      const res = await sendFramedIPCRequest(
        paths.controlSocketPath,
        { id: `stop-cli-${Date.now()}`, method: 'stop' },
        4000
      );
      if (res && res.success && res.data && res.data.status === 'stopped') {
        const receipt = res.data;
        if (
          typeof receipt.generation !== 'string' ||
          receipt.generation !== ownerGen ||
          typeof receipt.daemonPid !== 'number' ||
          receipt.daemonPid !== ownerDaemonPid ||
          (receipt.nativePid !== null && typeof receipt.nativePid !== 'number') ||
          receipt.native_closed !== true ||
          typeof receipt.killEscalated !== 'boolean' ||
          !receipt.residueState ||
          typeof receipt.residueState.hostSocketClean !== 'boolean' ||
          typeof receipt.residueState.lockFilePreserved !== 'boolean'
        ) {
          fail('Malformed stop receipt received from supervisor', 'error', 'MALFORMED_RECEIPT', 1);
        }

        // Bounded wait for daemon & native process termination and socket absence
        const stopWaitBegin = Date.now();
        const stopWaitTimeoutMs = 3000;
        let daemonDead = false;

        while (Date.now() - stopWaitBegin < stopWaitTimeoutMs) {
          let dAlive = true;
          try { process.kill(ownerDaemonPid, 0); } catch { dAlive = false; }
          let nAlive = false;
          if (ownerNativePid) {
            try { process.kill(ownerNativePid, 0); nAlive = true; } catch { nAlive = false; }
          }
          if (!dAlive && !nAlive) {
            daemonDead = true;
            break;
          }
          await new Promise((r) => setTimeout(r, 40));
        }

        let ctrlSocketPresent = false;
        try { fs.lstatSync(paths.controlSocketPath); ctrlSocketPresent = true; } catch (err) {
          if (err.code !== 'ENOENT') ctrlSocketPresent = true;
        }

        let hostSocketPresent = false;
        try { fs.lstatSync(paths.hostSocketPath); hostSocketPresent = true; } catch (err) {
          if (err.code !== 'ENOENT') hostSocketPresent = true;
        }

        let lockFilePreserved = false;
        try {
          const lockSt = fs.lstatSync(paths.lockFilePath);
          lockFilePreserved = lockSt.isFile() && (lockSt.mode & 0o077) === 0;
        } catch {}

        if (daemonDead && !ctrlSocketPresent && !hostSocketPresent && lockFilePreserved) {
          const finalReceipt = {
            success: true,
            status: 'stopped',
            idempotent: false,
            generation: receipt.generation,
            daemonPid: receipt.daemonPid,
            nativePid: receipt.nativePid,
            native_closed: receipt.native_closed,
            killEscalated: receipt.killEscalated,
            residueState: {
              hostSocketClean: !hostSocketPresent,
              controlSocketClean: !ctrlSocketPresent,
              lockFilePreserved: lockFilePreserved
            }
          };
          console.log(JSON.stringify(finalReceipt, null, 2));
          process.exit(0);
          return;
        }

        fail('Daemon or native process did not terminate within timeout after stop receipt', 'error', 'STOP_TIMEOUT', 1);
      }
    } catch (err) {
      fail(`Failed to send stop request to active supervisor: ${err.message}`, 'error', 'STOP_FAILED', 1);
    }
  }

  let ctrlSocketExists = false;
  let hostSocketExists = false;

  try {
    const st = fs.lstatSync(paths.controlSocketPath);
    if (st.isSocket() || st.isSymbolicLink() || st.isFile() || st.isDirectory()) ctrlSocketExists = true;
  } catch {}

  try {
    const st = fs.lstatSync(paths.hostSocketPath);
    if (st.isSocket() || st.isSymbolicLink() || st.isFile() || st.isDirectory()) hostSocketExists = true;
  } catch {}

  if (!ctrlSocketExists && !hostSocketExists) {
    console.log(JSON.stringify({
      success: true,
      status: 'stopped',
      idempotent: true,
      generation: null,
      daemonPid: null,
      nativePid: null,
      native_closed: true,
      killEscalated: false,
      residueState: {
        hostSocketClean: true,
        controlSocketClean: true,
        lockFilePreserved: true
      }
    }, null, 2));
    process.exit(0);
    return;
  }

  if (hostSocketExists) {
    const nativeProbe = await supervisor.checkNativeStatus(500);
    if (nativeProbe.alive) {
      fail('Refusing to stop host: native host process exists without an active supervisor owner', 'RUNNING_UNMANAGED', 'UNMANAGED_HOST', 1);
    }
  }

  fail('Socket files exist but supervisor control server is not active', 'STALE_OR_AMBIGUOUS', 'NO_OWNER', 1);
}

async function runDaemon() {
  const supervisor = new ProductionHostSupervisor({ isDaemonProcess: true });
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
    fail(`Unknown host lifecycle command '${command}'`, 'error', 'UNKNOWN_COMMAND', 1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main().catch((err) => fail(err.message, 'error', 'UNHANDLED_ERROR', 1));
}
