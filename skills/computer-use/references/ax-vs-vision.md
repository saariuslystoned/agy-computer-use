# Accessibility (AX) vs Vision Decision Matrix

| UI Scenario | Recommended Perception Mode | Tool to Call | Rationale |
|---|---|---|---|
| Standard macOS native controls (Buttons, TextFields, Menus) | **Accessibility Tree** | `computer_use_ax_tree` | Sub-millisecond element location, zero visual coordinate ambiguity, exact label matching. |
| Password & Sensitive Fields | **Accessibility Tree** | `computer_use_ax_tree` | Sensitive text fields automatically display `[REDACTED]` to prevent credential leaks. |
| Web Canvas, Video Player, Custom Drawn UI | **Visual Perception** | `computer_use_observe` | Non-standard DOM elements not exposed to macOS accessibility system. |
| Icon-only buttons without accessibility labels | **Dual Perception** | `computer_use_observe` + `computer_use_ax_tree` | Use visual image for location and AX tree for bounding box confirmation. |
