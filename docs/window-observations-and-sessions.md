# Exact-window observations and scoped AX leases

`computer_use_targets {}` discovers bounded running-app metadata. Pass an explicit
`app_id` to obtain exact opaque `window_ref` values. `computer_use_window_observe`
requires an explicit app and, for multiple windows, one of those references. It
returns the selected window's image and compact AX tree together. It never selects
whichever application happens to be frontmost. Windows whose centers cannot be
assigned to one active display are omitted with `truncated: true`; usable siblings
remain explicitly selectable. An incomplete discovery never permits implicit
single-window selection.

Each MCP connection creates a random logical session ID and sends it privately to
the native host. Tool arguments cannot impersonate another connection's session.
This is controller isolation, not authentication: the owner-only Unix socket is the
security boundary. Direct IPC callers may explicitly supply a bounded session ID;
omitting it uses the compatibility `legacy` session.

The host retains at most 32 AX leases, each for 30 seconds, and at most 64 window
references, each for five minutes. Discovery limits one app to 16 windows and the
app inventory to 128 entries. Capacity fails closed without evicting another
session. Successful rediscovery replaces that session's old references for that
app. A five-second cleanup timer releases expired native references/monitors;
expiry is checked on every operation. MCP close revokes its own leases and window
references; process termination relies on bounded expiry if close cannot run.

AX leases are keyed by session and exact process/window. Inspecting another target
preserves prior authority. A second inspection replaces only the same session's
same-target lease. The existing operation gate serializes native mutations. Before
dispatch, the first writer consumes all competing leases for that target, including
other sessions; a later writer must reinspect. Legacy app-wide snapshots overlap
all that app's windows. Unrelated windows retain their authority. App-scoped
intervention still conservatively cancels every pending lease in the target app
on input/activation; it is not a claim of window-scoped input monitoring.

Window references retain process birth, the exact AX window object and a uniquely
matched on-screen public window-server ID. Minimized/off-screen targets fail closed.
Matching requires unambiguous geometry/title
correlation; unavailable or ambiguous mapping fails rather than guessing. Window
movement permits a fresh observation of the same reference, while an older action
lease fails its existing geometry fingerprint. Window replacement, window-set
changes and newly opened dialogs require rediscovery. No reference silently moves
to the new window. Attached modal sheets fail closed for window images and pending
parent-window authority because the capture API does not promise to include their
separate surface; use fresh explicit-app AX inspection to resolve the dialog.

The host selects the display containing the window center. Missing or overlapping
display coverage fails. The returned top-left window bounds are global screen
points. Image pixels map through `screen_points_per_pixel_x/y`; the returned
display-normalized scale and offset map those pixels to the existing 0–999 display
grid. A straddling window can map outside that grid. These are geometry metadata,
not permission for coordinate input. Window image IDs are never promoted to the
legacy global-HID capture lease.

AX is read before and after the exact-window ScreenCaptureKit image. The second
read issues fresh references even when semantics are unchanged. A concurrent
writer, process/window replacement, changed semantics, geometry or topology makes
the entire observation fail without returning the image or authority. Timing
metadata says `atomic: false` and `consistency: stable_bracket`: the bracket detects
observed drift; it cannot rule out a brief animation or changes that revert between
reads. Do not describe this as atomic image/AX capture.

AX strings remain bounded/redacted. `image_redaction: none` states explicitly that
AX redaction does not redact screenshot pixels. Controllers must choose an
appropriate target before requesting an image. The native capture excludes the
physical cursor and uses the window's native pixel scale for readable text.

Public capture reference: Apple's
[desktop-independent window filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter).
The available OpenAI `cua` documentation was refreshed September 16, 2026: explicit
app/tab bindings, AX differences, combined AX/image state and persistent
single-call action-plus-state are documented. Its source/release SHA was not
available. This implementation does not claim audited upstream-main parity or
knowledge of private input mechanisms.

Global HID remains a separate exclusive-use policy surface; this change neither
adds global fallback nor closes Issue #7's native exclusive-control enforcement
gap. HUD and permission onboarding remain out of scope.
