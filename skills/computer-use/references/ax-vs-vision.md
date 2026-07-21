# Accessibility (AX) vs Vision Perception Matrix

| Perception Strategy | Primary Strengths | Trade-offs & Boundaries | Recommended Use Case |
|---|---|---|---|
| **Accessibility (`computer_use_ax_tree`)** | Deterministic element titles, exact bounding boxes, semantic roles | Unlabelled buttons, canvas apps (Figma/WebGPU), missing AX trees | Target native controls, input fields, menu items |
| **Vision (`computer_use_observe`)** | Fallback for non-standard UI, canvas, games, image elements | Coordinate estimation error, requires OCR/grid mapping | Unlabelled buttons, canvas, image elements |
