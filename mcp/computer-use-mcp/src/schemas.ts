import { z } from "zod";

export const TopologyVersionSchema = z
  .string()
  .regex(/^top-sha256-[0-9a-f]{64}$/, {
    message: "Topology version must be exact format top-sha256-<64_hex_chars>"
  });

export const Base64ImageSchema = z.string().superRefine((data, ctx) => {
  if (data.length % 4 !== 0) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string length must be a multiple of 4" });
    return;
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string contains invalid characters" });
    return;
  }
  try {
    const buf = Buffer.from(data, "base64");
    if (buf.toString("base64") !== data) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string is not canonically encoded" });
      return;
    }
  } catch {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Failed to decode base64 string" });
  }
});

export const DisplayInfoSchema = z.object({
  id: z.number().int().positive().finite(),
  width_points: z.number().positive().finite(),
  height_points: z.number().positive().finite(),
  scale_factor: z.number().positive().finite(),
  origin_x: z.number().finite(),
  origin_y: z.number().finite(),
  pixel_width: z.number().int().positive().finite(),
  pixel_height: z.number().int().positive().finite(),
  rotation: z.number().finite()
}).strict();

export const DisplayTopologySchema = z.object({
  version: TopologyVersionSchema,
  primary_display_id: z.number().int().positive().finite(),
  displays: z.array(DisplayInfoSchema).min(1)
}).strict().refine(
  (data) => data.displays.some((d) => d.id === data.primary_display_id),
  { message: "primary_display_id must exist in displays array" }
).refine(
  (data) => {
    const ids = data.displays.map((d) => d.id);
    return new Set(ids).size === ids.length;
  },
  { message: "displays array must not contain duplicate display IDs" }
);

export const StatusDataSchema = z.object({
  connected: z.boolean(),
  tcc_permission_state: z.enum(["granted", "denied"]),
  accessibility_available: z.boolean(),
  accessibility_trusted: z.boolean(),
  input_mutation_state: z.enum(["enabled", "disabled"]),
  topology_version: TopologyVersionSchema,
  primary_display_id: z.number().int().positive().finite(),
  display_count: z.number().int().positive().finite(),
  topology: DisplayTopologySchema
}).strict().refine(
  (data) => data.topology_version === data.topology.version,
  { message: "topology_version must match topology.version" }
).refine(
  (data) => data.primary_display_id === data.topology.primary_display_id,
  { message: "primary_display_id must match topology.primary_display_id" }
).refine(
  (data) => data.display_count === data.topology.displays.length,
  { message: "display_count must match topology.displays array length" }
);

export const ObserveDataSchema = z.object({
  capture_id: z.string().min(1),
  timestamp: z.number().int().positive().finite(),
  topology_version: TopologyVersionSchema,
  display_id: z.number().int().positive().finite(),
  width_points: z.number().positive().finite(),
  height_points: z.number().positive().finite(),
  scale_factor: z.number().positive().finite(),
  pixel_width: z.number().int().positive().finite(),
  pixel_height: z.number().int().positive().finite(),
  image_format: z.literal("jpeg"),
  image_data_base64: Base64ImageSchema,
  normalized_bounds: z.object({
    min_x: z.number().int().min(0).max(999).finite(),
    min_y: z.number().int().min(0).max(999).finite(),
    max_x: z.number().int().min(0).max(999).finite(),
    max_y: z.number().int().min(0).max(999).finite()
  }).strict()
}).strict();
