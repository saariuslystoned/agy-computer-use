import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { PeekabooImageClient, PeekabooImageClientImpl } from "./peekaboo-client.js";
import { Logger } from "./logger.js";

const KNOWN_ERROR_CODES = [
  "CANARY_PEEKABOO_ERROR",
  "CANARY_RESPONSE_INVALID",
  "CANARY_CONTENT_INVALID_COUNT",
  "CANARY_CONTENT_NOT_IMAGE",
  "CANARY_UNSUPPORTED_MIME",
  "CANARY_EMPTY_BASE64",
  "CANARY_MALFORMED_BASE64",
  "CANARY_EMPTY_DECODED_BUFFER",
  "CANARY_SIZE_EXCEEDED",
  "CANARY_MAGIC_MISMATCH",
  "CANARY_TIMEOUT"
];

export function createCanaryServer(imageClient?: PeekabooImageClient): Server {
  const client = imageClient ?? new PeekabooImageClientImpl();

  const server = new Server(
    {
      name: "computer-use-canary",
      version: "0.1.0"
    },
    {
      capabilities: {
        tools: {}
      }
    }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
      tools: [
        {
          name: "computer_use_canary_screenshot",
          description: "Read-only test harness screenshot canary capturing Calculator background window via Peekaboo bridge.",
          inputSchema: {
            type: "object",
            properties: {},
            additionalProperties: false
          }
        }
      ]
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    if (name !== "computer_use_canary_screenshot") {
      return {
        isError: true,
        content: [{ type: "text", text: "CANARY_UNKNOWN_TOOL" }]
      };
    }

    if (args && Object.keys(args).length > 0) {
      return {
        isError: true,
        content: [{ type: "text", text: "CANARY_ARGUMENTS_REJECTED" }]
      };
    }

    try {
      const res = await client.captureCalculator();
      Logger.info(`Successfully captured canary screenshot (${res.mimeType})`);

      return {
        content: [
          {
            type: "image",
            data: res.imageBase64,
            mimeType: res.mimeType
          }
        ]
      };
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : "CANARY_CAPTURE_FAILED";
      // Bounded stable error message only; never log raw base64 or child output
      Logger.error(`Canary capture failed: ${errMsg}`);

      const stableCode = KNOWN_ERROR_CODES.find((code) => errMsg.includes(code)) ?? "CANARY_CAPTURE_FAILED";

      return {
        isError: true,
        content: [{ type: "text", text: stableCode }]
      };
    }
  });

  return server;
}

// Stdio startup entrypoint when executed directly
if (import.meta.url === `file://${process.argv[1]}`) {
  Logger.info("Starting Computer Use Canary MCP Server over stdio...");
  const server = createCanaryServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  Logger.info("Computer Use Canary MCP Server connected to stdio.");
}
