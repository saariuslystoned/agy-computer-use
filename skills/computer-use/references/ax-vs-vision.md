# Accessibility (AX) vs Vision Decision Matrix

> [!NOTE]
> **Milestone D2 Scope Note**: `computer_use_ax_tree` is **disabled and non-runnable** during Milestone D2 (`TARGET_UNREACHABLE`). In D2, visual perception via `computer_use_observe` is the active perception tool. Accessibility tree inspection will be enabled in subsequent milestones.

| UI Scenario | Recommended Perception Mode | Tool to Call | Rationale |
|---|---|---|---|
| Desktop Window Perception (Active in D2) | **Visual Perception** | `computer_use_observe` | Captures current desktop display state as a high-resolution JPEG image payload. |
| Standard macOS native controls (Future) | **Accessibility Tree** | `computer_use_ax_tree` (Disabled in D2) | Sub-millisecond element location, zero visual coordinate ambiguity, exact label matching. |
| Password & Sensitive Fields (Future) | **Accessibility Tree** | `computer_use_ax_tree` (Disabled in D2) | Sensitive text fields automatically display `[REDACTED]` to prevent credential leaks. |
