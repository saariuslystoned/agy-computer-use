# Observe-Action-Observe Loop Reference

> [!NOTE]
> **Milestone M9 Scope Note**: Bounded input synthesis actions (`computer_use_click`, `computer_use_type`, `computer_use_shortcut`) are **active** in Milestone M9 (`v0.1.0-dogfood-m9`). Each action atomically consumes the `capture_id` lease token from the latest `computer_use_observe`. Attempting a second input action without an intervening `computer_use_observe` fails closed with `STALE_CAPTURE`. Unbounded actions (`move`, `drag`, `scroll`) and `computer_use_ax_tree` remain disabled in M9.

## Sequence Diagram (Milestone M9 Active Loop)

```text
Antigravity Agent         MCP Server          Native ComputerUseHost
      |                       |                         |
      |--- computer_use_observe ------->|
      |                       |--- Capture Display ---->|
      |<-- capture_id, jpeg --|<-- Return Frame --------|
      |                       |                         |
      |--- computer_use_click(x, y, capture_id) ------->| (Active in M9)
      |                       |--- Perform Click ------>| (Lease Consumed!)
      |<-- action status -----|<-- Action Result -------|
      |                       |                         |
      |--- computer_use_observe ------->| (Re-observe required!)
      |<-- new capture_id ----|<-- Return Frame --------|
```

1. **Step 1**: Capture screen state with `computer_use_observe` to obtain a fresh `capture_id` and `topology_version`.
2. **Step 2**: Process visual state and determine target normalized coordinates (`0...999`) or input payload.
3. **Step 3**: Execute bounded action (`computer_use_click`, `computer_use_type`, `computer_use_shortcut`) passing active `capture_id`, `topology_version`, and nonblank `intent`.
4. **Step 4**: Perform fresh `computer_use_observe` to verify action outcome and obtain new `capture_id` lease for any subsequent action.
