import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { HostClient, UnixSocketHostClient, MockHostClient, IPCResponsePayload } from "./host-client.js";
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

  // Extract pixel base64 from observe or post_action_observation
  if (typeof data.image_data_base64 === "string") {
    imageBase64 = data.image_data_base64;
  } else if (data.post_action_observation && typeof (data.post_action_observation as any).image_data_base64 === "string") {
    imageBase64 = (data.post_action_observation as any).image_data_base64;
  }

  // Create clean metadata text without pixel base64 strings
  const cleanData = JSON.parse(JSON.stringify(data));
  if (cleanData.image_data_base64) delete cleanData.image_data_base64;
  if (cleanData.post_action_observation?.image_data_base64) delete cleanData.post_action_observation.image_data_base64;

  const content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }> = [
    { type: "text", text: JSON.stringify(cleanData, null, 2) }
  ];

  if (imageBase64) {
    content.push({
      type: "image",
      data: imageBase64,
      mimeType: "image/jpeg"
    });
  }

  return { content };
}

export function createComputerUseServer(hostClient?: HostClient): Server {
  const client = hostClient ?? (process.env.USE_MOCK_HOST === "1" ? new MockHostClient() : new UnixSocketHostClient());

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
          description: "Returns host connectivity, active display topology, and TCC permission state.",
          inputSchema: {
            type: "object",
            properties: {},
            additionalProperties: false
          }
        },
        {
          name: "computer_use_observe",
          description: "Captures current desktop display screenshot, metadata, and assigns a capture_id.",
          inputSchema: {
            type: "object",
            properties: {
              display_id: { type: "integer", description: "Target display ID" }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_ax_tree",
          description: "Returns bounded macOS Accessibility element graph with redacted sensitive input fields.",
          inputSchema: {
            type: "object",
            properties: {
              max_depth: { type: "integer", default: 10, description: "Max traversal depth" },
              app_id: { type: "string", description: "Target app bundle or title" }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_click",
          description: "Performs mouse click at 0...999 grid coordinates.",
          inputSchema: {
            type: "object",
            required: ["x", "y", "capture_id", "topology_version", "intent"],
            properties: {
              x: { type: "integer", minimum: 0, maximum: 999 },
              y: { type: "integer", minimum: 0, maximum: 999 },
              button: { type: "string", enum: ["left", "right", "middle"], default: "left" },
              click_count: { type: "integer", minimum: 1, maximum: 3, default: 1 },
              capture_id: { type: "string" },
              topology_version: { type: "string" },
              intent: { type: "string", minLength: 1 }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_move",
          description: "Moves cursor to 0...999 grid coordinates.",
          inputSchema: {
            type: "object",
            required: ["x", "y", "capture_id", "topology_version", "intent"],
            properties: {
              x: { type: "integer", minimum: 0, maximum: 999 },
              y: { type: "integer", minimum: 0, maximum: 999 },
              capture_id: { type: "string" },
              topology_version: { type: "string" },
              intent: { type: "string", minLength: 1 }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_drag",
          description: "Performs drag and drop from start to end 0...999 grid coordinates.",
          inputSchema: {
            type: "object",
            required: ["start_x", "start_y", "end_x", "end_y", "capture_id", "topology_version", "intent"],
            properties: {
              start_x: { type: "integer", minimum: 0, maximum: 999 },
              start_y: { type: "integer", minimum: 0, maximum: 999 },
              end_x: { type: "integer", minimum: 0, maximum: 999 },
              end_y: { type: "integer", minimum: 0, maximum: 999 },
              capture_id: { type: "string" },
              topology_version: { type: "string" },
              intent: { type: "string", minLength: 1 }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_type",
          description: "Types text string into active focused element.",
          inputSchema: {
            type: "object",
            required: ["text", "capture_id", "topology_version", "intent"],
            properties: {
              text: { type: "string", minLength: 1 },
              press_enter: { type: "boolean", default: false },
              capture_id: { type: "string" },
              topology_version: { type: "string" },
              intent: { type: "string", minLength: 1 }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_shortcut",
          description: "Triggers keyboard shortcut key combination.",
          inputSchema: {
            type: "object",
            required: ["keys", "capture_id", "topology_version", "intent"],
            properties: {
              keys: { type: "array", items: { type: "string" }, minItems: 1 },
              capture_id: { type: "string" },
              topology_version: { type: "string" },
              intent: { type: "string", minLength: 1 }
            },
            additionalProperties: false
          }
        },
        {
          name: "computer_use_scroll",
          description: "Scrolls scrollable container at target 0...999 location.",
          inputSchema: {
            type: "object",
            required: ["x", "y", "delta_x", "delta_y", "capture_id", "topology_version", "intent"],
            properties: {
              x: { type: "integer", minimum: 0, maximum: 999 },
              y: { type: "integer", minimum: 0, maximum: 999 },
              delta_x: { type: "integer" },
              delta_y: { type: "integer" },
              direction: { type: "string", enum: ["up", "down", "left", "right"] },
              capture_id: { type: "string" },
              topology_version: { type: "string" },
              intent: { type: "string", minLength: 1 }
            },
            additionalProperties: false
          }
        }
      ]
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const { name, arguments: args } = request.params;
    const signal = extra?.signal;
    Logger.info(`Tool called: ${name}`);

    if (signal?.aborted) {
      Logger.warn(`Request for tool ${name} aborted before execution.`);
      return {
        isError: true,
        content: [{ type: "text", text: "Tool request cancelled by client signal." }]
      };
    }

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

// Server startup if executed directly
if (import.meta.url === `file://${process.argv[1]}`) {
  Logger.info("Starting Computer Use MCP Server over stdio...");
  const server = createComputerUseServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  Logger.info("Computer Use MCP Server connected to stdio.");
}
