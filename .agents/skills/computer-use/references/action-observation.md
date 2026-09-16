# Compound AX action observations

Add `observe: {"condition":"snapshot","timeout_ms":2000}` to the existing `computer_use_ax_action` arguments. The native host dispatches exactly one existing `press` or `set_value`, then reads the same process under the same operation gate. It uses the prior inspection's depth; the caller cannot retarget the post-action read.

- `snapshot`: return the next successful tree, with `changed` or `unchanged` relative to the original bounded tree.
- `semantic_change`: poll read-only snapshots at intervals up to 100 ms until a semantic change or the observation deadline.
- `timeout_ms`: required integer, 100–2000; starts after dispatch. AX calls use bounded messaging timeouts and the traversal checks a monotonic deadline. This is a cooperative observation budget, not a hard end-to-end latency guarantee. Late trees are discarded.

The dispatch receipt retains `status: "dispatched"` and `requires_reinspection: true`, describing the original consumed lease. `observation` supplies the result of that reinspection:

| Observation status | Meaning | Next step |
| --- | --- | --- |
| `changed` | A difference was observed in the bounded AX tree. | Verify the intended effect, then use fresh refs from `state`. |
| `unchanged` | The next bounded snapshot had no semantic difference. | Inspect the returned state; do not assume the action failed. |
| `timed_out` | The observation condition was not met within budget, or a read timed out. | No actionable state is returned. Obtain fresh state; adjudicate the effect before another mutation. |
| `failed` | Observation failed, including intervention or changed process identity. | Read `error_code`; dispatch still occurred. Do not repeat the mutation automatically. |

An action-side error retains the existing typed error envelope and stops the operation. The host does not poll or repeat the mutation after an action error. Transport uncertainty remains `OUTCOME_UNKNOWN`; never replay the old reference or value.

The change summary compares already-redacted semantic fields, geometry and capabilities while ignoring new opaque authority refs. It gives added/removed/changed counts and at most 16 traversal IDs. Those IDs are perception only; only `state` contains actionable refs. Truncated source trees and capped summaries are marked. Unchanged bounded semantics cannot establish that nothing outside the observed tree changed.

A returned tree may contain non-secure text read from the app, including a value just set. The submitted payload is not echoed into the dispatch receipt, summary, or error; normal AX observation/redaction rules apply to `state`. Never send secrets through `set_value`.

The MCP bridge sends a distinct native `ax_action_observe` request. Older hosts fail before dispatch rather than silently ignoring `observe`. The existing ten tools and unmodified `ax_action` route remain available.

This first slice is app/process-scoped. Exact window discovery/images, independent session leases, and target-qualified human intervention are later Issue #12 slices. The conservative session-wide intervention policy remains active.
