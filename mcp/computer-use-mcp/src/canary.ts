import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { PeekabooImageClient, StdioPeekabooImageClient } from "./peekaboo-client.js";
import { Logger } from "./logger.js";

const MAX_BASE64_LENGTH = 22 * 1024 * 1024; // Approx 16MB raw binary

export function createCanaryServer(imageClient?: PeekabooImageClient): Server {
  const client = imageClient ?? new StdioPeekabooImageClient();

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
        content: [{ type: "text", text: `Unknown tool name '${name}'. Canary server exposes only 'computer_use_canary_screenshot'.` }]
      };
    }

    if (args && Object.keys(args).length > 0) {
      return {
        isError: true,
        content: [{ type: "text", text: "Tool 'computer_use_canary_screenshot' accepts no arguments." }]
      };
    }

    try {
      const res = await client.captureCalculator();

      if (!res || !res.imageBase64 || typeof res.imageBase64 !== "string") {
        return {
          isError: true,
          content: [{ type: "text", text: "Canary capture failed: Missing or invalid base64 image data." }]
        };
      }

      if (res.mimeType !== "image/png" && res.mimeType !== "image/jpeg") {
        return {
          isError: true,
          content: [{ type: "text", text: `Canary capture failed: Unsupported mimeType '${res.mimeType}'. Expected image/png or image/jpeg.` }]
        };
      }

      if (res.imageBase64.length > MAX_BASE64_LENGTH) {
        return {
          isError: true,
          content: [{ type: "text", text: `Canary capture failed: Base64 payload size exceeds 16MB limit.` }]
        };
      }

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
      const errMsg = err instanceof Error ? err.message : String(err);
      Logger.error(`Canary capture error: ${errMsg}`);
      return {
        isError: true,
        content: [{ type: "text", text: `Canary capture error: ${errMsg}` }]
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
