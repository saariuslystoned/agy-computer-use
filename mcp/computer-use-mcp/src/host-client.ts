import * as net from "net";
import * as fs from "fs";
import { z } from "zod";

export const IPCErrorPayloadSchema = z.object({
  code: z.string().min(1),
  message: z.string().min(1),
  details: z.record(z.unknown()).optional()
}).strict();

export const IPCResponseSchema = z.object({
  id: z.string().min(1),
  success: z.boolean(),
  data: z.record(z.unknown()).optional(),
  error: IPCErrorPayloadSchema.optional()
}).strict().refine(
  (data) => {
    if (data.success) {
      return data.data !== undefined && data.error === undefined;
    } else {
      return data.error !== undefined && data.data === undefined;
    }
  },
  { message: "IPCResponse must have 'data' when success=true, and 'error' when success=false" }
);

export type IPCResponse = z.infer<typeof IPCResponseSchema>;

export interface HostClient {
  request(method: string, params?: Record<string, unknown>, signal?: AbortSignal): Promise<IPCResponse>;
}

export class MockHostClient implements HostClient {
  public connected: boolean = true;
  public tccState: "granted" | "denied" = "granted";
  public axAvailable: boolean = false;
  public axTrusted: boolean = false;
  public inputMutationState: "enabled" | "disabled" = "disabled";
  public mockDisplayId: number = 1;

  public request: (method: string, params?: Record<string, unknown>, signal?: AbortSignal) => Promise<IPCResponse> = async (method, params) => {
    if (method === "status") {
      const topVer = "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
      return {
        id: "mock-req",
        success: true,
        data: {
          connected: this.connected,
          tcc_permission_state: this.tccState,
          accessibility_available: this.axAvailable,
          accessibility_trusted: this.axTrusted,
          input_mutation_state: this.inputMutationState,
          topology_version: topVer,
          primary_display_id: this.mockDisplayId,
          display_count: 1,
          topology: {
            version: topVer,
            primary_display_id: this.mockDisplayId,
            displays: [
              {
                id: this.mockDisplayId,
                width_points: 1920,
                height_points: 1080,
                scale_factor: 2.0,
                origin_x: 0,
                origin_y: 0,
                pixel_width: 3840,
                pixel_height: 2160,
                rotation: 0
              }
            ]
          }
        }
      };
    }

    if (method === "observe") {
      const targetId = (params?.display_id as number) ?? this.mockDisplayId;
      const topVer = "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
      const dummyJpegBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAARCABkAGQDAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/9oADAMBAAIRAxEAPwD+2AD/2Q==";

      return {
        id: "mock-obs",
        success: true,
        data: {
          capture_id: "cap-mock-001",
          timestamp: Date.now(),
          topology_version: topVer,
          display_id: targetId,
          width_points: 1920,
          height_points: 1080,
          scale_factor: 2.0,
          pixel_width: 100,
          pixel_height: 100,
          image_format: "jpeg",
          image_data_base64: dummyJpegBase64,
          normalized_bounds: {
            min_x: 0,
            min_y: 0,
            max_x: 999,
            max_y: 999
          }
        }
      };
    }

    if (["click", "move", "drag", "type", "shortcut", "scroll"].includes(method)) {
      if (this.inputMutationState === "disabled") {
        return {
          id: "mock-dis",
          success: false,
          error: {
            code: "MUTATION_DISABLED",
            message: "Input mutation is disabled in Milestone D2"
          }
        };
      }
    }

    if (method === "ax_tree") {
      return {
        id: "mock-ax",
        success: false,
        error: {
          code: "TARGET_UNREACHABLE",
          message: "AX tree inspection is disabled in Milestone D2"
        }
      };
    }

    return {
      id: "mock-unk",
      success: false,
      error: {
        code: "UNKNOWN_METHOD",
        message: `Method '${method}' is not supported`
      }
    };
  };
}

const MUTATION_METHODS = new Set(["click", "move", "drag", "type", "shortcut", "scroll"]);

export function getDefaultSocketPath(): string {
  const uid = process.getuid ? process.getuid() : 501;
  return process.env.AGY_SOCKET_PATH || `/private/tmp/agy-computer-use-${uid}/host.sock`;
}

export class UnixSocketHostClient implements HostClient {
  private socketPath: string;
  private timeoutMs: number;

  constructor(socketPath?: string, timeoutMs: number = 5000) {
    this.socketPath = socketPath || (getDefaultSocketPath() as string);
    this.timeoutMs = timeoutMs;
  }

  public async request(method: string, params?: Record<string, unknown>, signal?: AbortSignal): Promise<IPCResponse> {
    if (signal?.aborted) {
      return {
        id: "cancelled",
        success: false,
        error: { code: "CANCELLED", message: "Request was cancelled before dispatch" }
      };
    }

    if (!fs.existsSync(this.socketPath)) {
      return {
        id: "no-socket",
        success: false,
        error: {
          code: "TARGET_UNREACHABLE",
          message: `Unix domain socket not found at ${this.socketPath}`
        }
      };
    }

    return new Promise<IPCResponse>((resolve) => {
      const reqId = `req-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`;
      let client: net.Socket | null = null;
      let isDispatched = false;
      let isSettled = false;

      const finish = (response: IPCResponse) => {
        if (isSettled) return;
        isSettled = true;
        if (client) {
          client.destroy();
          client = null;
        }
        resolve(response);
      };

      const timer = setTimeout(() => {
        if (isDispatched && MUTATION_METHODS.has(method)) {
          finish({
            id: reqId,
            success: false,
            error: {
              code: "ACTION_OUTCOME_UNKNOWN",
              message: `Mutation request '${method}' timed out after socket write; action outcome is unknown. A fresh computer_use_observe snapshot is required.`
            }
          });
        } else {
          finish({
            id: reqId,
            success: false,
            error: {
              code: "TIMEOUT",
              message: `IPC request '${method}' timed out after ${this.timeoutMs}ms`
            }
          });
        }
      }, this.timeoutMs);

      const abortHandler = () => {
        clearTimeout(timer);
        if (isDispatched && MUTATION_METHODS.has(method)) {
          finish({
            id: reqId,
            success: false,
            error: {
              code: "ACTION_OUTCOME_UNKNOWN",
              message: `Mutation request '${method}' aborted after socket write; action outcome is unknown. A fresh computer_use_observe snapshot is required.`
            }
          });
        } else {
          finish({
            id: reqId,
            success: false,
            error: {
              code: "CANCELLED",
              message: `IPC request '${method}' was cancelled`
            }
          });
        }
      };

      if (signal) {
        signal.addEventListener("abort", abortHandler, { once: true });
      }

      client = net.createConnection(this.socketPath, () => {
        const payloadObj = {
          id: reqId,
          method,
          ...(params ? { params } : {})
        };
        const payloadJson = JSON.stringify(payloadObj);
        const payloadBuf = Buffer.from(payloadJson, "utf-8");

        if (payloadBuf.length > 16 * 1024 * 1024) {
          clearTimeout(timer);
          finish({
            id: reqId,
            success: false,
            error: { code: "REQUEST_TOO_LARGE", message: "Request payload exceeds 16MB" }
          });
          return;
        }

        const headerBuf = Buffer.alloc(4);
        headerBuf.writeUInt32BE(payloadBuf.length, 0);
        const msgBuf = Buffer.concat([headerBuf, payloadBuf]);

        // Set uncertainty flag synchronously BEFORE socket write
        if (MUTATION_METHODS.has(method)) {
          isDispatched = true;
        }

        client?.write(msgBuf, (err) => {
          if (err) {
            clearTimeout(timer);
            if (isDispatched) {
              finish({
                id: reqId,
                success: false,
                error: { code: "ACTION_OUTCOME_UNKNOWN", message: `Socket write error after dispatch: ${err.message}` }
              });
            } else {
              finish({
                id: reqId,
                success: false,
                error: { code: "IPC_ERROR", message: `Socket write error: ${err.message}` }
              });
            }
          }
        });
      });

      let responseBuffer = Buffer.alloc(0);
      let expectedLen: number | null = null;

      client.on("data", (chunk: Buffer) => {
        responseBuffer = Buffer.concat([responseBuffer, chunk]);

        if (expectedLen === null) {
          if (responseBuffer.length >= 4) {
            expectedLen = responseBuffer.readUInt32BE(0);
            if (expectedLen > 16 * 1024 * 1024) {
              clearTimeout(timer);
              if (isDispatched) {
                finish({
                  id: reqId,
                  success: false,
                  error: { code: "ACTION_OUTCOME_UNKNOWN", message: `Oversized response payload length ${expectedLen} after mutation dispatch` }
                });
              } else {
                finish({
                  id: reqId,
                  success: false,
                  error: { code: "RESPONSE_TOO_LARGE", message: `Response payload length ${expectedLen} exceeds 16MB limit` }
                });
              }
              return;
            }
          }
        }

        if (expectedLen !== null && responseBuffer.length >= 4 + expectedLen) {
          clearTimeout(timer);
          const jsonBuf = responseBuffer.subarray(4, 4 + expectedLen);
          try {
            const rawObj = JSON.parse(jsonBuf.toString("utf-8"));
            const parsedResp = IPCResponseSchema.parse(rawObj);
            if (parsedResp.id !== reqId) {
              if (isDispatched) {
                finish({
                  id: reqId,
                  success: false,
                  error: { code: "ACTION_OUTCOME_UNKNOWN", message: `Response ID mismatch '${parsedResp.id}' after mutation dispatch` }
                });
              } else {
                finish({
                  id: reqId,
                  success: false,
                  error: { code: "ID_MISMATCH", message: `IPC response ID '${parsedResp.id}' does not match request ID '${reqId}'` }
                });
              }
              return;
            }
            finish(parsedResp);
          } catch (parseErr: any) {
            if (isDispatched) {
              finish({
                id: reqId,
                success: false,
                error: { code: "ACTION_OUTCOME_UNKNOWN", message: `Response parse error after mutation dispatch: ${parseErr.message}` }
              });
            } else {
              finish({
                id: reqId,
                success: false,
                error: { code: "INVALID_RESPONSE", message: `Failed to parse IPC response JSON: ${parseErr.message}` }
              });
            }
          }
        }
      });

      client.on("error", (err) => {
        clearTimeout(timer);
        if (isDispatched) {
          finish({
            id: reqId,
            success: false,
            error: { code: "ACTION_OUTCOME_UNKNOWN", message: `IPC socket error after dispatch: ${err.message}` }
          });
        } else {
          finish({
            id: reqId,
            success: false,
            error: { code: "IPC_ERROR", message: `IPC socket error: ${err.message}` }
          });
        }
      });

      client.on("end", () => {
        if (!isSettled && (expectedLen === null || responseBuffer.length < 4 + expectedLen)) {
          clearTimeout(timer);
          if (isDispatched) {
            finish({
              id: reqId,
              success: false,
              error: { code: "ACTION_OUTCOME_UNKNOWN", message: "Socket closed after mutation dispatch; action outcome is unknown." }
            });
          } else {
            finish({
              id: reqId,
              success: false,
              error: { code: "EOF", message: "IPC socket closed before complete response payload was received" }
            });
          }
        }
      });
    });
  }
}
