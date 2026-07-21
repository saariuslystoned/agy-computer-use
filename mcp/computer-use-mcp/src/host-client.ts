import * as net from "net";
import { z } from "zod";
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

export const IPCResponseSchema = z.object({
  id: z.string().min(1),
  success: z.boolean(),
  data: z.record(z.unknown()).optional(),
  error: z.object({
    code: z.string().min(1),
    message: z.string().min(1),
    details: z.record(z.string()).optional()
  }).optional()
}).refine(res => {
  if (res.success) {
    return res.data !== undefined && res.error === undefined;
  } else {
    return res.data === undefined && res.error !== undefined;
  }
}, {
  message: "IPCResponse must contain data XOR error consistent with success boolean"
});

export interface HostClient {
  request(method: string, params?: Record<string, unknown>, signal?: AbortSignal): Promise<IPCResponsePayload>;
}

const MAX_FRAME_SIZE = 16 * 1024 * 1024; // 16 MB max payload limit
const MUTATION_METHODS = new Set(["click", "move", "drag", "type", "shortcut", "scroll"]);
const VALID_DUMMY_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";
const MOCK_TOPOLOGY_VERSION = "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

export class MockHostClient implements HostClient {
  private latestCaptureId: string | null = null;
  private reqCounter = 1;
  public inputMutationState: "enabled" | "disabled" = "disabled";
  public axAvailable = false;

  public async request(method: string, params?: Record<string, unknown>, signal?: AbortSignal): Promise<IPCResponsePayload> {
    const id = `req-${this.reqCounter++}`;
    if (signal?.aborted) {
      return {
        id,
        success: false,
        error: { code: "CANCELLED", message: "IPC request cancelled before execution" }
      };
    }

    if (method === "status") {
      return {
        id,
        success: true,
        data: {
          connected: true,
          tcc_permission_state: "granted",
          accessibility_available: this.axAvailable,
          accessibility_trusted: false,
          input_mutation_state: this.inputMutationState,
          topology_version: MOCK_TOPOLOGY_VERSION,
          primary_display_id: 1,
          display_count: 1,
          topology: {
            version: MOCK_TOPOLOGY_VERSION,
            primary_display_id: 1,
            displays: [
              {
                id: 1,
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
      if (params?.display_id !== undefined && (typeof params.display_id !== "number" || !Number.isInteger(params.display_id))) {
        return { id, success: false, error: { code: "IPC_ERROR", message: "display_id parameter must be an integer" } };
      }

      const capId = `cap-mock-${Date.now()}`;
      this.latestCaptureId = capId;
      return {
        id,
        success: true,
        data: {
          capture_id: capId,
          timestamp: Date.now(),
          topology_version: MOCK_TOPOLOGY_VERSION,
          display_id: 1,
          width_points: 1920,
          height_points: 1080,
          scale_factor: 2.0,
          pixel_width: 3840,
          pixel_height: 2160,
          image_format: "jpeg",
          image_data_base64: VALID_DUMMY_JPEG_BASE64,
          normalized_bounds: { min_x: 0, min_y: 0, max_x: 999, max_y: 999 }
        }
      };
    }

    if (method === "ax_tree") {
      return {
        id,
        success: false,
        error: { code: "TARGET_UNREACHABLE", message: "AX tree inspection is unavailable in this build phase" }
      };
    }

    if (MUTATION_METHODS.has(method)) {
      return {
        id,
        success: false,
        error: { code: "MUTATION_DISABLED", message: "Input mutations are disabled in this build phase." }
      };
    }

    return {
      id,
      success: false,
      error: { code: "UNKNOWN_METHOD", message: `Method '${method}' not supported` }
    };
  }
}

export class UnixSocketHostClient implements HostClient {
  private socketPath: string;
  private reqCounter = 1;
  private timeoutMs: number;

  constructor(socketPath?: string, timeoutMs = 10000) {
    const uid = process.getuid ? process.getuid() : 501;
    this.socketPath = socketPath ?? `/tmp/agy-computer-use-${uid}/agy-computer-use.sock`;
    this.timeoutMs = timeoutMs;
  }

  public request(method: string, params?: Record<string, unknown>, signal?: AbortSignal): Promise<IPCResponsePayload> {
    return new Promise((resolve) => {
      const id = `req-${this.reqCounter++}`;
      let settled = false;
      let isDispatched = false;
      let timer: NodeJS.Timeout | undefined;
      let onAbort: (() => void) | undefined;
      let client: net.Socket | undefined;

      const settle = (response: IPCResponsePayload) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        if (signal && onAbort) signal.removeEventListener("abort", onAbort);
        if (client) client.destroy();
        resolve(response);
      };

      onAbort = () => {
        if (isDispatched && MUTATION_METHODS.has(method)) {
          settle({
            id,
            success: false,
            error: {
              code: "ACTION_OUTCOME_UNKNOWN",
              message: `Client IPC socket for '${method}' was destroyed during cancellation. Native host state is unconfirmed; a fresh computer_use_observe snapshot is required.`
            }
          });
        } else {
          settle({
            id,
            success: false,
            error: { code: "CANCELLED", message: "IPC request cancelled before completion" }
          });
        }
      };

      if (signal?.aborted) {
        settle({
          id,
          success: false,
          error: { code: "CANCELLED", message: "IPC request cancelled before execution" }
        });
        return;
      }

      if (signal && onAbort) {
        signal.addEventListener("abort", onAbort, { once: true });
      }

      timer = setTimeout(() => {
        settle({
          id,
          success: false,
          error: { code: "TIMEOUT", message: `IPC request '${method}' timed out after ${this.timeoutMs}ms` }
        });
      }, this.timeoutMs);

      client = net.createConnection({ path: this.socketPath }, () => {
        const payloadObj: IPCRequestPayload = { id, method, params };
        const jsonStr = JSON.stringify(payloadObj);
        const payloadBuf = Buffer.from(jsonStr, "utf-8");

        if (payloadBuf.length > MAX_FRAME_SIZE) {
          settle({
            id,
            success: false,
            error: { code: "PAYLOAD_TOO_LARGE", message: `Request payload size ${payloadBuf.length} exceeds 16MB limit` }
          });
          return;
        }

        const msgBuf = Buffer.alloc(4 + payloadBuf.length);
        msgBuf.writeUInt32BE(payloadBuf.length, 0);
        payloadBuf.copy(msgBuf, 4);

        client?.write(msgBuf, () => {
          isDispatched = true;
        });
      });

      let incoming = Buffer.alloc(0);

      client.on("data", (chunk) => {
        incoming = Buffer.concat([incoming, chunk]);

        if (incoming.length > MAX_FRAME_SIZE + 4) {
          settle({
            id,
            success: false,
            error: { code: "RESPONSE_TOO_LARGE", message: `Incoming frame size exceeds maximum 16MB limit` }
          });
          return;
        }

        if (incoming.length >= 4) {
          const bodyLen = incoming.readUInt32BE(0);

          if (bodyLen > MAX_FRAME_SIZE) {
            settle({
              id,
              success: false,
              error: { code: "RESPONSE_TOO_LARGE", message: `Incoming frame header bodyLen ${bodyLen} exceeds 16MB limit` }
            });
            return;
          }

          if (incoming.length >= 4 + bodyLen) {
            const bodyBuf = incoming.subarray(4, 4 + bodyLen);

            try {
              const rawJson = JSON.parse(bodyBuf.toString("utf-8"));
              const parseResult = IPCResponseSchema.safeParse(rawJson);

              if (!parseResult.success) {
                settle({
                  id,
                  success: false,
                  error: { code: "MALFORMED_RESPONSE", message: `Invalid response schema from host: ${parseResult.error.message}` }
                });
                return;
              }

              const response = parseResult.data as IPCResponsePayload;

              if (response.id !== id) {
                settle({
                  id,
                  success: false,
                  error: { code: "INVALID_RESPONSE_ID", message: `Response ID mismatch. Expected ${id}, got ${response.id}` }
                });
                return;
              }

              settle(response);
            } catch (err) {
              settle({
                id,
                success: false,
                error: { code: "MALFORMED_RESPONSE", message: `Malformed JSON response from host: ${err}` }
              });
            }
          }
        }
      });

      client.on("end", () => {
        if (!settled) {
          settle({
            id,
            success: false,
            error: { code: "EOF", message: "Socket closed (EOF) before complete frame was received" }
          });
        }
      });

      client.on("close", () => {
        if (!settled) {
          settle({
            id,
            success: false,
            error: { code: "EOF", message: "Socket connection closed unexpectedly" }
          });
        }
      });

      client.on("error", (err) => {
        settle({
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
