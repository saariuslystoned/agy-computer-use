# Background AX coexistence

Background `press` and `set_value` can coexist with unrelated operator mouse and
keyboard use when `computer_use_ax_tree` reports `intervention_scope: "app"`.
`global` (or a missing field from an older host) retains the conservative
session-wide guard. This field reports qualification, not permission to retry.

The host uses Apple's public passive `CGEventTapCreateForPid` delivery boundary
and `AXApplicationActivated` notifications. Actual target input or activation
invalidates pending authority even after switching away. Any window in that app
counts as the same target for this first slice. Foreground targets and apps that
cannot provide complete monitoring use the conservative guard from inspection.
An active app-scoped monitor that loses coverage fails closed. No automatic
re-enabling or downgrade can revive the lease.

The event tap has a dedicated run loop. Every authority sample checks its health
through a bounded 100 ms round trip; a 10 ms timer checks continued health.
Disabled-tap notifications are sticky. Accessibility trust, target liveness, and
secure-input state are checked. The full effective event mask is verified because
macOS can strip keyboard monitoring bits. Process-birth, retained window/element,
ancestry, fingerprint, expiry, consumption and replay checks remain authoritative.
A queued OS event can race dispatch; post-dispatch checking remains necessary and
an error is never evidence that no action happened.

This does not implement per-window session leases, independent concurrent targets,
window images, or background global mouse/keyboard injection. Those remain Issue
#12 follow-ups. The monitor is retained with the current bounded one-shot lease;
replacement, consumption or inspector destruction releases it (compound reads
retain it through reinspection).

Reference: current @Computer exposed runtime API and same disposable app, accessed
2026-09-16. `getApp`, app-targeted `click`/`setValue`, and action-plus-`getAXState`
are the behavioral reference. The service did not expose an upstream source SHA
or release version, so this is not a claim of auditing upstream `main` internals.
Apple's [event tap API](https://developer.apple.com/documentation/coregraphics/cgevent)
provides the public native mechanism used by our independent implementation.
