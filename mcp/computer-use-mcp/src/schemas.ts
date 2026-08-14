import { z } from "zod";

export const StatusInputSchema = z.object({}).strict();

export const MAX_SET_VALUE_UTF8_BYTES = 4_096;
export const OperatorSafeAXActionSchema = z.enum(["press", "set_value"]);

export function isBoundedWellFormedUTF8(value: string): boolean {
  const encoded = Buffer.from(value, "utf8");
  return encoded.length <= MAX_SET_VALUE_UTF8_BYTES &&
    encoded.toString("utf8") === value;
}

export const ObserveInputSchema = z.object({
  display_id: z.number().int().min(1).finite().optional()
}).strict();

export function validatePixelDimensions(width: number, height: number): boolean {
  if (!Number.isInteger(width) || !Number.isInteger(height)) return false;
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height)) return false;
  if (width <= 0 || height <= 0) return false;
  const total = width * height;
  return Number.isSafeInteger(total) && total <= 64_000_000;
}

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
  pid: z.number().int().positive().optional(),
  tcc_permission_state: z.enum(["granted", "denied"]),
  accessibility_available: z.boolean(),
  accessibility_trusted: z.boolean(),
  ax_tree_inspection_available: z.boolean().optional(),
  operator_safe_ax_available: z.boolean(),
  operator_safe_ax_actions: z.array(OperatorSafeAXActionSchema).max(2).refine(
    (actions) => actions.length === 0 || actions.join(",") === "press,set_value",
    { message: "operator_safe_ax_actions must be empty or canonical [press, set_value]" }
  ),
  supported_action_strategies: z.array(
    z.enum(["ax_semantic", "exclusive_global_hid"])
  ).max(2),
  global_hid_may_affect_pointer_or_focus: z.literal(true),
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
).refine(
  (data) => data.operator_safe_ax_available === (data.operator_safe_ax_actions.length === 2),
  { message: "operator_safe_ax_available must match operator_safe_ax_actions" }
).refine(
  (data) => data.operator_safe_ax_available === data.supported_action_strategies.includes("ax_semantic"),
  { message: "ax_semantic strategy must match operator_safe_ax_available" }
).refine(
  (data) => (data.input_mutation_state === "enabled") === data.supported_action_strategies.includes("exclusive_global_hid"),
  { message: "exclusive_global_hid strategy must match input_mutation_state" }
).refine(
  (data) => new Set(data.supported_action_strategies).size === data.supported_action_strategies.length,
  { message: "supported_action_strategies must not contain duplicates" }
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
  image_byte_length: z.number().int().positive().finite().max(10 * 1024 * 1024),
  image_sha256: z.string().regex(/^[0-9a-f]{64}$/, {
    message: "image_sha256 must be a lowercase 64-hex SHA-256 digest"
  }),
  normalized_bounds: z.object({
    min_x: z.literal(0),
    min_y: z.literal(0),
    max_x: z.literal(999),
    max_y: z.literal(999)
  }).strict()
}).strict();

export const AXTreeInputSchema = z.object({
  app_id: z.string().trim().min(1),
  max_depth: z.number().int().min(1).max(10).optional()
}).strict();

export const AXNodeSchema: z.ZodType<any> = z.lazy(() =>
  z.object({
    id: z.string().min(1).max(256),
    element_ref: z.string().min(1).max(256).optional(),
    supported_actions: z.array(OperatorSafeAXActionSchema).min(1).max(2).refine(
      (actions) => ["press", "set_value", "press,set_value"].includes(actions.join(",")),
      { message: "supported_actions must be unique and in canonical order" }
    ).optional(),
    role: z.string().min(1).max(256),
    subrole: z.string().max(256).optional(),
    identifier: z.string().max(256).optional(),
    description: z.string().max(256).optional(),
    title: z.string().max(256).optional(),
    value: z.string().max(256).optional(),
    enabled: z.boolean().optional(),
    focused: z.boolean().optional(),
    bounds: z.object({
      x: z.number().finite(),
      y: z.number().finite(),
      width: z.number().nonnegative().finite(),
      height: z.number().nonnegative().finite()
    }).strict(),
    children: z.array(AXNodeSchema).optional()
  }).strict().refine(
    (data) => (data.element_ref === undefined) === (data.supported_actions === undefined),
    { message: "element_ref and supported_actions must be present together" }
  ).refine(
    (data) => !data.supported_actions?.includes("set_value") || (
      data.enabled === true &&
      (data.role === "AXTextField" || data.role === "AXTextArea") &&
      data.subrole !== "AXSecureTextField"
    ),
    { message: "set_value may be advertised only on enabled non-secure text fields or text areas" }
  )
);

export const AXTargetAppSchema = z.object({
  pid: z.number().int().positive(),
  bundle_id: z.string().max(256).optional(),
  name: z.string().max(256).optional()
}).strict();

export function inspectTreeStructure(node: any, currentDepth = 1): { count: number; maxDepth: number; ids: Set<string>; hasDuplicateId: boolean } {
  let count = 1;
  let maxDepth = currentDepth;
  const ids = new Set<string>([node.id]);
  let hasDuplicateId = false;

  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      const childRes = inspectTreeStructure(child, currentDepth + 1);
      count += childRes.count;
      maxDepth = Math.max(maxDepth, childRes.maxDepth);
      for (const id of childRes.ids) {
        if (ids.has(id)) {
          hasDuplicateId = true;
        }
        ids.add(id);
      }
      if (childRes.hasDuplicateId) {
        hasDuplicateId = true;
      }
    }
  }
  return { count, maxDepth, ids, hasDuplicateId };
}

export const AXTreeDataSchema = z.object({
  target_app: AXTargetAppSchema,
  ax_snapshot_id: z.string().min(1).max(256),
  app_instance_ref: z.string().min(1).max(256),
  expires_at_ms: z.number().int().positive().finite(),
  topology_version: TopologyVersionSchema,
  node_count: z.number().int().min(1).max(500),
  max_depth_reached: z.number().int().min(1).max(10),
  truncated: z.boolean(),
  tree: AXNodeSchema
}).strict()
.refine(
  (data) => {
    const struct = inspectTreeStructure(data.tree);
    return data.node_count === struct.count;
  },
  { message: "node_count must match actual node count in tree" }
)
.refine(
  (data) => {
    const struct = inspectTreeStructure(data.tree);
    return data.max_depth_reached === struct.maxDepth;
  },
  { message: "max_depth_reached must match actual max depth in tree" }
)
.refine(
  (data) => {
    const struct = inspectTreeStructure(data.tree);
    return !struct.hasDuplicateId;
  },
  { message: "AX tree node IDs must be unique" }
);

const AXActionAuthorityFields = {
  ax_snapshot_id: z.string().trim().min(1).max(256),
  app_instance_ref: z.string().trim().min(1).max(256),
  element_ref: z.string().trim().min(1).max(256),
  topology_version: TopologyVersionSchema,
  intent: z.string().trim().min(1)
};

const AXPressActionInputSchema = z.object({
  ...AXActionAuthorityFields,
  action: z.literal("press"),
}).strict();

const AXSetValueActionInputSchema = z.object({
  ...AXActionAuthorityFields,
  action: z.literal("set_value"),
  value: z.string().max(MAX_SET_VALUE_UTF8_BYTES).superRefine((value, ctx) => {
    if (!isBoundedWellFormedUTF8(value)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `value must be well-formed UTF-8 no larger than ${MAX_SET_VALUE_UTF8_BYTES} bytes`
      });
    }
  })
}).strict();

export const AXActionInputSchema = z.discriminatedUnion("action", [
  AXPressActionInputSchema,
  AXSetValueActionInputSchema
]);

export const AXActionResultDataSchema = z.object({
  action_id: z.string().min(1).max(256),
  status: z.literal("dispatched"),
  strategy: z.literal("ax_semantic"),
  action: OperatorSafeAXActionSchema,
  ax_snapshot_id: z.string().min(1).max(256),
  app_instance_ref: z.string().min(1).max(256),
  element_ref: z.string().min(1).max(256),
  topology_version: TopologyVersionSchema,
  requires_reinspection: z.literal(true),
  global_hid_posts: z.literal(0),
  duration_ms: z.number().nonnegative().finite()
}).strict();

export const ClickInputSchema = z.object({
  capture_id: z.string().min(1),
  topology_version: TopologyVersionSchema,
  x: z.number().int().min(0).max(999),
  y: z.number().int().min(0).max(999),
  button: z.enum(["left", "right", "middle"]).optional(),
  click_count: z.number().int().min(1).max(3).optional(),
  intent: z.string().trim().min(1)
}).strict();

export const MoveInputSchema = z.object({
  capture_id: z.string().min(1),
  topology_version: TopologyVersionSchema,
  x: z.number().int().min(0).max(999),
  y: z.number().int().min(0).max(999),
  intent: z.string().trim().min(1)
}).strict();

export const ScrollInputSchema = z.object({
  capture_id: z.string().min(1),
  topology_version: TopologyVersionSchema,
  x: z.number().int().min(0).max(999),
  y: z.number().int().min(0).max(999),
  delta_x: z.number().int().min(-1000).max(1000).optional(),
  delta_y: z.number().int().min(-1000).max(1000).optional(),
  intent: z.string().trim().min(1)
}).strict().refine(
  (data) => (data.delta_x !== undefined && data.delta_x !== 0) || (data.delta_y !== undefined && data.delta_y !== 0),
  { message: "At least one of delta_x or delta_y must be specified and non-zero" }
);

export const DragInputSchema = z.object({
  capture_id: z.string().min(1),
  topology_version: TopologyVersionSchema,
  start_x: z.number().int().min(0).max(999),
  start_y: z.number().int().min(0).max(999),
  end_x: z.number().int().min(0).max(999),
  end_y: z.number().int().min(0).max(999),
  button: z.enum(["left"]).optional(),
  intent: z.string().trim().min(1)
}).strict();

export const TypeInputSchema = z.object({
  capture_id: z.string().min(1),
  topology_version: TopologyVersionSchema,
  text: z.string().min(1).max(1000),
  press_enter: z.boolean().optional(),
  intent: z.string().trim().min(1)
}).strict();

export const ShortcutInputSchema = z.object({
  capture_id: z.string().min(1),
  topology_version: TopologyVersionSchema,
  keys: z.array(z.string().trim().min(1)).min(1).max(5),
  intent: z.string().trim().min(1)
}).strict();

export const ActionResultDataSchema = z.object({
  action_id: z.string().min(1),
  status: z.enum(["dispatched", "indeterminate"]),
  capture_id: z.string().min(1),
  duration_ms: z.number().nonnegative().finite()
}).strict();
