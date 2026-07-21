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

export const TopologyVersionSchema = z.string()
  .startsWith("top-sha256-", "Topology version must start with top-sha256-")
  .length(75, "Topology version must be top-sha256- followed by 64 hex characters")
  .describe("Display topology version token");

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
  version: TopologyVersionSchema,
  primary_display_id: z.number().int(),
  displays: z.array(DisplayInfoSchema).min(1)
}).strict().refine(t => t.displays.some(d => d.id === t.primary_display_id), {
  message: "Primary display ID must exist in displays list"
}).refine(t => {
  const ids = t.displays.map(d => d.id);
  return new Set(ids).size === ids.length;
}, {
  message: "Display IDs in topology must be unique"
});

export const StatusDataSchema = z.object({
  connected: z.boolean(),
  tcc_permission_state: z.enum(["granted", "denied"]),
  accessibility_available: z.boolean(),
  accessibility_trusted: z.boolean(),
  input_mutation_state: z.enum(["enabled", "disabled"]),
  topology_version: TopologyVersionSchema,
  primary_display_id: z.number().int(),
  display_count: z.number().int().min(1),
  topology: DisplayTopologySchema
}).strict().refine(s => s.topology_version === s.topology.version, {
  message: "topology_version must match topology.version"
}).refine(s => s.primary_display_id === s.topology.primary_display_id, {
  message: "primary_display_id must match topology.primary_display_id"
}).refine(s => s.display_count === s.topology.displays.length, {
  message: "display_count must equal topology.displays.length"
});

export const Base64ImageSchema = z.string().min(1).refine(val => {
  if (val.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(val)) return false;
  return true;
}, { message: "Invalid canonical Base64 string" });

export const ObserveDataSchema = z.object({
  capture_id: z.string().min(1),
  timestamp: z.number().int().positive(),
  topology_version: TopologyVersionSchema,
  display_id: z.number().int(),
  width_points: z.number().positive(),
  height_points: z.number().positive(),
  scale_factor: z.number().positive(),
  pixel_width: z.number().int().positive(),
  pixel_height: z.number().int().positive(),
  image_format: z.enum(["jpeg"]),
  image_data_base64: Base64ImageSchema,
  normalized_bounds: z.object({
    min_x: z.number().int(),
    min_y: z.number().int(),
    max_x: z.number().int(),
    max_y: z.number().int()
  }).strict()
}).strict();
