# Accessibility (AX) vs Vision Decision Matrix

> [!NOTE]
> **Milestone M9 Scope Note**: Visual perception via `computer_use_observe` and bounded input synthesis tools (`computer_use_click`, `computer_use_type`, `computer_use_shortcut`) are active in Milestone M9 (`v0.1.0-dogfood-m9`). Accessibility tree inspection (`computer_use_ax_tree`) and unbounded input actions (`move`, `drag`, `scroll`) remain disabled (`TARGET_UNREACHABLE` / `MUTATION_DISABLED`).

| UI Scenario | Recommended Perception Mode | Tool to Call | Rationale |
|---|---|---|---|
| Desktop Window Perception (Active in M9) | **Visual Perception** | `computer_use_observe` | Captures current desktop display state as a high-resolution JPEG image payload. |
| Bounded Input Synthesis (Active in M9) | **Visual & Bounded Input** | `computer_use_click`, `computer_use_type`, `computer_use_shortcut` | Dispatches single click, Unicode text, or whitelisted navigation shortcuts using active `capture_id` lease. |
| Standard macOS native controls (Disabled) | **Accessibility Tree** | `computer_use_ax_tree` (Disabled in M9) | Sub-millisecond element location, zero visual coordinate ambiguity, exact label matching. |
| Password & Sensitive Fields (Disabled) | **Accessibility Tree** | `computer_use_ax_tree` (Disabled in M9) | Sensitive text fields automatically display `[REDACTED]` to prevent credential leaks. |
