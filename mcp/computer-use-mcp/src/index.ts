import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { HostClient, UnixSocketHostClient, MockHostClient } from "./host-client.js";
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
            properties: {}
          }
        },
        {
          name: "computer_use_observe",
          description: "Captures current desktop display screenshot, metadata, and assigns a capture_id.",
          inputSchema: {
            type: "object",
            properties: {
              display_id: { type: "integer", description: "Target display ID" }
            }
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
            }
          }
        },
        {
          name: "computer_use_click",
          description: "Performs mouse click at 0...999 grid coordinates.",
          inputSchema: {
            type: "object",
            required: ["x", "y", "capture_id"],
            properties: {
              x: { type: "integer", minimum: 0, maximum: 999 },
              y: { type: "integer", minimum: 0, maximum: 999 },
              button: { type: "string", enum: ["left", "right", "middle"], default: "left" },
              click_count: { type: "integer", minimum: 1, maximum: 3, default: 1 },
              capture_id: { type: "string" }
            }
          }
        },
        {
          name: "computer_use_move",
          description: "Moves cursor to 0...999 grid coordinates.",
          inputSchema: {
            type: "object",
            required: ["x", "y", "capture_id"],
            properties: {
              x: { type: "integer", minimum: 0, maximum: 999 },
              y: { type: "integer", minimum: 0, maximum: 999 },
              capture_id: { type: "string" }
            }
          }
        },
        {
          name: "computer_use_drag",
          description: "Performs drag and drop from start to end 0...999 grid coordinates.",
          inputSchema: {
            type: "object",
            required: ["start_x", "start_y", "end_x", "end_y", "capture_id"],
            properties: {
              start_x: { type: "integer", minimum: 0, maximum: 999 },
              start_y: { type: "integer", minimum: 0, maximum: 999 },
              end_x: { type: "integer", minimum: 0, maximum: 999 },
              end_y: { type: "integer", minimum: 0, maximum: 999 },
              capture_id: { type: "string" }
            }
          }
        },
        {
          name: "computer_use_type",
          description: "Types text string into active focused element.",
          inputSchema: {
            type: "object",
            required: ["text", "capture_id"],
            properties: {
              text: { type: "string" },
              capture_id: { type: "string" }
            }
          }
        },
        {
          name: "computer_use_shortcut",
          description: "Triggers keyboard shortcut key combination.",
          inputSchema: {
            type: "object",
            required: ["keys", "capture_id"],
            properties: {
              keys: { type: "array", items: { type: "string" } },
              capture_id: { type: "string" }
            }
          }
        },
        {
          name: "computer_use_scroll",
          description: "Scrolls scrollable container at target 0...999 location.",
          inputSchema: {
            type: "object",
            required: ["x", "y", "delta_x", "delta_y", "capture_id"],
            properties: {
              x: { type: "integer", minimum: 0, maximum: 999 },
              y: { type: "integer", minimum: 0, maximum: 999 },
              delta_x: { type: "integer" },
              delta_y: { type: "integer" },
              capture_id: { type: "string" }
            }
          }
        }
      ]
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    Logger.info(`Tool called: ${name}`);

    try {
      switch (name) {
        case "computer_use_status": {
          const resp = await client.request("status");
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_observe": {
          const parsed = ObserveSchema.parse(args ?? {});
          const resp = await client.request("observe", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_ax_tree": {
          const parsed = AXTreeSchema.parse(args ?? {});
          const resp = await client.request("ax_tree", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_click": {
          const parsed = ClickSchema.parse(args);
          const resp = await client.request("click", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_move": {
          const parsed = MoveSchema.parse(args);
          const resp = await client.request("move", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_drag": {
          const parsed = DragSchema.parse(args);
          const resp = await client.request("drag", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_type": {
          const parsed = TypeSchema.parse(args);
          const resp = await client.request("type", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_shortcut": {
          const parsed = ShortcutSchema.parse(args);
          const resp = await client.request("shortcut", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
        }

        case "computer_use_scroll": {
          const parsed = ScrollSchema.parse(args);
          const resp = await client.request("scroll", parsed as Record<string, unknown>);
          return { content: [{ type: "text", text: JSON.stringify(resp, null, 2) }] };
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
