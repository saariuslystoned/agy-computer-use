# Observe-Action-Observe Loop Reference

> [!NOTE]
> **Milestone M10 Scope Note**: Nine active tools (`computer_use_status`, `computer_use_observe`, `computer_use_ax_tree`, `computer_use_click`, `computer_use_move`, `computer_use_type`, `computer_use_shortcut`, `computer_use_scroll`, `computer_use_drag`) are **active** in Milestone M10 (`v0.2.0-dogfood-m10`). Each input action atomically consumes the `capture_id` lease token from the latest `computer_use_observe`. Attempting a second input action without an intervening `computer_use_observe` fails closed with `STALE_CAPTURE`.

## Sequence Diagram (Milestone M10 Active Loop)

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
