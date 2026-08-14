# Observe-Action-Observe Loop Reference

> [!NOTE]
> The ten-tool surface has two different lease loops. Prefer the exact-element AX loop on shared workstations. The display-coordinate loop uses global HID and is allowed only in an explicitly exclusive GUI session.

## Operator-safe AX loop

```text
computer_use_status
  -> require operator-safe AX availability
computer_use_ax_tree(app_id)
  -> ax_snapshot_id + app_instance_ref + actionable element_ref
computer_use_ax_action(..., action="press")
  or computer_use_ax_action(..., action="set_value", value=<transient>)
  -> dispatched + requires_reinspection + global_hid_posts=0
computer_use_ax_tree(same app_id)
  -> independently verify the intended state
```

Never use a traversal `id`, `identifier`, `description`, title, label, index, or bounds as action authority.
The opaque lease is consumed once. A dispatched action is not a verified effect.
Semantic/window/ancestry drift or any observed macOS session input counter
change returns a typed stale/intervention error. A read-only tree inspection
that returns `USER_INTERVENED` may be retried because it issued no lease. After
`computer_use_ax_action` is called, however, every error may follow an
already-dispatched AX mutation: never automatically repeat the action or reuse
the old value/ref. Re-inspect,
verify the target state, and let the controller or operator decide whether a
new action is still needed.

Omit `value` for `press`. For an advertised `set_value`, `value` is required
(empty is allowed), must be well-formed UTF-8 no larger than 4096 bytes, is
call-scoped, and is never returned in the receipt or error. Secure fields never
advertise `set_value` or receive an actionable ref.

## Exclusive global-HID loop

```text
Antigravity Agent         MCP Server          Native ComputerUseHost
      |                       |                         |
      |--- computer_use_observe ------->|
      |                       |--- Capture Display ---->|
      |<-- capture_id, jpeg --|<-- Return Frame --------|
      |                       |                         |
      |--- input_action(x, y, capture_id) ------------->| (Active in M10)
      |                       |--- Dispatch Action ---->| (Lease Consumed!)
      |<-- action status -----|<-- Action Result -------|
      |                       |                         |
      |--- computer_use_observe ------->| (Re-observe required!)
      |<-- new capture_id ----|<-- Return Frame --------|
```

1. **Step 1**: Capture screen state with `computer_use_observe` to obtain a fresh `capture_id` and `topology_version`.
2. **Step 2**: Process visual/AX state and determine target normalized coordinates (`0...999`) or input payload.
3. **Step 3**: Execute input action (`click`, `move`, `type`, `shortcut`, `scroll`, `drag`) passing active `capture_id`, `topology_version`, and nonblank `intent`.
4. **Step 4**: Perform fresh `computer_use_observe` to verify action outcome and obtain new `capture_id` lease for any subsequent action.
