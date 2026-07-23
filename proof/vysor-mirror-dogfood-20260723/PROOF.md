# PROOF — Vysor Phone-Mirror Dogfood (agy-cu-vysor-mirror-dogfood-01-20260723)

Lane: vysor-phone-mirror skill extension (cockpit-assigned, Claude worker)
Host: aiworker-02 (macOS 26.5.2), runtime: M10-D3 worktree
`/Users/aiworker02/Developer/worktrees/agy-computer-use-m10-d3-20260723`
(v0.2.0-dogfood-m10, nine-tool surface), staged `ComputerUseHost.app`, TCC granted.
Device: registered swarm test device **Pixel 10 Pro XL** (`pixel10_xl_sender`),
serial masked `63310DLC*****`, USB, mirrored via Vysor Pro 5.0.72
(`com.electron.vysor`). No other device attached.

## What was proven

1. **Loop reachability over the production surface** — `tools/list` returned all
   nine M10 tools; `computer_use_status`: `tcc_permission_state=granted`,
   `input_mutation_state=enabled`, single display id 7 (1920x1080 pt @2x,
   3840x2160 px). Journal: `events.jsonl` (initialize/tools/status rows).
2. **Semantic Vysor window targeting via AX** — `computer_use_ax_tree`
   (`app_id=com.electron.vysor`) resolved the app (pid 62496) and window bounds
   without any pixel guessing: dashboard window "Vysor" at (16,33) 800x940 pt
   (`vysor_ax_windows.json`), and after mirror open, window "Pixel 10_Pro_XL"
   at (704,30) 394x963 pt (`vysor_ax_windows_after.json`).
3. **Verified mirror-directed action through the loop** — observe -> click
   (normalized 191,152; device-card play button, nonblank intent) -> re-observe:
   the "Pixel 10_Pro_XL" mirror window appeared and streams the live phone home
   screen. Shots: `shots/02..04_computer_use_observe.jpg` pre/post frames.
4. **Coordinate calibration (Vysor window -> phone screen)** — phone renders
   1080x2404 (`adb shell wm size`, mode 2 of the 1344x2992 panel, rotation 0).
   Mirror content rect measured against the AX window frame: points
   x 704..1098 (width 394), y 66..949 (height 883) — title bar ~36 pt, Vysor
   nav toolbar ~44 pt at the bottom (back/home/recents). Aspect check:
   394/883 = 0.446 vs phone 1080/2404 = 0.449 (<1% delta, no letterboxing at
   this window size). Mapping: `pt_x = 704 + px_x*(394/1080)`,
   `pt_y = 66 + px_y*(883/2404)`, then normalize by 999/(dim-1).
5. **Staleness failure reproduced (negative proof)** — the app-drawer drag was
   issued with a fresh capture lease but coordinates derived from the PREVIOUS
   run's frame. Between runs the desktop changed (Safari went fullscreen over
   the mirror; concurrent operator, see 6). The drag landed in Safari and only
   text-selected a local test page (`shots/04` pre = Safari fullscreen clean,
   `shots/05` post = selection swath). Benign: no control clicked, no state
   changed, no phone input. This is the canonical cross-frame-coordinate
   violation the skill reference now forbids.
6. **Concurrent-operator detection and hard stop** — an active Antigravity
   session (`agy --model gemini-3.6-flash-high`, pid 10787, ttys010 from the
   cockpit at 192.168.1.154, cwd = M10-D3 worktree, ~7.5% CPU sustained) shares
   this desktop; Safari-fullscreen flip at ~16:11 was not this lane's doing.
   All input synthesis on aiworker-02 halted at 20:12Z after the misfire
   diagnosis. No further actions issued.
7. **Phone untouched end-to-end** — before: `mCurrentFocus=NexusLauncher`;
   after all actions: `topResumedActivity=NexusLauncherActivity` (read-only
   `dumpsys` checks). Zero phone-side taps/swipes/keys landed; zero app,
   account, or settings mutations on the device.

## Explicit blocker (return condition)

The planned read-only phone flow (swipe up -> open Settings -> assert visible
state -> Vysor-toolbar Home) is NOT complete. Blocked on desktop ownership:
resume only when the cockpit confirms the aiworker-02 desktop is free (AGY
session on ttys010 closed or idle and no human screen-sharing driver), then
re-run with per-script preconditions (frontmost=Vysor + AX window re-check +
same-frame coordinate derivation).

## Artifacts

- `events.jsonl` — full action journal (tool calls, results, env_prep, notes)
- `shots/01..05_computer_use_observe.jpg` — desktop frames (see 3, 5)
- `vysor_ax_windows.json`, `vysor_ax_windows_after.json` — AX window bounds
- `driver/` — MCP stdio driver + step scripts (probe, surface, open-mirror,
  app-drawer)
- `STATE.md`, `heartbeat` — run state

No secrets inspected or captured; frames contain only test surfaces; device
serial masked per `phone-test-identities` labeling policy.
