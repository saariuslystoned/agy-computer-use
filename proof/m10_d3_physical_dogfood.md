# Computer Use M10/D3 Physical Dogfood Verification Proof

- **Run ID**: `agy-cu-m10-d3-ax-pointer-01-20260723`
- **Staged Source Candidate HEAD**: `e1b06f1adb2186ef6d47c4ee2d93c45d864f22f1` (CI Push [#30035943899](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30035943899), CI PR [#30035946527](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30035946527))
- **Evidence Bundle Commit**: `6e61bbc9be4ec3c271891d4e2fb6fb8b4226f30e`
- **Metadata Follow-up Commit**: `18a4a7d6eecbeebf0a7eec1ca5a2f5dd831969a5`
- **Note**: The final exact head SHA and GitHub Actions CI run IDs live in the terminal `m10_d3_final_ready` event and PR status after this correction commit.

- **Worktree Path**: `/Users/aiworker02/Developer/worktrees/agy-computer-use-m10-d3-20260723`
- **Host Machine**: `aiworker-02.local`

---

## 1. Runtime & Host TCC Truth

- **Host Process Identity**: `ComputerUseHost` (bundle `com.saariuslystoned.agy-computer-use.host`)
- **Screen Recording TCC Permission**: `granted`
- **Accessibility TCC Permission**: `accessibility_trusted: true`, `ax_tree_inspection_available: true`
- **Input Mutation State**: `input_mutation_state: "enabled"`
- **Active Display Topology**: Display ID `7` (1920x1080 points, scale factor 2.0, pixel dimensions 3840x2160)
- **Active Topology Version**: `top-sha256-c1ddd4bae082c11d19d8b87a29f177b61f27db9ba82aad8a600545a954e0deff`

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
- Returned `node_count: 500`, `max_depth_reached: 10`, `truncated: true`.
- Verified synthetic secure text field value was not returned and was redacted to `[REDACTED]`. Saved to `proof/m10_ax_tree_redacted.json`.

### Loop 3: Bounded Pointer Move / Hover (`computer_use_move`)
- Dispatched `computer_use_move` to normalized coordinates `x: 354, y: 384` over `#hover-box` using capture `cap-94056249-5C2D-461D-ACCE-7FFCC496D135` (Action ID: `act-c9faf899-3188-4aba-95f6-a3b3cfeafb86`).
- Verified hover movement and subsequent observation capture `cap-19920353-A8DD-4C6D-9C30-96D33D49DEEA`.

### Loop 4: Anchored Scroll (`computer_use_scroll`)
- Dispatched `computer_use_scroll` at normalized `x: 359, y: 588` with `delta_y: -100` followed by a corrective second `computer_use_scroll` call with `delta_y: 50` to properly reach bottom marker.

### Loop 5: Drag Synthesis (`computer_use_drag`)
- Dispatched `computer_use_drag` on range slider `#slider` from `start_x: 286, start_y: 787` to `end_x: 432, end_y: 787` with `button: "left"` using capture `cap-7D3A4D31-F372-47A7-9AE1-393E9D600F8D` (Action ID: `act-f878e321-8354-4aaf-9231-3aafbfed16c4`).
- Verified slider updated value to `SLIDER_VALUE_100` in post-action observation capture `cap-05772A4D-83E4-4BE6-8DCD-A3F33FA964CF` (`proof/m10_proof_after.jpg`).

### Loop 6: Lease Replay Rejection
- Replayed consumed capture ID `cap-7D3A4D31-F372-47A7-9AE1-393E9D600F8D` in `computer_use_move`.
- Verified fail-closed `STALE_CAPTURE` error response against active capture `cap-6FC8AC70-F1FA-4454-AD62-AA53D44B0A6B`.

### Loop 7: Post-Release Pointer Usability Check
- Dispatched post-drag move to `x: 500, y: 500` using capture `cap-A249A651-613B-4F90-9A39-80AF707F74D4` (Action ID: `act-3ae0c77a-cf15-4460-a9e6-19a965ca4b87`).
- Verified pointer remains responsive and mouse button released.

### Loop 8: Representative Installed-Skill End-to-End Video Loop
- **Topology Version**: `top-sha256-c1ddd4bae082c11d19d8b87a29f177b61f27db9ba82aad8a600545a954e0deff`
- **Initial Clean Fixture Observe**: `cap-D849497E-1364-4F98-9FFC-F5CAFDE99A18`
- **Move to Hover Target**: Action ID `act-bf503338-eef9-4b64-9093-166026ff8410` (`x: 110, y: 368`)
- **Observe Hover Active**: `cap-5A686209-4652-443C-B89A-C2DB37B3F0A4` (Visually verified `HOVER_STATE_ACTIVE`)
- **Bounded Scroll Target Box**: Action ID `act-7177d665-70d0-4c18-bf9f-ca0d9526445d` (`x: 110, y: 560`, `delta_y: 100`)
- **Observe Scroll Result**: `cap-DC9890AB-3FAA-444B-A4C9-75588574EF16` (Visually verified `SCROLL_BOTTOM_MARKER_END`)
- **Bounded Left-Button Drag Slider**: Action ID `act-8292d3ab-a936-4c85-9b6d-d3fbd01f795f` (`start_x: 36, start_y: 742` to `end_x: 186, end_y: 742`)
- **Observe Drag Result**: `cap-665470C1-05AD-4617-B6EB-C8A693F96F0F` (Visually verified `SLIDER_VALUE_100`)
- **Move Pointer Neutral**: Action ID `act-6ee3806e-40a1-4252-b9ec-67cdf54cef79` (`x: 600, y: 120`)
- **Final Observation**: `cap-C607ADCA-8836-4C07-94D2-01219786D101`
- **Final Visible Fixture State**: No selection overlay, `HOVER_IDLE_DEFAULT`, `SCROLL_BOTTOM_MARKER_END`, `SLIDER_VALUE_100`, pointer resting on neutral background.

---

## 3. Physical Evidence Artifacts

- **Before Frame (`proof/m10_proof_before.jpg`)**:
  - Image payload from observation capture `cap-7D3A4D31-F372-47A7-9AE1-393E9D600F8D`.
  - Size: `739,484` bytes, SHA-256: `b9b25909474fed2a8c747d1de2c5ef4dcf959648c13ce842764150bed7e08357`, Dimensions: `3840x2160`.
- **After Frame (`proof/m10_proof_after.jpg`)**:
  - Image payload from post-drag observation capture `cap-05772A4D-83E4-4BE6-8DCD-A3F33FA964CF` showing `SLIDER_VALUE_100`.
  - Size: `737,910` bytes, SHA-256: `ba0d7a8edbdf07cc40dcb7242b6cd360ce41d535a4702a3674d3a79f6194c9c5`, Dimensions: `3840x2160`.
- **Hover Active Screenshot (`proof/m10_hover_active.jpg`)**:
  - Screenshot of active hover state from capture `cap-DF325D38-5568-4186-9D8A-760E303F2C12` showing `HOVER_STATE_ACTIVE`.
  - Size: `152,047` bytes, SHA-256: `a6bf6ddab9d46430f7f6ad40a4f6f7af706028bf6624ac854c658f5b1ee3256b`, Dimensions: `3840x2160`.
- **Redacted AX Tree Subtree (`proof/m10_ax_tree_redacted.json`)**:
  - Extracted accessibility tree subtree for `com.apple.Safari` demonstrating `[REDACTED]` token output on secure text field `AXTextField` / `AXSecureTextField`.
- **Raw Controller Video Recording (`/Users/aiworker02/Desktop/Screen Recording 2026-07-23 at 4.15.18 PM.mov`)**:
  - Size: `10,395,349` bytes, Duration: `138.525` seconds, 3840x2160, 60 fps, 1 H.264 video stream, no audio. Preserved on Desktop per controller authority.
- **Transcoded End-to-End Proof Video (`proof/m10_d3_end_to_end.mp4`)**:
  - Transcoded at 10x speed with STARTPTS subtraction, 1920x1080, 30 fps, H.264/yuv420p, faststart, no audio.
  - Size: `310,107` bytes, Duration: `13.866667` seconds (within 10.0–14.5s requirement), SHA-256: `7773d1c75b2bb76e2c50f00570ebd86bab5369b132cf8c68ebb7dec1aea35869`.
