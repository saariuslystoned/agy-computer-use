import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool
} from "@modelcontextprotocol/sdk/types.js";
import { HostClient, UnixSocketHostClient, getDefaultSocketPath } from "./host-client.js";
import { StatusDataSchema, ObserveDataSchema, StatusInputSchema, ObserveInputSchema } from "./schemas.js";

export interface JPEGDimensions {
  width: number;
  height: number;
}

export function parseJPEGDimensions(buf: Buffer): JPEGDimensions | null {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) {
    return null;
  }

  let offset = 2;
  let foundSOF = false;
  let foundSOS = false;
  let dimensions: JPEGDimensions | null = null;

  while (offset < buf.length - 1) {
    if (buf[offset] !== 0xff) {
      offset++;
      continue;
    }

    const marker = buf[offset + 1];

    // SOF0 (0xC0), SOF1 (0xC1), SOF2 (0xC2)
    if (marker === 0xc0 || marker === 0xc1 || marker === 0xc2) {
      if (offset + 8 >= buf.length) return null;
      const height = (buf[offset + 5] << 8) | buf[offset + 6];
      const width = (buf[offset + 7] << 8) | buf[offset + 8];
      if (width <= 0 || height <= 0) return null;
      dimensions = { width, height };
      foundSOF = true;
      offset += 2 + ((buf[offset + 2] << 8) | buf[offset + 3]);
      continue;
    }

    // SOS (0xDA)
    if (marker === 0xda) {
      foundSOS = true;
      break;
    }

    // EOI (0xD9)
    if (marker === 0xd9) {
      break;
    }

    // Skip segment payload
    if (offset + 3 < buf.length) {
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      if (segLen < 2) return null;
      offset += 2 + segLen;
    } else {
      break;
    }
  }

  if (!foundSOF || !foundSOS || !dimensions) {
    return null;
  }

  return dimensions;
}

export function validateAndDecodeBase64JPEG(base64Data: string, expectedPixelWidth?: number, expectedPixelHeight?: number): Buffer {
  if (!base64Data || typeof base64Data !== "string") {
    throw new Error("Base64 image data is empty or invalid");
  }

  if (base64Data.length % 4 !== 0) {
    throw new Error("Base64 string length must be a multiple of 4");
  }

  const maxEncodedChars = Math.ceil((10 * 1024 * 1024) / 3) * 4;
  if (base64Data.length > maxEncodedChars) {
    throw new Error(`Base64 payload length ${base64Data.length} exceeds maximum encoded limit ${maxEncodedChars}`);
  }

  let paddingCount = 0;
  if (base64Data.endsWith("==")) paddingCount = 2;
  else if (base64Data.endsWith("=")) paddingCount = 1;
  const decodedLen = Math.floor((base64Data.length * 3) / 4) - paddingCount;
  if (decodedLen > 10 * 1024 * 1024) {
    throw new Error(`Decoded byte size ${decodedLen} exceeds 10 MiB limit`);
  }

  const imageBuffer = Buffer.from(base64Data, "base64");

  if (imageBuffer.toString("base64") !== base64Data) {
    throw new Error("Base64 string is not canonically encoded");
  }

  if (imageBuffer.length === 0) {
    throw new Error("Decoded image buffer is empty");
  }

  if (imageBuffer.length > 10 * 1024 * 1024) {
    throw new Error(`Decoded image buffer size ${imageBuffer.length} bytes exceeds 10 MiB limit`);
  }

  if (imageBuffer.length < 4 || imageBuffer[0] !== 0xff || imageBuffer[1] !== 0xd8 || imageBuffer[2] !== 0xff) {
    throw new Error("Invalid JPEG magic bytes: buffer must start with 0xFF 0xD8 0xFF");
  }

  // EOI marker check (0xFF 0xD9)
  const eoiIdx = imageBuffer.lastIndexOf(Buffer.from([0xff, 0xd9]));
  if (eoiIdx === -1 || eoiIdx < imageBuffer.length - 2) {
    // Check if trailing bytes past EOI are non-zero
    if (eoiIdx !== -1) {
      for (let i = eoiIdx + 2; i < imageBuffer.length; i++) {
        if (imageBuffer[i] !== 0) {
          throw new Error("Trailing non-zero garbage bytes after JPEG EOI marker");
        }
      }
    } else {
      throw new Error("Missing JPEG EOI marker (0xFF 0xD9)");
    }
  }

  if (expectedPixelWidth !== undefined && expectedPixelHeight !== undefined) {
    const dims = parseJPEGDimensions(imageBuffer);
    if (!dims) {
      throw new Error("Failed to parse valid JPEG SOF marker or dimensions are absent");
    }
    if (dims.width !== expectedPixelWidth || dims.height !== expectedPixelHeight) {
      throw new Error(`JPEG dimensions (${dims.width}x${dims.height}) do not match declared pixel dimensions (${expectedPixelWidth}x${expectedPixelHeight})`);
    }
  }

  return imageBuffer;
}

function formatToolResponse(ipcResp: any, toolName: string) {
  if (!ipcResp.success) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text: JSON.stringify({
            error: ipcResp.error || { code: "HOST_ERROR", message: "Unknown host error" }
          }, null, 2)
        }
      ]
    };
  }

  if (toolName === "computer_use_status") {
    const parsedData = StatusDataSchema.safeParse(ipcResp.data);
    if (!parsedData.success) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: {
                code: "INVALID_RESPONSE_DATA",
                message: `Status response data failed Zod schema validation: ${parsedData.error.message}`
              }
            }, null, 2)
          }
        ]
      };
    }
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(parsedData.data, null, 2)
        }
      ]
    };
  }

  if (toolName === "computer_use_observe") {
    const parsedData = ObserveDataSchema.safeParse(ipcResp.data);
    if (!parsedData.success) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: {
                code: "INVALID_RESPONSE_DATA",
                message: `Observe response data failed Zod schema validation: ${parsedData.error.message}`
              }
            }, null, 2)
          }
        ]
      };
    }

    try {
      validateAndDecodeBase64JPEG(parsedData.data.image_data_base64, parsedData.data.pixel_width, parsedData.data.pixel_height);
    } catch (valErr: any) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: {
                code: "INVALID_IMAGE_PAYLOAD",
                message: `JPEG image payload validation failed: ${valErr.message}`
              }
            }, null, 2)
          }
        ]
      };
    }

    const { image_data_base64, ...metaData } = parsedData.data;

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(metaData, null, 2)
        },
        {
          type: "image",
          data: image_data_base64,
          mimeType: "image/jpeg"
        }
      ]
    };
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(ipcResp.data, null, 2)
      }
    ]
  };
}

export function createComputerUseServer(hostClient: HostClient): Server {
  const server = new Server(
    {
      name: "computer-use-mcp",
      version: "0.1.0"
    },
    {
      capabilities: {
        tools: {}
      }
    }
  );

  const STATUS_TOOL: Tool = {
    name: "computer_use_status",
    description: "Returns host connectivity, active display topology, TCC permission state, and mutation lockout state.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  };

  const OBSERVE_TOOL: Tool = {
    name: "computer_use_observe",
    description: "Captures primary or target display screenshot, returning capture_id, topology_version (top-sha256-...), and JPEG image payload.",
    inputSchema: {
      type: "object",
      properties: {
        display_id: {
          type: "integer",
          minimum: 1,
          description: "Optional display ID to capture. Defaults to primary display."
        }
      },
      additionalProperties: false
    }
  };

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
      tools: [STATUS_TOOL, OBSERVE_TOOL]
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const { name, arguments: args } = request.params;

    if (name === "computer_use_status") {
      const parseRes = StatusInputSchema.safeParse(args || {});
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_status: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("status", undefined, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_observe") {
      const parseRes = ObserveInputSchema.safeParse(args || {});
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_observe: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const displayId = parseRes.data.display_id;
      const params = displayId !== undefined ? { display_id: displayId } : undefined;
      const ipcResp = await hostClient.request("observe", params, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    return {
      isError: true,
      content: [
        {
          type: "text",
          text: JSON.stringify({
            error: {
              code: "UNKNOWN_TOOL",
              message: `Tool '${name}' is not recognized`
            }
          }, null, 2)
        }
      ]
    };
  });

  return server;
}

export async function main() {
  const socketPath = process.env.COMPUTER_USE_SOCKET_PATH || (getDefaultSocketPath() as string);
  const hostClient = new UnixSocketHostClient(socketPath);
  const server = createComputerUseServer(hostClient);
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error("[computer-use-mcp] Fatal server error:", err);
    process.exit(1);
  });
}
