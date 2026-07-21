# Observe-Action-Observe Loop Reference

> [!NOTE]
> **Milestone D2 Scope Note**: Action tools (`computer_use_click`, `move`, `drag`, `type`, `shortcut`, `scroll`) depicted in the conceptual workflow below are **disabled and non-runnable** during Milestone D2. In D2, only screen observation (`computer_use_observe`) and status queries (`computer_use_status`) are active. Action dispatch will be enabled in subsequent milestones.

## Conceptual Sequence Diagram (Future Milestones)

```text
Antigravity Agent         MCP Server          Native ComputerUseHost
      |                       |                         |
      |--- computer_use_observe ------->|
      |                       |--- Capture Display ---->|
      |<-- capture_id, jpeg --|<-- Return Frame --------|
      |                       |                         |
      |--- computer_use_click(x, y, capture_id) ------->| (Disabled in D2)
      |                       |--- Perform Action ----->|
      |<-- action status -----|<-- Action Result -------|
      |                       |                         |
      |--- computer_use_observe ------->| (Re-observe!)
```

1. **Step 1**: Capture screen state with `computer_use_observe`.
2. **Step 2**: Process visual state.
3. **Step 3**: Select target coordinates.
4. **Step 4**: Verify result with a fresh `computer_use_observe`.
