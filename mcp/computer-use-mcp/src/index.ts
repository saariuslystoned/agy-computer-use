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
    return null; // Must start with SOI 0xFFD8
  }

  let offset = 2;
  let foundSOF = false;
  let foundSOS = false;
  let dimensions: JPEGDimensions | null = null;
  let eoiOffset = -1;

  while (offset < buf.length - 1) {
    // Check if byte is marker start 0xFF
    if (buf[offset] !== 0xff) {
      if (foundSOS) {
        // Inside entropy data scanning for 0xFF marker
        offset++;
        continue;
      } else {
        return null; // Non-0xFF byte outside entropy data is invalid
      }
    }

    // Skip consecutive 0xFF fill bytes
    while (offset < buf.length - 1 && buf[offset] === 0xff && buf[offset + 1] === 0xff) {
      offset++;
    }
    if (offset >= buf.length - 1) return null;

    const marker = buf[offset + 1];

    if (foundSOS) {
      if (marker === 0x00) {
        offset += 2;
        continue;
      }
      if (marker >= 0xd0 && marker <= 0xd7) {
        offset += 2;
        continue;
      }
      if (marker === 0xd9) {
        eoiOffset = offset;
        break;
      }
      // Inter-scan marker in progressive JPEG: transition out of entropy scan to parse next segment
      foundSOS = false;
    }

    // Header / Segment state (before SOS)
    if (marker === 0xd8) {
      // Second SOI invalid
      return null;
    }

    if (marker === 0xd9) {
      // EOI before SOS is invalid
      return null;
    }

    if (marker === 0xda) {
      // SOS: Start of Scan (SOF must precede SOS)
      if (!foundSOF) return null;
      if (offset + 4 >= buf.length) return null;
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      const numScanComponents = buf[offset + 4];
      if (numScanComponents < 1 || numScanComponents > 4) return null;
      if (segLen !== 6 + 2 * numScanComponents || offset + 2 + segLen > buf.length) return null;
      foundSOS = true;
      offset += 2 + segLen;
      continue;
    }

    // SOF0 (0xC0) or SOF2 (0xC2) only (baseline or progressive DCT)
    if (marker === 0xc0 || marker === 0xc2) {
      if (foundSOF) return null; // Duplicate SOF invalid
      if (offset + 9 >= buf.length) return null;
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      const precision = buf[offset + 4];
      if (precision !== 8) return null; // 8-bit precision required

      const height = (buf[offset + 5] << 8) | buf[offset + 6];
      const width = (buf[offset + 7] << 8) | buf[offset + 8];
      const numComponents = buf[offset + 9];

      if (segLen !== 8 + 3 * numComponents || offset + 2 + segLen > buf.length) return null;
      if (width <= 0 || height <= 0) return null;
      if (numComponents !== 1 && numComponents !== 3 && numComponents !== 4) return null;

      dimensions = { width, height };
      foundSOF = true;
      offset += 2 + segLen;
      continue;
    }

    // Whitelist legal header/inter-scan segment markers: 0xC4 (DHT), 0xDB (DQT), 0xDD (DRI), 0xE0..0xEF (APP0..APP15)
    const isWhitelisted = marker === 0xc4 || marker === 0xdb || marker === 0xdd || (marker >= 0xe0 && marker <= 0xef);
    if (!isWhitelisted) return null;

    if (marker === 0xdd) {
      if (offset + 3 >= buf.length) return null;
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      if (segLen !== 4 || offset + 2 + segLen > buf.length) return null;
      offset += 2 + segLen;
      continue;
    }

    // Skip generic segment payload
    if (offset + 3 < buf.length) {
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      if (segLen < 2 || offset + 2 + segLen > buf.length) return null;
      offset += 2 + segLen;
    } else {
      return null;
    }
  }

  if (!foundSOF || !foundSOS || !dimensions || eoiOffset === -1) {
    return null;
  }

  // Reject trailing non-zero garbage past EOI
  for (let i = eoiOffset + 2; i < buf.length; i++) {
    if (buf[i] !== 0) {
      return null;
    }
  }

  return dimensions;
}

export type BufferDecoder = (str: string, encoding: BufferEncoding) => Buffer;

export function validateAndDecodeBase64JPEG(
  base64Data: string,
  expectedPixelWidth?: number,
  expectedPixelHeight?: number,
  decoder: BufferDecoder = (str, enc) => Buffer.from(str, enc)
): Buffer {
  if (!base64Data || typeof base64Data !== "string") {
    throw new Error("Base64 image data is empty or invalid");
  }

  if (base64Data.length % 4 !== 0) {
    throw new Error("Base64 string length must be a multiple of 4");
  }

  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64Data)) {
    throw new Error("Base64 string contains invalid characters or misplaced padding");
  }

  let paddingCount = 0;
  if (base64Data.endsWith("==")) {
    paddingCount = 2;
    const lastChar = base64Data[base64Data.length - 3];
    if (!"AQgw".includes(lastChar)) {
      throw new Error("Base64 image string contains invalid unused padding bits");
    }
  } else if (base64Data.endsWith("=")) {
    paddingCount = 1;
    const lastChar = base64Data[base64Data.length - 2];
    if (!"AEIMQUYcgkosw048".includes(lastChar)) {
      throw new Error("Base64 image string contains invalid unused padding bits");
    }
  }

  // Exact byte length calculation before Buffer allocation
  const decodedLen = (base64Data.length / 4) * 3 - paddingCount;
  if (decodedLen > 10 * 1024 * 1024) {
    throw new Error(`Decoded byte size ${decodedLen} exceeds 10 MiB limit`);
  }

  // Single canonical decoder invocation
  const imageBuffer = decoder(base64Data, "base64");

  if (imageBuffer.length === 0) {
    throw new Error("Decoded image buffer is empty");
  }

  if (imageBuffer.length > 10 * 1024 * 1024) {
    throw new Error(`Decoded image buffer size ${imageBuffer.length} bytes exceeds 10 MiB limit`);
  }

  if (imageBuffer.length < 4 || imageBuffer[0] !== 0xff || imageBuffer[1] !== 0xd8 || imageBuffer[2] !== 0xff) {
    throw new Error("Invalid JPEG magic bytes: buffer must start with 0xFF 0xD8 0xFF");
  }

  const dims = parseJPEGDimensions(imageBuffer);
  if (!dims) {
    throw new Error("Failed to parse valid JPEG SOF marker or dimensions are absent");
  }

  if (expectedPixelWidth !== undefined && expectedPixelHeight !== undefined) {
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
    const { name, arguments: rawArgs } = request.params;
    const args = rawArgs || {}; // Normalize omitted arguments to empty object

    if (name === "computer_use_status") {
      const parseRes = StatusInputSchema.safeParse(args);
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
      const parseRes = ObserveInputSchema.safeParse(args);
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
