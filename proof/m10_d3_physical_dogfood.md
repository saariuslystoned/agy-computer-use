# Computer Use M10/D3 Physical Dogfood Verification Proof

- **Run ID**: `agy-cu-m10-d3-ax-pointer-01-20260723`
- **Exact Source & Control-Plane HEAD**: `e1b06f1adb2186ef6d47c4ee2d93c45d864f22f1`
- **Validated CI Runs**: GitHub Actions Runs [#30035943899](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30035943899) (push) and [#30035946527](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30035946527) (PR)
- **Worktree Path**: `/Users/aiworker02/Developer/worktrees/agy-computer-use-m10-d3-20260723`
- **Host Machine**: `aiworker-02.local`

---

## 1. Runtime & Host TCC Truth

- **Host Process Identity**: `ComputerUseHost` (bundle `com.saariuslystoned.agy-computer-use.host`)
- **Screen Recording TCC Permission**: `granted`
- **Accessibility TCC Permission**: `accessibility_trusted: true`, `ax_tree_inspection_available: true`
- **Input Mutation State**: `input_mutation_state: "enabled"`
- **Active Display Topology**: Display ID `7` (1920x1080 points, scale factor 2.0, pixel dimensions 3840x2160)

### Staged App Identity Verification (Unchanged from TCC Gate)
- **Executable Path**: `apps/computer-use-host/.build/staged/ComputerUseHost.app/Contents/MacOS/ComputerUseHost`
- **Executable Inode**: `1691158`
- **Executable mtime**: `Jul 23 15:05:10 2026`
- **Executable SHA-256**: `f578232eca22be0faf7e13c202b6c447d030025791e09124e7ccf6db3b05f737`
- **Executable CDHash**: `9d716d693a848ccf9cfba22882f73d8e071b7670`
- **Bundle Identifier**: `com.saariuslystoned.agy-computer-use.host`

---

## 2. Antigravity Installed Skill Interaction Loops

### Loop 1: Status & Connectivity (`computer_use_status`)
- Returned `connected: true`, `tcc_permission_state: "granted"`, `accessibility_trusted: true`, `ax_tree_inspection_available: true`, `input_mutation_state: "enabled"`, primary display 7 topology.

### Loop 2: AX Tree Perception (`computer_use_ax_tree`)
- Targeted Safari (`app_id: "com.apple.Safari"`).
- Returned 257 total nodes, max depth 5.
- Verified secret password value (`SYNTHETIC_M10_SECRET_PASS_99`) in `AXSecureTextField` was redacted to `<REDACTED_SECURE_TEXT>`. Saved to `proof/m10_ax_tree_redacted.json`.

### Loop 3: Bounded Pointer Move / Hover (`computer_use_move`)
- Dispatched `computer_use_move` to normalized coordinates `x: 354, y: 384` over `#hover-box`.
- Verified hover state interaction without clicking.

### Loop 4: Anchored Scroll (`computer_use_scroll`)
- Dispatched `computer_use_scroll` at normalized `x: 359, y: 588` with `delta_y: -100` and `delta_y: 50`.
- Verified scroll region movement in fixture target.

### Loop 5: Drag Synthesis (`computer_use_drag`)
- Dispatched `computer_use_drag` on range slider `#slider` from `start_x: 286, start_y: 787` to `end_x: 432, end_y: 787` with `button: "left"`.
- Verified slider updated value to `SLIDER_VALUE_100` in post-action observation screenshot `proof/m10_proof_after.jpg`.

### Loop 6: Lease Replay Rejection
- Replayed previously consumed capture ID in `computer_use_move`.
- Verified fail-closed `STALE_CAPTURE` error response.

### Loop 7: Post-Release Pointer Usability Check
- Dispatched post-drag move to `x: 500, y: 500`.
- Verified pointer remains responsive and mouse button released.

---

## 3. Physical Evidence Artifacts

- **Before Frame (`proof/m10_proof_before.jpg`)**:
  - Image payload from initial observation capture.
  - Size: `985,980` bytes (3840x2160 resolution).
- **After Frame (`proof/m10_proof_after.jpg`)**:
  - Image payload from post-drag observation capture showing `SLIDER_VALUE_100`.
  - Size: `983,880` bytes (3840x2160 resolution).
- **Redacted AX Tree (`proof/m10_ax_tree_redacted.json`)**:
  - Full redacted accessibility tree output for `com.apple.Safari`.
- **Video Recording Evidence Status**:
  - Background recording attempts via `ffmpeg`/AVFoundation and `screencapture` subshells encountered 0-byte output / TCC subshell permission denial. Documented as proof-apparatus failure event per instructions; all product MCP loops and visual screenshots were fully executed and verified.
