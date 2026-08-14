# Accessibility (AX) vs Vision Decision Matrix

> [!NOTE]
> Prefer `computer_use_ax_tree` plus `computer_use_ax_action` for exact semantic `press` on a shared workstation. Vision/coordinate and keyboard synthesis use global HID and require an exclusive GUI session.

| UI Scenario | Recommended Perception Mode | Tool to Call | Rationale |
|---|---|---|---|
| Desktop Window Perception (Active in M10) | **Visual Perception** | `computer_use_observe` | Captures current desktop display state as a high-resolution JPEG image payload. |
| Pointer Movement & Hover (Active in M10) | **Visual & Move Input** | `computer_use_move` | Dispatches single mouse movement to target coordinates without clicking. |
| Bounded Input Synthesis (Active in M10) | **Visual & Bounded Input** | `computer_use_click`, `computer_use_type`, `computer_use_shortcut` | Dispatches single click, Unicode text, or keyboard shortcuts using active `capture_id` lease. |
| Anchored Scroll & Drag (Active in M10) | **Visual & Scroll/Drag** | `computer_use_scroll`, `computer_use_drag` | Dispatches finite scroll wheel events or same-display drag operations. |
| Standard macOS native pressable controls | **Operator-safe AX** | `computer_use_ax_tree`, `computer_use_ax_action` | Opaque retained element, one-shot semantic press, zero global-HID fallback; reinspection required. |
| Password & Sensitive Fields (Active in M10) | **Accessibility Tree** | `computer_use_ax_tree` | Sensitive text fields automatically display `[REDACTED]` to prevent credential leaks. |
