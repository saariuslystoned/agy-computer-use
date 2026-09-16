# Window observations and sessions

Use `computer_use_targets {}` to discover running apps, then pass an explicit
`app_id` to discover windows. Pass the selected opaque `window_ref` and app to
`computer_use_window_observe`. If more than one window exists, do not guess.
Window references expire after five minutes and belong to this MCP connection.
Replacement or a changed window/dialog set requires fresh discovery.

A window observation returns a window-only JPEG, compact AX semantics/capabilities,
geometry and non-atomic timing. Use `state` references for semantic press/set_value.
The host resolves display and pixel transforms. Window image IDs grant no global
HID authority. AX redaction does not redact image pixels (`image_redaction: none`).
`stable_bracket` means geometry/semantics matched before and after capture, not that
pixels and AX were captured atomically. A mismatched observation fails; reinspect.

Each connection owns independent bounded 30-second AX leases. Inspecting another
app/window preserves prior leases; reinspection replaces only that connection's
same-target state. The first same-target writer invalidates competing leases.
Different windows can retain independent leases, while takeover monitoring is
still conservatively application-scoped. Capacity fails closed; expiry and
connection close clean up references. Never share refs across connections.

A stale action must not be replayed. Obtain fresh explicit-target state, verify
whether the intended effect already occurred, and decide the next action using
new authority. Uncertainty never authorizes an automatic retry.
