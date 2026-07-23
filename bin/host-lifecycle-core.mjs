import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { stageHostApp } from './host-app.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

export function getCanonicalRuntimeDir(customDir = null, isMutation = false) {
  const uid = process.getuid ? process.getuid() : 501;
  const runtimeDir = customDir || `/tmp/agy-computer-use-${uid}`;

  let st;
  try {
    st = fs.lstatSync(runtimeDir);
  } catch (err) {
    if (err.code === 'ENOENT') {
      if (!isMutation) {
        return runtimeDir;
      }
      fs.mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
      st = fs.lstatSync(runtimeDir);
    } else {
      throw err;
    }
  }

  if (st.isSymbolicLink()) {
    throw new Error(`Runtime directory ${runtimeDir} cannot be a symbolic link`);
  }
  if (!st.isDirectory()) {
    throw new Error(`Runtime directory ${runtimeDir} must be a directory`);
  }
  if (process.getuid && st.uid !== uid) {
    throw new Error(`Runtime directory ${runtimeDir} owner mismatch: expected UID ${uid}, got ${st.uid}`);
  }
  if (isMutation && (st.mode & 0o077) !== 0) {
    fs.chmodSync(runtimeDir, 0o700);
  }

  return runtimeDir;
}

export function getCanonicalRuntimeDirIdentity(customDir = null, isMutation = false) {
  const runtimeDir = getCanonicalRuntimeDir(customDir, isMutation);
  let st;
  try {
    st = fs.lstatSync(runtimeDir);
  } catch (err) {
    if (err.code === 'ENOENT') {
      const uid = process.getuid ? process.getuid() : 501;
      return { uid, dev: null, ino: null, type: 'absent' };
    }
    throw err;
  }
  const uid = process.getuid ? process.getuid() : 501;
  return {
    uid: st.uid,
    dev: st.dev,
    ino: st.ino,
    type: 'directory'
  };
}

export function getCanonicalSocketPaths(customDir = null, isMutation = false) {
  const baseDir = getCanonicalRuntimeDir(customDir, isMutation);
  return {
    runtimeDir: baseDir,
    hostSocketPath: path.join(baseDir, 'host.sock'),
    controlSocketPath: path.join(baseDir, 'control.sock'),
    lockFilePath: path.join(baseDir, 'host.lock')
  };
}

export function safeUnlinkSocket(socketPath, rootIdentity, expectedIno = null, expectedDev = null) {
  if (!rootIdentity || typeof rootIdentity !== 'object' || rootIdentity.uid === undefined || rootIdentity.dev === undefined || rootIdentity.ino === undefined) {
    throw new Error(`safeUnlinkSocket requires mandatory captured rootIdentity {uid, dev, ino}`);
  }

  let st;
  try {
    st = fs.lstatSync(socketPath);
  } catch (err) {
    if (err.code === 'ENOENT') return false;
    throw err;
  }
  if (st.isSymbolicLink()) {
    throw new Error(`Refusing to unlink symlink at ${socketPath}`);
  }
  if (!st.isSocket()) {
    throw new Error(`Refusing to unlink non-socket file/directory at ${socketPath}`);
  }
  const currentUid = process.getuid ? process.getuid() : 501;
  if (st.uid !== currentUid) {
    throw new Error(`Refusing to unlink socket owned by UID ${st.uid} (expected ${currentUid})`);
  }
  if (expectedIno !== null && expectedIno !== undefined && st.ino !== expectedIno) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: inode mismatch (expected ${expectedIno}, got ${st.ino})`);
  }
  if (expectedDev !== null && expectedDev !== undefined && st.dev !== expectedDev) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: device mismatch (expected ${expectedDev}, got ${st.dev})`);
  }

  const parentDir = path.dirname(socketPath);
  let parentSt;
  try {
    parentSt = fs.lstatSync(parentDir);
  } catch (err) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: failed to lstat root directory ${parentDir}: ${err.message}`);
  }
  if (parentSt.isSymbolicLink() || !parentSt.isDirectory()) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: root directory ${parentDir} is not a valid directory`);
  }
  if (rootIdentity.uid !== undefined && parentSt.uid !== rootIdentity.uid) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: root directory UID mismatch (expected ${rootIdentity.uid}, got ${parentSt.uid})`);
  }
  if (rootIdentity.dev !== null && rootIdentity.dev !== undefined && parentSt.dev !== rootIdentity.dev) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: root directory dev mismatch (expected ${rootIdentity.dev}, got ${parentSt.dev})`);
  }
  if (rootIdentity.ino !== null && rootIdentity.ino !== undefined && parentSt.ino !== rootIdentity.ino) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: root directory inode mismatch (expected ${rootIdentity.ino}, got ${parentSt.ino})`);
  }

  // Immediate identical revalidation before unlink
  let st2;
  try {
    st2 = fs.lstatSync(socketPath);
  } catch (err) {
    if (err.code === 'ENOENT') return false;
    throw err;
  }
  if (st2.isSymbolicLink() || !st2.isSocket() || st2.uid !== currentUid || st2.ino !== st.ino || st2.dev !== st.dev) {
    throw new Error(`Socket state changed during revalidation prior to unlink at ${socketPath}`);
  }

  fs.unlinkSync(socketPath);
  return true;
}

export function sendFramedIPCRequest(socketPath, requestObj, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    if (!requestObj || typeof requestObj !== 'object' || requestObj.id === undefined || requestObj.id === null) {
      return reject(new Error('IPC request must include a valid request id'));
    }

    let st;
    try {
      st = fs.lstatSync(socketPath);
    } catch (err) {
      return reject(new Error(`Socket path check failed at ${socketPath}: ${err.message}`));
    }
    if (st.isSymbolicLink()) {
      return reject(new Error(`Refusing to connect: socket path ${socketPath} is a symbolic link`));
    }
    if (!st.isSocket()) {
      return reject(new Error(`Path ${socketPath} is not a UNIX socket`));
    }

    let client = null;
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      if (client) client.destroy();
      reject(new Error(`IPC request timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    const cleanup = () => {
      clearTimeout(timer);
      if (client) {
        client.destroy();
        client = null;
      }
    };

    client = net.createConnection(socketPath, () => {
      const payloadBuf = Buffer.from(JSON.stringify(requestObj), 'utf-8');
      const headerBuf = Buffer.alloc(4);
      headerBuf.writeUInt32BE(payloadBuf.length, 0);
      client.write(Buffer.concat([headerBuf, payloadBuf]));
    });

    let rxBuf = Buffer.alloc(0);
    const MAX_PAYLOAD_SIZE = 16 * 1024 * 1024;

    client.on('data', (chunk) => {
      rxBuf = Buffer.concat([rxBuf, chunk]);
      if (rxBuf.length >= 4) {
        const msgLen = rxBuf.readUInt32BE(0);
        if (msgLen > MAX_PAYLOAD_SIZE) {
          cleanup();
          if (settled) return;
          settled = true;
          reject(new Error(`IPC payload length ${msgLen} exceeds 16MB limit`));
          return;
        }
        if (rxBuf.length >= 4 + msgLen) {
          const payloadJson = rxBuf.subarray(4, 4 + msgLen).toString('utf-8');
          cleanup();
          if (settled) return;
          settled = true;
          try {
            const parsed = JSON.parse(payloadJson);
            if (parsed.id === undefined || parsed.id === null) {
              reject(new Error(`IPC response missing ID`));
            } else if (parsed.id !== requestObj.id) {
              reject(new Error(`IPC response ID mismatch: expected ${JSON.stringify(requestObj.id)} (${typeof requestObj.id}), got ${JSON.stringify(parsed.id)} (${typeof parsed.id})`));
            } else {
              resolve(parsed);
            }
          } catch (e) {
            reject(new Error(`Malformed JSON response from socket: ${e.message}`));
          }
        }
      }
    });

    client.on('error', (err) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(err);
    });

    client.on('close', () => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(`Socket closed before response received`));
    });
  });
}

export function validateStatusResponseSchema(res) {
  if (!res || typeof res !== 'object') return false;
  if (res.id === undefined || res.success !== true) return false;
  if (!res.data || typeof res.data !== 'object') return false;
  const d = res.data;
  if (typeof d.connected !== 'boolean') return false;
  if (typeof d.tcc_permission_state !== 'string') return false;
  if (typeof d.accessibility_available !== 'boolean') return false;
  if (typeof d.accessibility_trusted !== 'boolean') return false;
  if (typeof d.input_mutation_state !== 'string') return false;
  return true;
}

export class ProductionHostSupervisor {
  constructor(options = {}) {
    this.runtimeDir = getCanonicalRuntimeDir(options.runtimeDir, false);
    const paths = getCanonicalSocketPaths(this.runtimeDir, false);
    this.hostSocketPath = paths.hostSocketPath;
    this.controlSocketPath = paths.controlSocketPath;
    this.lockFilePath = paths.lockFilePath;

    this.generation = crypto.randomUUID();
    this.isDaemonProcess = options.isDaemonProcess ?? false;
    this.activeConnections = new Set();
    this.child = null;
    this.controlServer = null;
    this.rootIdentity = null;
    this.controlSocketIno = null;
    this.controlSocketDev = null;
    this.hostSocketIno = null;
    this.hostSocketDev = null;
    this.childClosedPromise = null;
    this.childClosedResolver = null;
    this.cleanupPromise = null;
    this.stoppingFromSignal = false;
    this.killEscalated = false;
    this.state = 'stopped';
  }

  ensureLockFile() {
    let lockSt = null;
    try {
      lockSt = fs.lstatSync(this.lockFilePath);
    } catch (err) {
      if (err.code === 'ENOENT') {
        fs.writeFileSync(this.lockFilePath, 'LOCK', { mode: 0o600 });
        lockSt = fs.lstatSync(this.lockFilePath);
      } else {
        throw err;
      }
    }

    if (lockSt.isSymbolicLink()) {
      throw new Error(`Lock file ${this.lockFilePath} cannot be a symbolic link`);
    }
    if (!lockSt.isFile()) {
      throw new Error(`Lock file ${this.lockFilePath} must be a regular file`);
    }
    const uid = process.getuid ? process.getuid() : 501;
    if (process.getuid && lockSt.uid !== uid) {
      throw new Error(`Lock file ${this.lockFilePath} owner mismatch: expected UID ${uid}, got ${lockSt.uid}`);
    }
    fs.chmodSync(this.lockFilePath, 0o600);
  }

  async checkNativeStatus(timeoutMs = 1500) {
    try {
      const res = await sendFramedIPCRequest(
        this.hostSocketPath,
        { id: `status-probe-${Date.now()}`, method: 'status' },
        timeoutMs
      );
      if (validateStatusResponseSchema(res)) {
        return { alive: true, data: res.data };
      }
      return { alive: false, reason: 'invalid_schema', raw: res };
    } catch (err) {
      return { alive: false, reason: err.message };
    }
  }

  async checkControlStatus(timeoutMs = 1500) {
    try {
      const res = await sendFramedIPCRequest(
        this.controlSocketPath,
        { id: `ctrl-probe-${Date.now()}`, method: 'status' },
        timeoutMs
      );
      if (res && res.success && res.data && ['starting', 'running', 'stopping'].includes(res.data.status)) {
        return { alive: true, data: res.data };
      }
      return { alive: false, reason: 'control_not_running', raw: res };
    } catch (err) {
      return { alive: false, reason: err.message };
    }
  }

  startControlServer() {
    return new Promise((resolve, reject) => {
      this.runtimeDir = getCanonicalRuntimeDir(this.runtimeDir, true);
      this.rootIdentity = getCanonicalRuntimeDirIdentity(this.runtimeDir, true);
      this.ensureLockFile();

      let existingControlSt = null;
      try { existingControlSt = fs.lstatSync(this.controlSocketPath); } catch (e) {}

      let existingHostSt = null;
      try { existingHostSt = fs.lstatSync(this.hostSocketPath); } catch (e) {}

      if (existingHostSt && existingHostSt.isSocket()) {
        this.checkNativeStatus(300).then(async (nativeProbe) => {
          if (nativeProbe.alive) {
            if (existingControlSt && existingControlSt.isSocket()) {
              const ctrlProbe = await this.checkControlStatus(300);
              if (ctrlProbe.alive) {
                return reject(new Error(`Active supervisor control server already running on ${this.controlSocketPath}`));
              }
            }
            return reject(new Error(`Native host process is running without an owner control server on ${this.hostSocketPath}`));
          }
          this._proceedWithControlBinding(existingControlSt, resolve, reject);
        }).catch((err) => reject(err));
      } else {
        this._proceedWithControlBinding(existingControlSt, resolve, reject);
      }
    });
  }

  _proceedWithControlBinding(existingControlSt, resolve, reject) {
    if (existingControlSt) {
      if (existingControlSt.isSymbolicLink() || !existingControlSt.isSocket()) {
        return reject(new Error(`Control socket path ${this.controlSocketPath} exists and is not a plain UNIX socket`));
      }
      this.checkControlStatus(300).then(async (ctrlProbe) => {
        if (ctrlProbe.alive) {
          return reject(new Error(`Active supervisor control server already running on ${this.controlSocketPath}`));
        }
        try {
          safeUnlinkSocket(this.controlSocketPath, this.rootIdentity, existingControlSt.ino, existingControlSt.dev);
        } catch (unlinkErr) {
          return reject(unlinkErr);
        }
        this._bindControlServer(resolve, reject);
      }).catch((err) => reject(err));
    } else {
      this._bindControlServer(resolve, reject);
    }
  }

  _bindControlServer(resolve, reject) {
    const server = net.createServer((socket) => {
      this.activeConnections.add(socket);
      socket.setTimeout(2000);

      socket.on('timeout', () => {
        socket.destroy();
      });

      const cleanupConn = () => {
        this.activeConnections.delete(socket);
      };
      socket.on('close', cleanupConn);
      socket.on('error', cleanupConn);

      let rxBuf = Buffer.alloc(0);
      let handledFrame = false;
      const MAX_PAYLOAD = 16 * 1024 * 1024;
      socket.on('data', (chunk) => {
        if (handledFrame) return;
        rxBuf = Buffer.concat([rxBuf, chunk]);
        if (rxBuf.length >= 4) {
          const msgLen = rxBuf.readUInt32BE(0);
          if (msgLen > MAX_PAYLOAD) {
            socket.destroy();
            return;
          }
          if (rxBuf.length >= 4 + msgLen) {
            handledFrame = true;
            const payloadJson = rxBuf.subarray(4, 4 + msgLen).toString('utf-8');
            try {
              const req = JSON.parse(payloadJson);
              if (!req || typeof req !== 'object' || req.id === undefined || req.id === null) {
                const errResp = { id: req?.id ?? null, success: false, error: { code: 'BAD_REQUEST', message: 'Missing request id' } };
                const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
                const headBuf = Buffer.alloc(4);
                headBuf.writeUInt32BE(respBuf.length, 0);
                socket.write(Buffer.concat([headBuf, respBuf]), () => {
                  try { socket.end(); } catch {}
                });
                return;
              }
              this.handleControlRequest(req).then((respObj) => {
                const respBuf = Buffer.from(JSON.stringify(respObj), 'utf-8');
                const headBuf = Buffer.alloc(4);
                headBuf.writeUInt32BE(respBuf.length, 0);
                socket.write(Buffer.concat([headBuf, respBuf]), () => {
                  if (req?.method === 'stop') {
                    try { socket.end(); } catch {}
                  }
                });
                if (req?.method === 'stop') {
                  setImmediate(() => {
                    this._finalizeDaemonTeardown();
                  });
                }
              }).catch((err) => {
                const errResp = { id: req.id, success: false, error: { code: 'INTERNAL_ERROR', message: err.message } };
                const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
                const headBuf = Buffer.alloc(4);
                headBuf.writeUInt32BE(respBuf.length, 0);
                socket.write(Buffer.concat([headBuf, respBuf]), () => {
                  try { socket.end(); } catch {}
                });
              });
            } catch (err) {
              const errResp = { id: null, success: false, error: { code: 'BAD_REQUEST', message: err.message } };
              const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]), () => {
                try { socket.end(); } catch {}
              });
            }
          }
        }
      });
    });

    server.on('error', (err) => {
      reject(err);
    });

    server.listen(this.controlSocketPath, () => {
      try {
        fs.chmodSync(this.controlSocketPath, 0o700);
        const st = fs.lstatSync(this.controlSocketPath);
        this.controlSocketIno = st.ino;
        this.controlSocketDev = st.dev;
      } catch {}
      this.controlServer = server;
      resolve();
    });
  }

  _finalizeDaemonTeardown() {
    if (this.controlServer) {
      try { this.controlServer.close(); } catch {}
      this.controlServer = null;
    }
    if (this.activeConnections) {
      for (const sock of this.activeConnections) {
        try { sock.destroy(); } catch {}
      }
      this.activeConnections.clear();
    }
    if (this.controlSocketIno !== null && this.rootIdentity) {
      try {
        safeUnlinkSocket(this.controlSocketPath, this.rootIdentity, this.controlSocketIno, this.controlSocketDev);
      } catch {}
    } else {
      let st = null;
      try { st = fs.lstatSync(this.controlSocketPath); } catch {}
      if (st && st.isSocket() && this.rootIdentity) {
        try { safeUnlinkSocket(this.controlSocketPath, this.rootIdentity, st.ino, st.dev); } catch {}
      }
    }
    if (this.isDaemonProcess) {
      process.exit(0);
    }
  }

  async handleControlRequest(req) {
    const reqId = req?.id || 'ctrl-req';
    const method = req?.method;

    if (method === 'status') {
      const native = await this.checkNativeStatus(1000);
      return {
        id: reqId,
        success: true,
        data: {
          status: this.state,
          generation: this.generation,
          daemonPid: process.pid,
          pid: this.child?.pid || null,
          nativePid: this.child?.pid || null,
          native: native.data || null,
          killEscalated: this.killEscalated
        }
      };
    }

    if (method === 'stop') {
      const stopResult = await this.stop();
      return {
        id: reqId,
        success: true,
        data: stopResult
      };
    }

    return {
      id: reqId,
      success: false,
      error: { code: 'UNKNOWN_METHOD', message: `Unknown control method ${method}` }
    };
  }

  async start(options = {}) {
    if (this.state === 'running' && this.child) {
      const native = await this.checkNativeStatus(500);
      if (native.alive) {
        return {
          status: 'running',
          idempotent: true,
          generation: this.generation,
          daemonPid: process.pid,
          pid: this.child.pid,
          nativePid: this.child.pid,
          socketPath: this.hostSocketPath,
          tcc_permission_state: native.data.tcc_permission_state
        };
      }
    }

    await this.startControlServer();
    this.state = 'starting';

    const cleanupSignal = () => {
      if (!this.stoppingFromSignal) {
        this.stoppingFromSignal = true;
        this.stop().then(() => {
          this._finalizeDaemonTeardown();
        }).catch(() => {
          this._finalizeDaemonTeardown();
        });
      }
    };
    process.once('SIGTERM', cleanupSignal);
    process.once('SIGINT', cleanupSignal);
    process.once('SIGHUP', cleanupSignal);

    try {
      const defaultBinary = path.join(REPO_ROOT, 'apps/computer-use-host/.build/staged/ComputerUseHost.app/Contents/MacOS/ComputerUseHost');
      let binaryPath = options.binaryPath || defaultBinary;

      if (!fs.existsSync(binaryPath) || options.stage === true || options.build === true) {
        const stageOpts = options.build !== undefined ? { build: options.build } : {};
        const stagedResult = await stageHostApp(stageOpts);
        binaryPath = stagedResult.binaryPath;
      }
      if (!fs.existsSync(binaryPath)) {
        throw new Error(`Staged binary does not exist at ${binaryPath}`);
      }

      let childClosed = false;
      this.childClosedPromise = new Promise((resolve) => {
        this.childClosedResolver = resolve;
      });

      const childEnv = { ...process.env, COMPUTER_USE_SOCKET_PATH: this.hostSocketPath, AGY_SOCKET_PATH: this.hostSocketPath };
      const binaryArgs = options.binaryArgs || [];
      const proc = spawn(binaryPath, binaryArgs, {
        cwd: REPO_ROOT,
        env: childEnv,
        stdio: ['ignore', 'pipe', 'pipe']
      });

      this.child = proc;

      if (proc.stdout) proc.stdout.resume();
      if (proc.stderr) proc.stderr.resume();

      proc.on('close', (code, signal) => {
        childClosed = true;
        if (this.childClosedResolver) {
          this.childClosedResolver({ code, signal });
        }
      });

      proc.on('error', (err) => {
        childClosed = true;
        if (this.childClosedResolver) {
          this.childClosedResolver({ error: err });
        }
      });

      const readinessTimeoutMs = options.readinessTimeoutMs || 5000;
      const startTime = Date.now();
      let ready = false;
      let lastNativeData = null;

      while (Date.now() - startTime < readinessTimeoutMs) {
        if (childClosed) break;
        const probe = await this.checkNativeStatus(500);
        if (probe.alive) {
          ready = true;
          lastNativeData = probe.data;
          break;
        }
        await new Promise((r) => setTimeout(r, 100));
      }

      if (!ready || childClosed) {
        throw new Error(childClosed ? 'Host child process exited during startup' : `Readiness check timed out after ${readinessTimeoutMs}ms`);
      }

      try {
        const hostSt = fs.lstatSync(this.hostSocketPath);
        this.hostSocketIno = hostSt.ino;
        this.hostSocketDev = hostSt.dev;
      } catch {}

      this.state = 'running';
      return {
        status: 'running',
        idempotent: false,
        generation: this.generation,
        daemonPid: process.pid,
        pid: proc.pid,
        nativePid: proc.pid,
        socketPath: this.hostSocketPath,
        tcc_permission_state: lastNativeData.tcc_permission_state
      };
    } catch (err) {
      await this.stop();
      this._finalizeDaemonTeardown();
      throw err;
    }
  }

  stop(stopTimeoutMs = 3000) {
    if (this.cleanupPromise) {
      return this.cleanupPromise;
    }
    this.cleanupPromise = this._stopInternal(stopTimeoutMs);
    return this.cleanupPromise;
  }

  async _stopInternal(stopTimeoutMs = 3000) {
    this.state = 'stopping';

    const nativePid = this.child?.pid || null;
    let nativeClosed = false;
    let killEscalated = false;

    if (this.child) {
      const proc = this.child;
      this.child = null;

      if (proc.exitCode === null && proc.signalCode === null) {
        let childPromise = this.childClosedPromise;
        if (!childPromise) {
          childPromise = new Promise((resolve) => {
            proc.on('close', (code, signal) => resolve({ code, signal }));
          });
        }

        let graceTimer = null;
        const timeoutPromise = new Promise((r) => {
          graceTimer = setTimeout(() => r('timed_out'), stopTimeoutMs);
        });

        try {
          proc.kill('SIGTERM');
        } catch {}

        const res = await Promise.race([childPromise, timeoutPromise]);
        if (graceTimer) clearTimeout(graceTimer);

        if (res === 'timed_out') {
          killEscalated = true;
          this.killEscalated = true;
          try {
            proc.kill('SIGKILL');
          } catch {}
          await childPromise;
        }
        nativeClosed = true;
      } else {
        nativeClosed = true;
      }
    } else {
      nativeClosed = true;
    }

    if (this.hostSocketIno !== null && this.rootIdentity) {
      try {
        safeUnlinkSocket(this.hostSocketPath, this.rootIdentity, this.hostSocketIno, this.hostSocketDev);
      } catch {}
    } else {
      let st = null;
      try { st = fs.lstatSync(this.hostSocketPath); } catch {}
      if (st && st.isSocket() && this.rootIdentity) {
        try { safeUnlinkSocket(this.hostSocketPath, this.rootIdentity, st.ino, st.dev); } catch {}
      }
    }

    let hostSocketClean = true;
    try {
      const st = fs.lstatSync(this.hostSocketPath);
      if (st) hostSocketClean = false;
    } catch {
      hostSocketClean = true;
    }

    let lockFilePreserved = false;
    try {
      const st = fs.lstatSync(this.lockFilePath);
      if (st.isFile()) lockFilePreserved = true;
    } catch {
      lockFilePreserved = false;
    }

    this.state = 'stopped';

    return {
      status: 'stopped',
      generation: this.generation,
      daemonPid: process.pid,
      nativePid: nativePid,
      native_closed: nativeClosed,
      killEscalated: killEscalated || this.killEscalated || false,
      residueState: {
        hostSocketClean,
        lockFilePreserved
      }
    };
  }
}
