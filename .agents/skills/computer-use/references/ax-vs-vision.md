# Accessibility (AX) vs Vision Decision Matrix

> [!NOTE]
> **Milestone M10 Scope Note**: Visual perception via `computer_use_observe`, accessibility tree inspection via `computer_use_ax_tree`, and bounded input synthesis tools (`computer_use_click`, `computer_use_move`, `computer_use_type`, `computer_use_shortcut`, `computer_use_scroll`, `computer_use_drag`) are **active** in Milestone M10 (`v0.2.0-dogfood-m10`).

| UI Scenario | Recommended Perception Mode | Tool to Call | Rationale |
|---|---|---|---|
| Desktop Window Perception (Active in M10) | **Visual Perception** | `computer_use_observe` | Captures current desktop display state as a high-resolution JPEG image payload. |
| Pointer Movement & Hover (Active in M10) | **Visual & Move Input** | `computer_use_move` | Dispatches single mouse movement to target coordinates without clicking. |
| Bounded Input Synthesis (Active in M10) | **Visual & Bounded Input** | `computer_use_click`, `computer_use_type`, `computer_use_shortcut` | Dispatches single click, Unicode text, or keyboard shortcuts using active `capture_id` lease. |
| Anchored Scroll & Drag (Active in M10) | **Visual & Scroll/Drag** | `computer_use_scroll`, `computer_use_drag` | Dispatches finite scroll wheel events or same-display drag operations. |
| Standard macOS native controls (Active in M10) | **Accessibility Tree** | `computer_use_ax_tree` | Sub-millisecond element location, zero visual coordinate ambiguity, exact label matching. |
| Password & Sensitive Fields (Active in M10) | **Accessibility Tree** | `computer_use_ax_tree` | Sensitive text fields automatically display `[REDACTED]` to prevent credential leaks. |
