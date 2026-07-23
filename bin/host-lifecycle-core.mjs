import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { stageHostApp, classifyPrincipal } from './host-app.mjs';

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

export function safeUnlinkSocket(socketPath, rootIdentity, socketIdentity) {
  if (!rootIdentity || typeof rootIdentity !== 'object' || rootIdentity.uid === undefined || rootIdentity.dev === undefined || rootIdentity.ino === undefined) {
    throw new Error(`safeUnlinkSocket requires mandatory captured rootIdentity {uid, dev, ino}`);
  }
  if (!socketIdentity || typeof socketIdentity !== 'object' || socketIdentity.uid === undefined || socketIdentity.uid === null || socketIdentity.type === undefined || socketIdentity.type === null || socketIdentity.ino === undefined || socketIdentity.dev === undefined || socketIdentity.ino === null || socketIdentity.dev === null) {
    throw new Error(`safeUnlinkSocket requires mandatory captured socketIdentity {uid, type, dev, ino}`);
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
  if (socketIdentity.uid !== undefined && socketIdentity.uid !== null && st.uid !== socketIdentity.uid) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: UID mismatch (expected ${socketIdentity.uid}, got ${st.uid})`);
  }
  if (socketIdentity.type !== undefined && socketIdentity.type !== null && socketIdentity.type === 'socket' && !st.isSocket()) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: type mismatch (expected socket, got non-socket)`);
  }
  if (socketIdentity.ino !== undefined && socketIdentity.ino !== null && st.ino !== socketIdentity.ino) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: inode mismatch (expected ${socketIdentity.ino}, got ${st.ino})`);
  }
  if (socketIdentity.dev !== undefined && socketIdentity.dev !== null && st.dev !== socketIdentity.dev) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: device mismatch (expected ${socketIdentity.dev}, got ${st.dev})`);
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

    const payloadJsonStr = JSON.stringify(requestObj);
    const payloadBuf = Buffer.from(payloadJsonStr, 'utf-8');
    const MAX_PAYLOAD_SIZE = 16 * 1024 * 1024;
    if (payloadBuf.length > MAX_PAYLOAD_SIZE) {
      return reject(new Error(`IPC request payload size ${payloadBuf.length} bytes exceeds 16MB limit`));
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
        client.removeAllListeners();
        client.destroy();
        client = null;
      }
    };

    client = net.createConnection(socketPath, () => {
      const headerBuf = Buffer.alloc(4);
      headerBuf.writeUInt32BE(payloadBuf.length, 0);
      client.write(Buffer.concat([headerBuf, payloadBuf]));
    });

    let rxBuf = Buffer.alloc(0);

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
          if (rxBuf.length > 4 + msgLen) {
            cleanup();
            if (settled) return;
            settled = true;
            reject(new Error(`Trailing data in frame beyond ${4 + msgLen} bytes`));
            return;
          }
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
    this.stagedAppDir = options.stagedAppDir || null;
    this.binaryPath = options.binaryPath || null;
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
      if (res && res.success && res.data && typeof res.data === 'object') {
        const d = res.data;
        if (
          typeof d.generation === 'string' &&
          typeof d.daemonPid === 'number' &&
          (d.nativePid === null || typeof d.nativePid === 'number') &&
          ['starting', 'running', 'stopping'].includes(d.status)
        ) {
          if (d.status === 'running') {
            if (!d.native) {
              return { alive: false, reason: 'running owner without embedded native observation must be rejected', raw: res };
            }
            if (!validateStatusResponseSchema({ id: res.id, success: true, data: d.native })) {
              return { alive: false, reason: 'invalid_native_schema', raw: res };
            }
          }
          return { alive: true, data: d };
        }
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
          safeUnlinkSocket(this.controlSocketPath, this.rootIdentity, {
            uid: existingControlSt.uid,
            type: 'socket',
            ino: existingControlSt.ino,
            dev: existingControlSt.dev
          });
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
      let settled = false;

      const connTimer = setTimeout(() => {
        if (!settled) {
          settled = true;
          socket.destroy();
        }
      }, 2000);

      const cleanupConn = () => {
        clearTimeout(connTimer);
        this.activeConnections.delete(socket);
      };
      socket.on('close', cleanupConn);
      socket.on('error', cleanupConn);

      let rxBuf = Buffer.alloc(0);
      let handledFrame = false;
      const MAX_PAYLOAD = 16 * 1024 * 1024;

      socket.on('data', (chunk) => {
        if (handledFrame || settled) {
          socket.destroy();
          return;
        }
        rxBuf = Buffer.concat([rxBuf, chunk]);
        if (rxBuf.length >= 4) {
          const msgLen = rxBuf.readUInt32BE(0);
          if (msgLen > MAX_PAYLOAD) {
            settled = true;
            socket.destroy();
            return;
          }
          if (rxBuf.length >= 4 + msgLen) {
            handledFrame = true;
            if (rxBuf.length > 4 + msgLen) {
              settled = true;
              const errResp = { id: null, success: false, error: { code: 'BAD_REQUEST', message: 'Trailing data in frame' } };
              const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]), () => {
                try { socket.destroy(); } catch {}
              });
              return;
            }
            try { socket.pause(); } catch {}

            let req;
            try {
              const payloadJson = rxBuf.subarray(4, 4 + msgLen).toString('utf-8');
              req = JSON.parse(payloadJson);
            } catch (err) {
              settled = true;
              const errResp = { id: null, success: false, error: { code: 'BAD_REQUEST', message: err.message } };
              const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]), () => {
                try { socket.destroy(); } catch {}
              });
              return;
            }

            if (!req || typeof req !== 'object' || req.id === undefined || req.id === null) {
              settled = true;
              const errResp = { id: null, success: false, error: { code: 'BAD_REQUEST', message: 'Missing request id' } };
              const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]), () => {
                try { socket.destroy(); } catch {}
              });
              return;
            }

            this.handleControlRequest(req).then((respObj) => {
              if (settled) return;
              settled = true;
              const respBuf = Buffer.from(JSON.stringify(respObj), 'utf-8');
              if (respBuf.length > MAX_PAYLOAD) {
                socket.destroy();
                return;
              }
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]), () => {
                try { socket.end(); } catch {}
                if (req.method === 'stop') {
                  let teardownDone = false;
                  const triggerTeardown = () => {
                    if (teardownDone) return;
                    teardownDone = true;
                    setImmediate(() => {
                      this._finalizeDaemonTeardown();
                    });
                  };
                  socket.once('close', triggerTeardown);
                  socket.once('finish', triggerTeardown);
                  setTimeout(triggerTeardown, 1000);
                }
              });
            }).catch((err) => {
              if (settled) return;
              settled = true;
              const errResp = { id: req.id, success: false, error: { code: 'INTERNAL_ERROR', message: err.message } };
              const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]), () => {
                try { socket.destroy(); } catch {}
              });
            });
          }
        }
      });
    });

    server.on('error', (err) => {
      if (this.state === 'starting' || this.state === 'running') {
        this.stop().then(() => this.finalizeDaemonTeardown()).catch(() => this.finalizeDaemonTeardown());
      }
      reject(err);
    });

    server.listen(this.controlSocketPath, () => {
      try {
        fs.chmodSync(this.controlSocketPath, 0o700);
        const st = fs.lstatSync(this.controlSocketPath);
        this.controlSocketIno = st.ino;
        this.controlSocketDev = st.dev;
      } catch (err) {
        reject(err);
        return;
      }
      this.controlServer = server;
      resolve();
    });
  }

  async finalizeDaemonTeardown() {
    this.removeSignalListeners();
    if (this.activeConnections) {
      for (const sock of this.activeConnections) {
        try { sock.destroy(); } catch {}
      }
      this.activeConnections.clear();
    }
    const server = this.controlServer;
    this.controlServer = null;
    if (server) {
      await new Promise((resolve, reject) => {
        try {
          server.close((err) => {
            if (err) reject(err);
            else resolve();
          });
        } catch (err) {
          reject(err);
        }
      });
    }
    if (this.controlSocketIno !== null && this.controlSocketDev !== null && this.rootIdentity) {
      const socketUid = this.rootIdentity.uid;
      safeUnlinkSocket(this.controlSocketPath, this.rootIdentity, { uid: socketUid, type: 'socket', ino: this.controlSocketIno, dev: this.controlSocketDev });
    }
    if (this.isDaemonProcess) {
      process.exit(0);
    }
  }

  _finalizeDaemonTeardown() {
    this.finalizeDaemonTeardown().catch(() => {});
  }

  removeSignalListeners() {
    if (this.signalCleanup) {
      process.removeListener('SIGTERM', this.signalCleanup);
      process.removeListener('SIGINT', this.signalCleanup);
      process.removeListener('SIGHUP', this.signalCleanup);
      this.signalCleanup = null;
    }
  }

  async handleControlRequest(req) {
    if (!req || typeof req !== 'object' || req.id === undefined || req.id === null) {
      return {
        id: null,
        success: false,
        error: { code: 'BAD_REQUEST', message: 'Missing request id' }
      };
    }

    const reqId = req.id;
    const method = req.method;

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

  async validateStagedHostApp(stagedAppDir = null, binaryPath = null) {
    const targetAppDir = stagedAppDir || this.stagedAppDir || (binaryPath || this.binaryPath ? null : path.join(REPO_ROOT, 'apps/computer-use-host/.build/staged/ComputerUseHost.app'));
    const targetBinaryPath = binaryPath || this.binaryPath || (targetAppDir ? path.join(targetAppDir, 'Contents/MacOS/ComputerUseHost') : null);

    if (!targetAppDir && targetBinaryPath) {
      if (!fs.existsSync(targetBinaryPath)) {
        throw new Error(`Staged binary does not exist at ${targetBinaryPath}. Please stage the host application first using './bin/agy-computer-use stage-host-app'.`);
      }
      return;
    }

    if (!targetAppDir || !fs.existsSync(targetAppDir)) {
      throw new Error(`Staged host application is absent at ${targetAppDir || 'unknown path'}. Please stage the host application first using './bin/agy-computer-use stage-host-app'.`);
    }

    const infoPlist = path.join(targetAppDir, 'Contents/Info.plist');
    if (!fs.existsSync(targetBinaryPath) || !fs.existsSync(infoPlist)) {
      throw new Error(`Staged host application at ${targetAppDir} is missing executable binary or Info.plist. Please stage the host application first using './bin/agy-computer-use stage-host-app'.`);
    }

    const principal = await classifyPrincipal(targetAppDir);
    if (principal.classification === 'unsigned_or_invalid') {
      throw new Error(`Staged host application at ${targetAppDir} is invalid or unsigned (${principal.details || 'codesign failed'}). Please stage the host application first using './bin/agy-computer-use stage-host-app'.`);
    }
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

    const stagedAppDir = options.stagedAppDir || this.stagedAppDir || (options.binaryPath || this.binaryPath ? null : path.join(REPO_ROOT, 'apps/computer-use-host/.build/staged/ComputerUseHost.app'));
    const binaryPath = options.binaryPath || this.binaryPath || (stagedAppDir ? path.join(stagedAppDir, 'Contents/MacOS/ComputerUseHost') : null);

    await this.validateStagedHostApp(stagedAppDir, binaryPath);

    await this.startControlServer();
    this.state = 'starting';

    this.signalCleanup = () => {
      if (!this.stoppingFromSignal) {
        this.stoppingFromSignal = true;
        this.stop().then(() => {
          this._finalizeDaemonTeardown();
        }).catch(() => {
          this._finalizeDaemonTeardown();
        });
      }
    };
    process.once('SIGTERM', this.signalCleanup);
    process.once('SIGINT', this.signalCleanup);
    process.once('SIGHUP', this.signalCleanup);

    try {
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
        if (this.state === 'running' && !this.cleanupPromise) {
          this.stop().then(() => this.finalizeDaemonTeardown()).catch(() => this.finalizeDaemonTeardown());
        }
      });

      proc.on('error', (err) => {
        // Record error without replacing close as authority
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

      const hostSt = fs.lstatSync(this.hostSocketPath);
      this.hostSocketIno = hostSt.ino;
      this.hostSocketDev = hostSt.dev;

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
      try { await this.stop(); } catch {}
      try { await this.finalizeDaemonTeardown(); } catch {}
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
    this.removeSignalListeners();
    this.state = 'stopping';

    const nativePid = this.child?.pid || null;
    let nativeClosed = false;
    let killEscalated = false;

    if (this.child) {
      const proc = this.child;

      let childPromise = this.childClosedPromise;
      if (!childPromise) {
        childPromise = new Promise((resolve) => {
          proc.on('close', (code, signal) => resolve({ code, signal }));
        });
      }

      let graceTimer = null;
      const timeoutPromise = new Promise((r) => {
        graceTimer = setTimeout(() => r('timed_out'), Math.min(stopTimeoutMs, 2000));
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

        let killTimer = null;
        const killTimeoutPromise = new Promise((r) => {
          killTimer = setTimeout(() => r('kill_timed_out'), 100);
        });
        const killRes = await Promise.race([childPromise, killTimeoutPromise]);
        if (killTimer) clearTimeout(killTimer);
        if (killRes === 'kill_timed_out') {
          nativeClosed = false;
        } else {
          nativeClosed = true;
        }
      } else {
        nativeClosed = true;
      }
      if (!nativeClosed) {
        this.cleanupPromise = null;
        throw new Error('Native child process failed to close after bounded TERM/KILL waits');
      }
      this.child = null;
    } else {
      nativeClosed = true;
    }

    let hostSocketClean = true;
    if (this.hostSocketIno !== null && this.hostSocketDev !== null && this.rootIdentity) {
      try {
        const socketUid = this.rootIdentity.uid;
        safeUnlinkSocket(this.hostSocketPath, this.rootIdentity, { uid: socketUid, type: 'socket', ino: this.hostSocketIno, dev: this.hostSocketDev });
      } catch (err) {
        if (err.code !== 'ENOENT') hostSocketClean = false;
      }
    }

    try {
      const st = fs.lstatSync(this.hostSocketPath);
      if (st) hostSocketClean = false;
    } catch (err) {
      if (err.code === 'ENOENT') {
        hostSocketClean = true;
      } else {
        hostSocketClean = false;
      }
    }

    let lockFilePreserved = false;
    try {
      const st = fs.lstatSync(this.lockFilePath);
      lockFilePreserved = st.isFile() && !st.isSymbolicLink() && (st.mode & 0o077) === 0;
    } catch {
      lockFilePreserved = false;
    }

    if (!hostSocketClean || !lockFilePreserved) {
      throw new Error(`Teardown residue check failed: hostSocketClean=${hostSocketClean}, lockFilePreserved=${lockFilePreserved}`);
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
