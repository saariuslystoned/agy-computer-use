# ADR 0005: Observation and Action Freshness

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Executing actions on dynamic UI elements based on stale desktop screenshots can cause accidental clicks on wrong windows or buttons.

## Decision
1. **Capture Preconditions**:
   - Every screenshot/AX observation assigns a unique `capture_id` and timestamp.
   - Input actions (`click`, `move`, `drag`, `type`) must include the target `capture_id`.
2. **Freshness Validation**:
   - If the `capture_id` is expired or does not match current state, the host returns a `staleCapture` error requiring a new observation before retry.
3. **Action Serialization & Input Cleanup**:
   - Actions are strictly serialized. Held modifier keys or mouse buttons are guaranteed to be released even on error or timeout.
