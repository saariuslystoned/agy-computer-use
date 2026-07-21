import { z } from "zod";

export const GridCoordinateSchema = z.number().int().min(0).max(999);

export const ObserveSchema = z.object({
  display_id: z.number().int().optional().describe("Target display ID (defaults to primary display)")
});

export const AXTreeSchema = z.object({
  max_depth: z.number().int().min(1).max(10).default(10).describe("Maximum accessibility graph traversal depth"),
  app_id: z.string().optional().describe("Optional target application bundle identifier or name")
});

export const ClickSchema = z.object({
  x: GridCoordinateSchema.describe("Target X coordinate on normalized 0...999 grid"),
  y: GridCoordinateSchema.describe("Target Y coordinate on normalized 0...999 grid"),
  button: z.enum(["left", "right", "middle"]).default("left").describe("Mouse button to click"),
  click_count: z.number().int().min(1).max(3).default(1).describe("Number of clicks (1=single, 2=double, 3=triple)"),
  capture_id: z.string().describe("Capture ID from prior computer_use_observe action")
});

export const MoveSchema = z.object({
  x: GridCoordinateSchema.describe("Target X coordinate on normalized 0...999 grid"),
  y: GridCoordinateSchema.describe("Target Y coordinate on normalized 0...999 grid"),
  capture_id: z.string().describe("Capture ID from prior computer_use_observe action")
});

export const DragSchema = z.object({
  start_x: GridCoordinateSchema.describe("Start X coordinate on normalized 0...999 grid"),
  start_y: GridCoordinateSchema.describe("Start Y coordinate on normalized 0...999 grid"),
  end_x: GridCoordinateSchema.describe("End X coordinate on normalized 0...999 grid"),
  end_y: GridCoordinateSchema.describe("End Y coordinate on normalized 0...999 grid"),
  capture_id: z.string().describe("Capture ID from prior computer_use_observe action")
});

export const TypeSchema = z.object({
  text: z.string().min(1).max(1000).describe("Text to type into active element"),
  capture_id: z.string().describe("Capture ID from prior computer_use_observe action")
});

export const ShortcutSchema = z.object({
  keys: z.array(z.string()).min(1).describe("Keys array (e.g. ['command', 'c'])"),
  capture_id: z.string().describe("Capture ID from prior computer_use_observe action")
});

export const ScrollSchema = z.object({
  x: GridCoordinateSchema.describe("Target X coordinate on normalized 0...999 grid"),
  y: GridCoordinateSchema.describe("Target Y coordinate on normalized 0...999 grid"),
  delta_x: z.number().int().describe("Horizontal scroll delta"),
  delta_y: z.number().int().describe("Vertical scroll delta"),
  capture_id: z.string().describe("Capture ID from prior computer_use_observe action")
});
