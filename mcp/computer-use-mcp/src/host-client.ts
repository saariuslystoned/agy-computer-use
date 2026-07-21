import * as net from "net";
import { Logger } from "./logger.js";

export interface IPCRequestPayload {
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

export interface IPCResponsePayload {
  id: string;
  success: boolean;
  data?: Record<string, unknown>;
  error?: {
    code: string;
    message: string;
    details?: Record<string, string>;
  };
}

export interface HostClient {
  request(method: string, params?: Record<string, unknown>): Promise<IPCResponsePayload>;
}

/**
 * MockHostClient provides a deterministic test host implementation
 * matching the Swift HostServer protocol behavior for Node unit and integration tests.
 */
export class MockHostClient implements HostClient {
  private latestCaptureId: string | null = null;
  private reqCounter = 1;

  public async request(method: string, params?: Record<string, unknown>): Promise<IPCResponsePayload> {
    const id = `req-${this.reqCounter++}`;

    switch (method) {
      case "status":
        return {
          id,
          success: true,
          data: {
            connected: true,
            topology_version: "top-v1",
            primary_display_id: 1,
            display_count: 1,
            tcc_permission_state: "fake_granted"
          }
        };

      case "observe": {
        const capId = `cap-${String(this.reqCounter).padStart(4, "0")}`;
        this.latestCaptureId = capId;
        return {
          id,
          success: true,
          data: {
            capture_id: capId,
            timestamp: Date.now(),
            topology_version: "top-v1",
            display_id: (params?.display_id as number) ?? 1,
            width_points: 1920,
            height_points: 1080,
            scale_factor: 2.0,
            image_format: "jpeg",
            image_data_base64: "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP...",
            normalized_bounds: { min_x: 0, min_y: 0, max_x: 999, max_y: 999 }
          }
        };
      }

      case "ax_tree":
        return {
          id,
          success: true,
          data: {
            id: "app-root",
            role: "AXApplication",
            title: (params?.app_id as string) ?? "Finder",
            bounds: { x: 0, y: 0, width: 1920, height: 1080 },
            children: [
              {
                id: "win-1",
                role: "AXWindow",
                title: "Main Window",
                bounds: { x: 100, y: 100, width: 800, height: 600 },
                children: [
                  {
                    id: "input-pass",
                    role: "AXTextField",
                    subrole: "AXSecureTextField",
                    title: "Password Input",
                    value: "[REDACTED]",
                    bounds: { x: 300, y: 500, width: 200, height: 30 }
                  }
                ]
              }
            ]
          }
        };

      case "click":
      case "move":
      case "drag":
      case "type":
      case "shortcut":
      case "scroll": {
        const capId = params?.capture_id as string;
        if (!capId || capId !== this.latestCaptureId) {
          return {
            id,
            success: false,
            error: {
              code: "STALE_CAPTURE",
              message: `Capture precondition failed. Current capture: ${this.latestCaptureId}, received: ${capId}`
            }
          };
        }
        return {
          id,
          success: true,
          data: {
            action_id: `act-${method}-${this.reqCounter}`,
            status: "verified",
            capture_id: capId,
            duration_ms: 15.0
          }
        };
      }

      default:
        return {
          id,
          success: false,
          error: {
            code: "UNKNOWN_METHOD",
            message: `Unknown method '${method}'`
          }
        };
    }
  }
}

/**
 * UnixSocketHostClient connects to the native ComputerUseHost Unix domain socket.
 */
export class UnixSocketHostClient implements HostClient {
  private socketPath: string;
  private reqCounter = 1;

  constructor(socketPath?: string) {
    const uid = process.getuid ? process.getuid() : 501;
    this.socketPath = socketPath ?? `/tmp/agy-computer-use-${uid}/agy-computer-use.sock`;
  }

  public async request(method: string, params?: Record<string, unknown>): Promise<IPCResponsePayload> {
    return new Promise((resolve, reject) => {
      const id = `req-${this.reqCounter++}`;
      const payload: IPCRequestPayload = { id, method, params };
      const jsonStr = JSON.stringify(payload);
      const jsonBuf = Buffer.from(jsonStr, "utf-8");

      const headerBuf = Buffer.alloc(4);
      headerBuf.writeUInt32BE(jsonBuf.length, 0);
      const msgBuf = Buffer.concat([headerBuf, jsonBuf]);

      const client = net.createConnection({ path: this.socketPath }, () => {
        client.write(msgBuf);
      });

      let incoming = Buffer.alloc(0);

      client.on("data", (chunk) => {
        incoming = Buffer.concat([incoming, chunk]);
        if (incoming.length >= 4) {
          const bodyLen = incoming.readUInt32BE(0);
          if (incoming.length >= 4 + bodyLen) {
            const bodyBuf = incoming.subarray(4, 4 + bodyLen);
            client.end();
            try {
              const response = JSON.parse(bodyBuf.toString("utf-8")) as IPCResponsePayload;
              resolve(response);
            } catch (err) {
              reject(err);
            }
          }
        }
      });

      client.on("error", (err) => {
        Logger.warn(`IPC socket connection to ${this.socketPath} failed: ${err.message}`);
        resolve({
          id,
          success: false,
          error: {
            code: "HOST_UNAVAILABLE",
            message: `Native host unavailable at ${this.socketPath}. Details: ${err.message}`
          }
        });
      });
    });
  }
}
