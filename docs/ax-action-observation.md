# Issue 12: compound AX action and reinspection

The first implementation slice adds optional `observe` to `computer_use_ax_action` and a distinct native `ax_action_observe` IPC method. The latter prevents older hosts from accepting the mutation while silently ignoring a new option.

The native inspector retains the bounded tree and inspection depth alongside its existing one-shot authority. One operation gate covers dispatch plus polling. Dispatch uses the unchanged native validation and consumption path. Post-action reads bind to retained PID, bundle and launch identity before and after traversal. Input epochs remain conservative across the entire compound operation. The host checks topology again before returning an observed tree.

See the [operational contract](../.agents/skills/computer-use/references/action-observation.md) for options, result semantics, freshness, redaction, and recovery.

Acceptance remains limited to this first slice. Live Calculator and native text/form comparisons under the same Gemini 3.8 configuration are required before claiming qualification or measured speedups. Tests with injected readers prove the orchestration and no-repeat behavior; they do not establish macOS app compatibility, pointer/focus isolation, or model performance. Window images/discovery and session-scoped leases remain separate deliverables.
