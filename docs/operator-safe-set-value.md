# Operator-Safe AX `set_value`

`computer_use_ax_action` accepts `action: "set_value"` only for an opaque
`element_ref` returned by the same fresh explicit-app `computer_use_ax_tree`
inspection. The node must advertise `set_value`; secure text nodes never do and
receive no actionable ref.

The request includes the existing snapshot, app-instance, element, and topology
authority plus a call-scoped `value`. Empty text is valid for clearing a field.
The value must be well-formed UTF-8 no larger than 4096 bytes. `press` rejects a
`value` field.

Before dispatch, the native host consumes the one-shot lease and revalidates:

1. live topology and the retained topology version;
2. process PID, bundle identity, process birth, and element/window PIDs;
3. exact window identity, ancestry, element/window fingerprints, and macOS
   combined-session input counters;
4. live role/subrole, enabled state, non-secure classification, and whether
   `kAXValueAttribute` is still settable.

It then calls `AXUIElementSetAttributeValue` exactly once. This path never
focuses the target, uses the pasteboard, calls the global input engine, posts a
`CGEvent`, or retries automatically. A success receipt records the action,
`strategy: "ax_semantic"`, `requires_reinspection: true`, and
`global_hid_posts: 0`; it does not contain the submitted value.

Typed failures include `STALE_AX_SNAPSHOT`, `STALE_OPERATION`,
`AX_ACTION_REPLAYED`, `SECURE_AX_VALUE_UNSUPPORTED`, `AX_ELEMENT_DISABLED`,
`AX_VALUE_NOT_SETTABLE`, `NONINTERFERING_ACTION_UNSUPPORTED`,
`USER_INTERVENED`, and `OUTCOME_UNKNOWN`. After dispatch, intervention,
uncertainty, or transport ambiguity, obtain a fresh explicit-app AX inspection
and adjudicate observed state. Never reuse the old ref or automatically submit
the value again.

Native status, AX-node action metadata, MCP schemas, fixtures, and the mirrored
skills share this contract and must roll out from the same source revision. A
press-only host and set-value-aware MCP bridge are intentionally not negotiated;
the mismatch fails validation.
