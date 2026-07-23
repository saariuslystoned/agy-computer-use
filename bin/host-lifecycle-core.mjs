import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { stageHostApp } from './host-app.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

export function getCanonicalRuntimeDir() {
  const uid = process.getuid ? process.getuid() : 501;
  const runtimeDir = process.env.COMPUTER_USE_RUNTIME_DIR || `/tmp/agy-computer-use-${uid}`;

  let st;
  try {
    st = fs.lstatSync(runtimeDir);
  } catch (err) {
    if (err.code === 'ENOENT') {
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
  if ((st.mode & 0o077) !== 0) {
    fs.chmodSync(runtimeDir, 0o700);
  }

  return runtimeDir;
}

export function getCanonicalSocketPaths(customDir) {
  const baseDir = customDir || getCanonicalRuntimeDir();
  return {
    runtimeDir: baseDir,
    hostSocketPath: path.join(baseDir, 'host.sock'),
    controlSocketPath: path.join(baseDir, 'control.sock'),
    lockFilePath: path.join(baseDir, 'host.lock')
  };
}

export function safeUnlinkSocket(socketPath, expectedIno = null, expectedDev = null) {
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
  if (expectedIno !== null && st.ino !== expectedIno) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: inode mismatch (expected ${expectedIno}, got ${st.ino})`);
  }
  if (expectedDev !== null && st.dev !== expectedDev) {
    throw new Error(`Refusing to unlink socket at ${socketPath}: device mismatch (expected ${expectedDev}, got ${st.dev})`);
  }
  fs.unlinkSync(socketPath);
  return true;
}

export function sendFramedIPCRequest(socketPath, requestObj, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
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
    const MAX_PAYLOAD_SIZE = 16 * 1024 * 1024; // 16MB

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
            if (requestObj.id !== undefined && parsed.id !== undefined && String(parsed.id) !== String(requestObj.id)) {
              reject(new Error(`IPC response ID mismatch: expected ${requestObj.id}, got ${parsed.id}`));
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
    this.runtimeDir = options.runtimeDir || getCanonicalRuntimeDir();
    const paths = getCanonicalSocketPaths(this.runtimeDir);
    this.hostSocketPath = paths.hostSocketPath;
    this.controlSocketPath = paths.controlSocketPath;
    this.lockFilePath = paths.lockFilePath;

    this.child = null;
    this.controlServer = null;
    this.controlSocketIno = null;
    this.controlSocketDev = null;
    this.childClosedPromise = null;
    this.childClosedResolver = null;
    this.cleanupPromise = null;
    this.stoppingFromSignal = false;
    this.state = 'stopped';
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
      if (res && res.success && res.data?.status === 'running') {
        return { alive: true, data: res.data };
      }
      return { alive: false, reason: 'control_not_running' };
    } catch (err) {
      return { alive: false, reason: err.message };
    }
  }

  startControlServer() {
    return new Promise((resolve, reject) => {
      // If control socket path exists, probe if alive
      let existingSt = null;
      try {
        existingSt = fs.lstatSync(this.controlSocketPath);
      } catch (e) {}

      if (existingSt) {
        if (existingSt.isSymbolicLink() || !existingSt.isSocket()) {
          return reject(new Error(`Control socket path ${this.controlSocketPath} exists and is not a plain UNIX socket`));
        }
        // Probe if active
        this.checkControlStatus(300).then((ctrlProbe) => {
          if (ctrlProbe.alive) {
            return reject(new Error(`Active supervisor control server already running on ${this.controlSocketPath}`));
          }
          // Dead socket, safe unlink
          try {
            safeUnlinkSocket(this.controlSocketPath);
          } catch (unlinkErr) {
            return reject(unlinkErr);
          }
          this._bindControlServer(resolve, reject);
        }).catch(() => {
          try {
            safeUnlinkSocket(this.controlSocketPath);
          } catch (unlinkErr) {
            return reject(unlinkErr);
          }
          this._bindControlServer(resolve, reject);
        });
      } else {
        this._bindControlServer(resolve, reject);
      }
    });
  }

  _bindControlServer(resolve, reject) {
    const server = net.createServer((socket) => {
      let rxBuf = Buffer.alloc(0);
      const MAX_PAYLOAD = 16 * 1024 * 1024;
      socket.on('data', (chunk) => {
        rxBuf = Buffer.concat([rxBuf, chunk]);
        if (rxBuf.length >= 4) {
          const msgLen = rxBuf.readUInt32BE(0);
          if (msgLen > MAX_PAYLOAD) {
            socket.destroy();
            return;
          }
          if (rxBuf.length >= 4 + msgLen) {
            const payloadJson = rxBuf.subarray(4, 4 + msgLen).toString('utf-8');
            try {
              const req = JSON.parse(payloadJson);
              this.handleControlRequest(req).then((respObj) => {
                const respBuf = Buffer.from(JSON.stringify(respObj), 'utf-8');
                const headBuf = Buffer.alloc(4);
                headBuf.writeUInt32BE(respBuf.length, 0);
                socket.write(Buffer.concat([headBuf, respBuf]), () => {
                  if (req?.method === 'stop') {
                    // Drain and close after stop request
                    socket.end();
                  }
                });
              });
            } catch (err) {
              const errResp = { id: 'err', success: false, error: { code: 'BAD_REQUEST', message: err.message } };
              const respBuf = Buffer.from(JSON.stringify(errResp), 'utf-8');
              const headBuf = Buffer.alloc(4);
              headBuf.writeUInt32BE(respBuf.length, 0);
              socket.write(Buffer.concat([headBuf, respBuf]));
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

  async handleControlRequest(req) {
    const reqId = req?.id || 'ctrl-req';
    const method = req?.method;

    if (method === 'status') {
      const native = await this.checkNativeStatus(1000);
      return {
        id: reqId,
        success: true,
        data: {
          status: native.alive ? 'running' : 'unhealthy',
          pid: this.child?.pid || null,
          daemonPid: process.pid,
          native: native.data || null
        }
      };
    }

    if (method === 'stop') {
      // Schedule asynchronous teardown so response can flush
      setImmediate(() => {
        this.stop().then(() => {
          process.exit(0);
        }).catch(() => {
          process.exit(1);
        });
      });
      return {
        id: reqId,
        success: true,
        data: { status: 'stopped' }
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
          pid: this.child.pid,
          socketPath: this.hostSocketPath,
          tcc_permission_state: native.data.tcc_permission_state
        };
      }
    }

    // 1. Atomically reserve & bind control socket first before staging/spawning!
    await this.startControlServer();
    this.state = 'starting';

    // Trap signals on daemon process for automatic teardown
    const cleanupSignal = () => {
      if (!this.stoppingFromSignal) {
        this.stoppingFromSignal = true;
        this.stop().then(() => process.exit(0)).catch(() => process.exit(1));
      }
    };
    process.once('SIGTERM', cleanupSignal);
    process.once('SIGINT', cleanupSignal);
    process.once('SIGHUP', cleanupSignal);

    try {
      const defaultBinary = path.join(REPO_ROOT, 'apps/computer-use-host/.build/staged/ComputerUseHost.app/Contents/MacOS/ComputerUseHost');
      let binaryPath = options.binaryPath || defaultBinary;

      if (!fs.existsSync(binaryPath) || options.stage === true) {
        const stagedResult = await stageHostApp({ build: options.build ?? false });
        binaryPath = stagedResult.binaryPath;
      }
      if (!fs.existsSync(binaryPath)) {
        throw new Error(`Staged binary does not exist at ${binaryPath}`);
      }

      // Track child exit
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

      // Poll native status
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

      this.state = 'running';
      return {
        status: 'running',
        idempotent: false,
        pid: proc.pid,
        socketPath: this.hostSocketPath,
        tcc_permission_state: lastNativeData.tcc_permission_state
      };
    } catch (err) {
      await this.stop();
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
    this.state = 'stopped';

    // 1. Teardown child process if present
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

        try {
          proc.kill('SIGTERM');
        } catch {}

        const timeoutPromise = new Promise((r) => setTimeout(() => r('timed_out'), stopTimeoutMs));
        const res = await Promise.race([childPromise, timeoutPromise]);

        if (res === 'timed_out') {
          try {
            proc.kill('SIGKILL');
          } catch {}
          await childPromise;
        }
      }
    }

    // 2. Close control server
    if (this.controlServer) {
      try {
        await new Promise((r) => this.controlServer.close(r));
      } catch {}
      this.controlServer = null;
    }

    // 3. Clean up sockets safely
    if (fs.existsSync(this.controlSocketPath)) {
      try {
        safeUnlinkSocket(this.controlSocketPath, this.controlSocketIno, this.controlSocketDev);
      } catch {}
    }
    if (fs.existsSync(this.hostSocketPath)) {
      try {
        safeUnlinkSocket(this.hostSocketPath);
      } catch {}
    }

    return { status: 'stopped', idempotent: false };
  }
}
