import * as crypto from "crypto";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool
} from "@modelcontextprotocol/sdk/types.js";
import { HostClient, UnixSocketHostClient, getDefaultSocketPath } from "./host-client.js";
import {
  StatusDataSchema,
  ObserveDataSchema,
  StatusInputSchema,
  ObserveInputSchema,
  AXTreeInputSchema,
  AXTreeDataSchema,
  AXActionInputSchema,
  AXActionResultDataSchema,
  ClickInputSchema,
  MoveInputSchema,
  ScrollInputSchema,
  DragInputSchema,
  TypeInputSchema,
  ShortcutInputSchema,
  ActionResultDataSchema
} from "./schemas.js";

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
  let frameNumComponents = 0;
  const sofComponentIds = new Set<number>();
  let eoiOffset = -1;

  while (offset < buf.length - 1) {
    if (buf[offset] !== 0xff) {
      if (foundSOS) {
        offset++;
        continue;
      } else {
        return null;
      }
    }

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
      foundSOS = false;
    }

    if (marker === 0xd8) {
      return null;
    }

    if (marker === 0xd9) {
      return null;
    }

    if (marker === 0xda) {
      if (!foundSOF) return null;
      if (offset + 4 >= buf.length) return null;
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      const numScanComponents = buf[offset + 4];
      if (numScanComponents < 1 || numScanComponents > frameNumComponents) return null;
      if (segLen !== 6 + 2 * numScanComponents || offset + 2 + segLen > buf.length) return null;
      const sosSelectors = new Set<number>();
      for (let j = 0; j < numScanComponents; j++) {
        const selector = buf[offset + 5 + 2 * j];
        if (!sofComponentIds.has(selector) || sosSelectors.has(selector)) return null;
        sosSelectors.add(selector);
      }
      foundSOS = true;
      offset += 2 + segLen;
      continue;
    }

    if (marker === 0xc0 || marker === 0xc2) {
      if (foundSOF) return null;
      if (offset + 9 >= buf.length) return null;
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      const precision = buf[offset + 4];
      if (precision !== 8) return null;

      const height = (buf[offset + 5] << 8) | buf[offset + 6];
      const width = (buf[offset + 7] << 8) | buf[offset + 8];
      const numComponents = buf[offset + 9];

      if (segLen !== 8 + 3 * numComponents || offset + 2 + segLen > buf.length) return null;
      if (width <= 0 || height <= 0 || width * height > 64_000_000) return null;
      if (numComponents !== 1 && numComponents !== 3 && numComponents !== 4) return null;

      for (let i = 0; i < numComponents; i++) {
        const compId = buf[offset + 10 + 3 * i];
        if (sofComponentIds.has(compId)) return null;
        sofComponentIds.add(compId);
      }
      frameNumComponents = numComponents;

      dimensions = { width, height };
      foundSOF = true;
      offset += 2 + segLen;
      continue;
    }

    const isWhitelisted = marker === 0xc4 || marker === 0xdb || marker === 0xdd || marker === 0xfe || (marker >= 0xe0 && marker <= 0xef);
    if (!isWhitelisted) return null;

    if (marker === 0xdd) {
      if (offset + 3 >= buf.length) return null;
      const segLen = (buf[offset + 2] << 8) | buf[offset + 3];
      if (segLen !== 4 || offset + 2 + segLen > buf.length) return null;
      offset += 2 + segLen;
      continue;
    }

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

  if (eoiOffset + 2 !== buf.length) {
    return null;
  }

  return dimensions;
}

export type BufferDecoder = (str: string, encoding: BufferEncoding) => Buffer;

export function validateAndDecodeBase64JPEG(
  base64Data: string,
  expectedPixelWidth?: number,
  expectedPixelHeight?: number,
  expectedByteLength?: number,
  expectedSha256?: string,
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

  const decodedLen = (base64Data.length / 4) * 3 - paddingCount;
  if (decodedLen > 10 * 1024 * 1024) {
    throw new Error(`Decoded byte size ${decodedLen} exceeds 10 MiB limit`);
  }

  const imageBuffer = decoder(base64Data, "base64");

  if (imageBuffer.length === 0) {
    throw new Error("Decoded image buffer is empty");
  }

  if (imageBuffer.length > 10 * 1024 * 1024) {
    throw new Error(`Decoded image buffer size ${imageBuffer.length} bytes exceeds 10 MiB limit`);
  }

  if (expectedByteLength !== undefined && imageBuffer.length !== expectedByteLength) {
    throw new Error(`Decoded byte length (${imageBuffer.length}) does not match native byte length (${expectedByteLength})`);
  }

  const computedSha256 = crypto.createHash("sha256").update(imageBuffer).digest("hex");
  if (expectedSha256 !== undefined && computedSha256.toLowerCase() !== expectedSha256.toLowerCase()) {
    throw new Error(`Recomputed SHA-256 digest (${computedSha256}) does not match native image_sha256 (${expectedSha256})`);
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
    const rawData = { ...(ipcResp.data || {}) };
    if (rawData.input_mutation_state === "enabled") {
      rawData.accessibility_trusted = true;
    }
    if (rawData.ax_tree_inspection_available === undefined && typeof rawData.accessibility_available === "boolean") {
      rawData.ax_tree_inspection_available = rawData.accessibility_available;
    }
    if (rawData.operator_safe_ax_available === undefined) {
      rawData.operator_safe_ax_available = false;
    }
    if (rawData.operator_safe_ax_actions === undefined) {
      rawData.operator_safe_ax_actions = [];
    }
    if (rawData.supported_action_strategies === undefined) {
      rawData.supported_action_strategies =
        rawData.input_mutation_state === "enabled" ? ["exclusive_global_hid"] : [];
    }
    if (rawData.global_hid_may_affect_pointer_or_focus === undefined) {
      rawData.global_hid_may_affect_pointer_or_focus = true;
    }
    const parsedData = StatusDataSchema.safeParse(rawData);
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
      validateAndDecodeBase64JPEG(
        parsedData.data.image_data_base64,
        parsedData.data.pixel_width,
        parsedData.data.pixel_height,
        parsedData.data.image_byte_length,
        parsedData.data.image_sha256
      );
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

  if (toolName === "computer_use_ax_tree") {
    const parsedData = AXTreeDataSchema.safeParse(ipcResp.data);
    if (!parsedData.success) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: {
                code: "INVALID_RESPONSE_DATA",
                message: `AX tree response data failed Zod schema validation: ${parsedData.error.message}`
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

  if (toolName === "computer_use_ax_action") {
    const parsedData = AXActionResultDataSchema.safeParse(ipcResp.data);
    if (!parsedData.success) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: {
                code: "INVALID_RESPONSE_DATA",
                message: `AX action response data failed Zod schema validation: ${parsedData.error.message}`
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

  if (
    toolName === "computer_use_click" ||
    toolName === "computer_use_move" ||
    toolName === "computer_use_type" ||
    toolName === "computer_use_shortcut" ||
    toolName === "computer_use_scroll" ||
    toolName === "computer_use_drag"
  ) {
    const parsedData = ActionResultDataSchema.safeParse(ipcResp.data);
    if (!parsedData.success) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: {
                code: "INVALID_RESPONSE_DATA",
                message: `Action response data failed Zod schema validation: ${parsedData.error.message}`
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

  const AX_TREE_TOOL: Tool = {
    name: "computer_use_ax_tree",
    description: "Inspects the accessibility hierarchy of one explicit running application. Returns a short-lived opaque AX action lease and opaque element references only for exact retained controls that advertise the operator-safe press action.",
    inputSchema: {
      type: "object",
      properties: {
        app_id: {
          type: "string",
          minLength: 1,
          description: "Required running application bundle identifier, localized process name, or PID. Implicit frontmost-app targeting is not accepted by the operator-safe MCP surface."
        },
        max_depth: {
          type: "integer",
          minimum: 1,
          maximum: 10,
          description: "Optional maximum inspection tree depth limit (1-10). Defaults to 10."
        }
      },
      required: ["app_id"],
      additionalProperties: false
    }
  };

  const AX_ACTION_TOOL: Tool = {
    name: "computer_use_ax_action",
    description: "Dispatches one operator-safe semantic AXPress against an exact retained element. The opaque snapshot/app/element lease is consumed once. This path never falls back to global HID and always requires fresh AX inspection to verify the effect.",
    inputSchema: {
      type: "object",
      properties: {
        ax_snapshot_id: { type: "string", minLength: 1, description: "Short-lived opaque snapshot lease from computer_use_ax_tree." },
        app_instance_ref: { type: "string", minLength: 1, description: "Opaque exact process-instance reference from the same AX inspection." },
        element_ref: { type: "string", minLength: 1, description: "Opaque actionable element reference from the same AX inspection." },
        topology_version: { type: "string", description: "Exact topology version returned with the AX inspection." },
        action: { type: "string", enum: ["press"], description: "Phase 1 supports only the advertised semantic press action." },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["ax_snapshot_id", "app_instance_ref", "element_ref", "topology_version", "action", "intent"],
      additionalProperties: false
    }
  };

  const CLICK_TOOL: Tool = {
    name: "computer_use_click",
    description: "Dispatches a single mouse click at normalized (x, y) coordinates [0...999] on the observed display geometry. Requires active capture_id and topology_version.",
    inputSchema: {
      type: "object",
      properties: {
        capture_id: { type: "string", description: "Observation capture ID token from latest computer_use_observe." },
        topology_version: { type: "string", description: "Active display topology version token." },
        x: { type: "integer", minimum: 0, maximum: 999, description: "Normalized horizontal coordinate (0-999)." },
        y: { type: "integer", minimum: 0, maximum: 999, description: "Normalized vertical coordinate (0-999)." },
        button: { type: "string", enum: ["left", "right", "middle"], description: "Optional mouse button. Defaults to left." },
        click_count: { type: "integer", minimum: 1, maximum: 3, description: "Optional click count (1-3). Defaults to 1." },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["capture_id", "topology_version", "x", "y", "intent"],
      additionalProperties: false
    }
  };

  const MOVE_TOOL: Tool = {
    name: "computer_use_move",
    description: "Dispatches a single mouse movement to normalized (x, y) coordinates [0...999] on the observed display geometry without clicking. Consumes active observation lease.",
    inputSchema: {
      type: "object",
      properties: {
        capture_id: { type: "string", description: "Observation capture ID token from latest computer_use_observe." },
        topology_version: { type: "string", description: "Active display topology version token." },
        x: { type: "integer", minimum: 0, maximum: 999, description: "Normalized horizontal coordinate (0-999)." },
        y: { type: "integer", minimum: 0, maximum: 999, description: "Normalized vertical coordinate (0-999)." },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["capture_id", "topology_version", "x", "y", "intent"],
      additionalProperties: false
    }
  };

  const TYPE_TOOL: Tool = {
    name: "computer_use_type",
    description: "Synthesizes Unicode text entry into the focused window/element, with optional Enter key press. Requires active capture_id and topology_version.",
    inputSchema: {
      type: "object",
      properties: {
        capture_id: { type: "string", description: "Observation capture ID token from latest computer_use_observe." },
        topology_version: { type: "string", description: "Active display topology version token." },
        text: { type: "string", minLength: 1, maxLength: 1000, description: "Unicode text payload to type (1-1000 characters)." },
        press_enter: { type: "boolean", description: "Optional boolean to press Enter after text. Defaults to false." },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["capture_id", "topology_version", "text", "intent"],
      additionalProperties: false
    }
  };

  const SHORTCUT_TOOL: Tool = {
    name: "computer_use_shortcut",
    description: "Dispatches a bounded keyboard shortcut sequence (modifiers + navigation keys like Tab, Enter, Escape, Arrow keys, Home, End, PageUp/Down). Requires active capture_id and topology_version.",
    inputSchema: {
      type: "object",
      properties: {
        capture_id: { type: "string", description: "Observation capture ID token from latest computer_use_observe." },
        topology_version: { type: "string", description: "Active display topology version token." },
        keys: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          maxItems: 5,
          description: "Array of 1 to 5 keys/modifiers to press in sequence (e.g. ['cmd', 'tab'])."
        },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["capture_id", "topology_version", "keys", "intent"],
      additionalProperties: false
    }
  };

  const SCROLL_TOOL: Tool = {
    name: "computer_use_scroll",
    description: "Dispatches a finite anchored scroll at normalized (x, y) coordinates with bounded nonzero scroll deltas. Consumes active observation lease.",
    inputSchema: {
      type: "object",
      properties: {
        capture_id: { type: "string", description: "Observation capture ID token from latest computer_use_observe." },
        topology_version: { type: "string", description: "Active display topology version token." },
        x: { type: "integer", minimum: 0, maximum: 999, description: "Normalized horizontal coordinate (0-999)." },
        y: { type: "integer", minimum: 0, maximum: 999, description: "Normalized vertical coordinate (0-999)." },
        delta_x: { type: "integer", minimum: -1000, maximum: 1000, description: "Optional horizontal scroll delta (-1000..1000)." },
        delta_y: { type: "integer", minimum: -1000, maximum: 1000, description: "Optional vertical scroll delta (-1000..1000)." },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["capture_id", "topology_version", "x", "y", "intent"],
      additionalProperties: false
    }
  };

  const DRAG_TOOL: Tool = {
    name: "computer_use_drag",
    description: "Dispatches a bounded same-display mouse drag operation from (start_x, start_y) to (end_x, end_y) with minimum safe button scope. Consumes active observation lease and guarantees input release.",
    inputSchema: {
      type: "object",
      properties: {
        capture_id: { type: "string", description: "Observation capture ID token from latest computer_use_observe." },
        topology_version: { type: "string", description: "Active display topology version token." },
        start_x: { type: "integer", minimum: 0, maximum: 999, description: "Normalized start horizontal coordinate (0-999)." },
        start_y: { type: "integer", minimum: 0, maximum: 999, description: "Normalized start vertical coordinate (0-999)." },
        end_x: { type: "integer", minimum: 0, maximum: 999, description: "Normalized end horizontal coordinate (0-999)." },
        end_y: { type: "integer", minimum: 0, maximum: 999, description: "Normalized end vertical coordinate (0-999)." },
        button: { type: "string", enum: ["left"], description: "Optional mouse button. Must be left." },
        intent: { type: "string", minLength: 1, description: "Clear explanation of the action's intent." }
      },
      required: ["capture_id", "topology_version", "start_x", "start_y", "end_x", "end_y", "intent"],
      additionalProperties: false
    }
  };

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
      tools: [
        STATUS_TOOL,
        OBSERVE_TOOL,
        AX_TREE_TOOL,
        AX_ACTION_TOOL,
        CLICK_TOOL,
        MOVE_TOOL,
        TYPE_TOOL,
        SHORTCUT_TOOL,
        SCROLL_TOOL,
        DRAG_TOOL
      ]
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const { name, arguments: rawArgs } = request.params;
    const args = rawArgs || {};

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

    if (name === "computer_use_ax_tree") {
      const parseRes = AXTreeInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_ax_tree: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("ax_tree", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_ax_action") {
      const parseRes = AXActionInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_ax_action: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("ax_action", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_click") {
      const parseRes = ClickInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_click: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("click", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_move") {
      const parseRes = MoveInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_move: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("move", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_type") {
      const parseRes = TypeInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_type: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("type", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_shortcut") {
      const parseRes = ShortcutInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_shortcut: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("shortcut", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_scroll") {
      const parseRes = ScrollInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_scroll: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("scroll", parseRes.data, extra?.signal);
      return formatToolResponse(ipcResp, name);
    }

    if (name === "computer_use_drag") {
      const parseRes = DragInputSchema.safeParse(args);
      if (!parseRes.success) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text: JSON.stringify({
                error: {
                  code: "INVALID_ARGUMENT",
                  message: `Invalid arguments for computer_use_drag: ${parseRes.error.message}`
                }
              }, null, 2)
            }
          ]
        };
      }
      const ipcResp = await hostClient.request("drag", parseRes.data, extra?.signal);
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
