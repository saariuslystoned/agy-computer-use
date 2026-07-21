import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { HostClient, UnixSocketHostClient, IPCResponsePayload } from "./host-client.js";
import { Logger } from "./logger.js";
import {
  ObserveSchema,
  AXTreeSchema,
  ClickSchema,
  MoveSchema,
  DragSchema,
  TypeSchema,
  ShortcutSchema,
  ScrollSchema
} from "./schemas.js";

const MAX_DECODED_BYTES = 10 * 1024 * 1024; // 10 MiB limit

function validateAndDecodeBase64Image(base64Str: string): Buffer {
  if (!base64Str || typeof base64Str !== "string") {
    throw new Error("CANARY_RESPONSE_INVALID: Missing base64 image payload");
  }

  // Pre-allocation guard & canonical padding/character check
  if (base64Str.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(base64Str)) {
    throw new Error("CANARY_RESPONSE_INVALID: Invalid canonical base64 format");
  }

  const buf = Buffer.from(base64Str, "base64");
  if (buf.length === 0) {
    throw new Error("CANARY_EMPTY_DECODED_BUFFER: Decoded image buffer is empty");
  }
  if (buf.length > MAX_DECODED_BYTES) {
    throw new Error("CANARY_SIZE_EXCEEDED: Decoded image exceeds 10 MiB limit");
  }

  // Validate JPEG magic bytes 0xFF, 0xD8, 0xFF
  if (buf.length < 3 || buf[0] !== 0xff || buf[1] !== 0xd8 || buf[2] !== 0xff) {
    throw new Error("CANARY_MAGIC_MISMATCH: Image payload magic bytes do not match image/jpeg header");
  }

  return buf;
}

function formatToolResponse(resp: IPCResponsePayload) {
  if (!resp.success) {
    return {
      isError: true,
      content: [
        {
          type: "text" as const,
          text: JSON.stringify({ error: resp.error ?? { code: "HOST_ERROR", message: "Host request failed" } }, null, 2)
        }
      ]
    };
  }

  const data = resp.data ?? {};
  let imageBase64: string | undefined;

  if (typeof data.image_data_base64 === "string") {
    imageBase64 = data.image_data_base64;
  } else if (data.post_action_observation && typeof (data.post_action_observation as any).image_data_base64 === "string") {
    imageBase64 = (data.post_action_observation as any).image_data_base64;
  }

  const cleanData = JSON.parse(JSON.stringify(data));
  delete cleanData.image_data_base64;
  if (cleanData.post_action_observation) {
    delete cleanData.post_action_observation.image_data_base64;
  }

  const content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }> = [
    {
      type: "text" as const,
      text: JSON.stringify(cleanData, null, 2)
    }
  ];

  if (imageBase64) {
    try {
      validateAndDecodeBase64Image(imageBase64);
      content.push({
        type: "image" as const,
        data: imageBase64,
        mimeType: "image/jpeg"
      });
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      return {
        isError: true,
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({ error: { code: "INVALID_IMAGE_PAYLOAD", message: errMsg } }, null, 2)
          }
        ]
      };
    }
  }

  return { content };
}

export function createComputerUseServer(hostClient?: HostClient): Server {
  const client = hostClient ?? new UnixSocketHostClient();

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

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
      tools: [
        {
          name: "computer_use_status",
          description: "Gets active display topology, host connection status, TCC permission state, and mutation state.",
          inputSchema: {
            type: "object",
            properties: {},
            additionalProperties: false
          }
        },
        {
          name: "computer_use_observe",
          description: "Captures primary or target display snapshot and yields fresh capture_id and topology_version.",
          inputSchema: {
            type: "object",
            properties: {
              display_id: { type: "integer" }
            },
            additionalProperties: false
          }
        }
      ]
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const { name, arguments: args } = request.params;
    const signal = extra.signal;

    try {
      switch (name) {
        case "computer_use_status": {
          const resp = await client.request("status", {}, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_observe": {
          const parsed = ObserveSchema.parse(args ?? {});
          const resp = await client.request("observe", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_ax_tree": {
          const parsed = AXTreeSchema.parse(args ?? {});
          const resp = await client.request("ax_tree", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_click": {
          const parsed = ClickSchema.parse(args);
          const resp = await client.request("click", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_move": {
          const parsed = MoveSchema.parse(args);
          const resp = await client.request("move", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_drag": {
          const parsed = DragSchema.parse(args);
          const resp = await client.request("drag", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_type": {
          const parsed = TypeSchema.parse(args);
          const resp = await client.request("type", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_shortcut": {
          const parsed = ShortcutSchema.parse(args);
          const resp = await client.request("shortcut", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        case "computer_use_scroll": {
          const parsed = ScrollSchema.parse(args);
          const resp = await client.request("scroll", parsed as Record<string, unknown>, signal);
          return formatToolResponse(resp);
        }

        default:
          return {
            isError: true,
            content: [{ type: "text", text: `Unknown tool name: ${name}` }]
          };
      }
    } catch (err: unknown) {
      const errMsg = err instanceof Error ? err.message : String(err);
      Logger.error(`Tool execution error for ${name}: ${errMsg}`);
      return {
        isError: true,
        content: [{ type: "text", text: `Tool error: ${errMsg}` }]
      };
    }
  });

  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  Logger.info("Starting Computer Use MCP Server over stdio...");
  const server = createComputerUseServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  Logger.info("Computer Use MCP Server connected to stdio.");
}
