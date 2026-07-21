import { z } from "zod";

export const GridCoordinateSchema = z.number().int().min(0).max(999);

export const ObserveSchema = z.object({
  display_id: z.number().int().optional().describe("Target display ID (defaults to primary display)")
}).strict();

export const AXTreeSchema = z.object({
  max_depth: z.number().int().min(1).max(10).default(10).describe("Maximum accessibility graph traversal depth"),
  app_id: z.string().optional().describe("Optional target application bundle identifier or name")
}).strict();

export const IntentSchema = z.string()
  .trim()
  .min(1, "Intent must contain non-whitespace characters")
  .max(200, "Intent must not exceed 200 characters")
  .regex(/^.*\S.*$/, "Intent must contain at least one non-whitespace character")
  .describe("Non-empty, bounded description of action intent (max 200 chars)");

export const TopologyVersionSchema = z.string().min(1).describe("Display topology version token");

export const ClickSchema = z.object({
  x: GridCoordinateSchema.describe("Target X coordinate on normalized 0...999 grid"),
  y: GridCoordinateSchema.describe("Target Y coordinate on normalized 0...999 grid"),
  button: z.enum(["left", "right", "middle"]).default("left").describe("Mouse button to click"),
  click_count: z.number().int().min(1).max(3).default(1).describe("Number of clicks (1=single, 2=double, 3=triple)"),
  capture_id: z.string().min(1).describe("Capture ID from prior computer_use_observe action"),
  topology_version: TopologyVersionSchema,
  intent: IntentSchema
}).strict();

export const MoveSchema = z.object({
  x: GridCoordinateSchema.describe("Target X coordinate on normalized 0...999 grid"),
  y: GridCoordinateSchema.describe("Target Y coordinate on normalized 0...999 grid"),
  capture_id: z.string().min(1).describe("Capture ID from prior computer_use_observe action"),
  topology_version: TopologyVersionSchema,
  intent: IntentSchema
}).strict();

export const DragSchema = z.object({
  start_x: GridCoordinateSchema.describe("Start X coordinate on normalized 0...999 grid"),
  start_y: GridCoordinateSchema.describe("Start Y coordinate on normalized 0...999 grid"),
  end_x: GridCoordinateSchema.describe("End X coordinate on normalized 0...999 grid"),
  end_y: GridCoordinateSchema.describe("End Y coordinate on normalized 0...999 grid"),
  capture_id: z.string().min(1).describe("Capture ID from prior computer_use_observe action"),
  topology_version: TopologyVersionSchema,
  intent: IntentSchema
}).strict();

export const TypeSchema = z.object({
  text: z.string().min(1).max(1000).describe("Text to type into active focused element"),
  press_enter: z.boolean().default(false).describe("Optional flag to simulate pressing enter after typing text"),
  capture_id: z.string().min(1).describe("Capture ID from prior computer_use_observe action"),
  topology_version: TopologyVersionSchema,
  intent: IntentSchema
}).strict();

export const ShortcutSchema = z.object({
  keys: z.array(z.string()).min(1).describe("Keys array (e.g. ['command', 'c'])"),
  capture_id: z.string().min(1).describe("Capture ID from prior computer_use_observe action"),
  topology_version: TopologyVersionSchema,
  intent: IntentSchema
}).strict();

export const ScrollSchema = z.object({
  x: GridCoordinateSchema.describe("Target X coordinate on normalized 0...999 grid"),
  y: GridCoordinateSchema.describe("Target Y coordinate on normalized 0...999 grid"),
  delta_x: z.number().int().default(0).describe("Horizontal scroll delta"),
  delta_y: z.number().int().default(0).describe("Vertical scroll delta"),
  direction: z.enum(["up", "down", "left", "right"]).optional().describe("Optional scroll direction helper"),
  capture_id: z.string().min(1).describe("Capture ID from prior computer_use_observe action"),
  topology_version: TopologyVersionSchema,
  intent: IntentSchema
}).strict();

export const DisplayInfoSchema = z.object({
  id: z.number().int(),
  width_points: z.number().positive(),
  height_points: z.number().positive(),
  scale_factor: z.number().positive(),
  origin_x: z.number(),
  origin_y: z.number(),
  pixel_width: z.number().int().positive(),
  pixel_height: z.number().int().positive(),
  rotation: z.number()
}).strict();

export const DisplayTopologySchema = z.object({
  version: z.string().min(1),
  primary_display_id: z.number().int(),
  displays: z.array(DisplayInfoSchema).min(1)
}).strict();

export const StatusDataSchema = z.object({
  connected: z.boolean(),
  tcc_permission_state: z.enum(["granted", "denied"]),
  accessibility_available: z.boolean(),
  accessibility_trusted: z.boolean(),
  input_mutation_state: z.enum(["enabled", "disabled"]),
  topology_version: z.string().min(1),
  primary_display_id: z.number().int(),
  display_count: z.number().int().min(1),
  topology: DisplayTopologySchema
}).strict();

export const ObserveDataSchema = z.object({
  capture_id: z.string().min(1),
  timestamp: z.number().int().positive(),
  topology_version: z.string().min(1),
  display_id: z.number().int(),
  width_points: z.number().positive(),
  height_points: z.number().positive(),
  scale_factor: z.number().positive(),
  pixel_width: z.number().int().positive(),
  pixel_height: z.number().int().positive(),
  image_format: z.string().min(1),
  image_data_base64: z.string().min(1),
  normalized_bounds: z.object({
    min_x: z.number().int(),
    min_y: z.number().int(),
    max_x: z.number().int(),
    max_y: z.number().int()
  }).strict()
}).strict();
