# ADR 0004: Coordinate Authority and Display Topology Transforms

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
macOS supports multi-display configurations with Retina scaling factors (e.g. 2x, 3x) and negative origins (e.g. display left of primary display at `x = -1920`). Antigravity agents operate on normalized integer grid coordinates (`0...999`).

## Decision
1. **Single Coordinate Authority**:
   - The native Swift host is the sole authority for display topology, resolution detection, scale factor mapping, and negative origin offsets.
2. **Normalized Agent Grid**:
   - MCP tools accept integer coordinates in `[0, 999]` normalized space.
   - Host transforms `(x_norm, y_norm)` to logical macOS points `(x_point, y_point)` and physical retina pixels `(x_pixel, y_pixel)` based on the target display bounds.
3. **Topology Staleness Protection**:
   - Responses include a `topology_version` token. Input actions referencing an outdated `topology_version` are rejected with `staleTopology`.
