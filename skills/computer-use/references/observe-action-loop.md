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
  -> dispatched + requires_reinspection + global_hid_posts=0
computer_use_ax_tree(same app_id)
  -> independently verify the intended state
```

Never use a traversal `id`, title, label, index, or bounds as action authority.
The opaque lease is consumed once. A dispatched action is not a verified effect.
Semantic/window/ancestry drift or any observed macOS session input counter
change returns a typed stale/intervention error. Recover only with a fresh
explicit-app AX tree; never retry the consumed lease.

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
