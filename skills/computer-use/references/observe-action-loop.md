# Observe-Action-Observe Loop Reference

## Sequence Diagram

```text
Antigravity Agent         MCP Server          Native ComputerUseHost
      |                       |                         |
      |--- computer_use_observe ------->|
      |                       |--- Capture Display ---->|
      |<-- capture_id, jpeg --|<-- Return Frame --------|
      |                       |                         |
      |--- computer_use_click(x, y, capture_id) ------->|
      |                       |--- Perform Action ----->|
      |<-- action status -----|<-- Action Result -------|
      |                       |                         |
      |--- computer_use_observe ------->| (Re-observe!)
```

1. **Step 1**: Capture screen state with `computer_use_observe`.
2. **Step 2**: Process visual and AX state. Select target element.
3. **Step 3**: Dispatch action passing `capture_id`.
4. **Step 4**: Verify result with a fresh `computer_use_observe`.
