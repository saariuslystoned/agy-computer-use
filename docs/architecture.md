# Architecture & Design Specification

## System Design
`agy-computer-use` bridges Google Antigravity / Gemini 3.6 Flash with macOS native UI automation APIs.

### 1. Dual Perception Engine
- **AXUIElement Engine**: Uses macOS Accessibility APIs to inspect element bounding boxes, roles, titles, labels, and state flags without visual latency.
- **ScreenCaptureKit Engine**: Captures screen frames via Metal/ScreenCaptureKit for direct multimodal visual reasoning.

### 2. Control Engine
- **CGEvent Injection**: Synthesizes low-level keyboard and mouse events (`CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`).
- **Coordinate Transformation**: Normalizes coordinates across Retina displays, logical point coordinates, and normalized `[0, 1000]` agent grids.

### 3. Antigravity Skill & MCP Bridge
- **MCP Server**: Provides JSON-RPC tool endpoints over stdio/IPC.
- **Antigravity Skill**: Exposes tools and operational guidance to Antigravity agents.
