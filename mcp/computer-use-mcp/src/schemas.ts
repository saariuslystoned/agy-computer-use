import { z } from "zod";

export const StatusInputSchema = z.object({}).strict();

export const ObserveInputSchema = z.object({
  display_id: z.number().int().min(1).finite().optional()
}).strict();

export const TopologyVersionSchema = z
  .string()
  .regex(/^top-sha256-[0-9a-f]{64}$/, {
    message: "Topology version must be exact format top-sha256-<64_hex_chars>"
  });

// Single canonical Base64 string schema validator WITHOUT Buffer decoding allocation
export const Base64ImageSchema = z.string().superRefine((data, ctx) => {
  if (data.length % 4 !== 0) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string length must be a multiple of 4" });
    return;
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string contains invalid characters or misplaced padding" });
    return;
  }

  let paddingCount = 0;
  if (data.endsWith("==")) {
    paddingCount = 2;
    const lastChar = data[data.length - 3];
    if (!"AQgw".includes(lastChar)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string contains invalid unused padding bits" });
      return;
    }
  } else if (data.endsWith("=")) {
    paddingCount = 1;
    const lastChar = data[data.length - 2];
    if (!"AEIMQUYcgkosw048".includes(lastChar)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Base64 image string contains invalid unused padding bits" });
      return;
    }
  }

  const decodedLen = (data.length / 4) * 3 - paddingCount;
  if (decodedLen > 10 * 1024 * 1024) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Decoded image data size exceeds 10 MiB limit" });
    return;
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
    min_x: z.literal(0),
    min_y: z.literal(0),
    max_x: z.literal(999),
    max_y: z.literal(999)
  }).strict()
}).strict();
