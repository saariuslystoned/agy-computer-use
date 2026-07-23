# Computer Use M9 Physical Dogfood Verification Proof

- **Run ID**: `m9-g36-media-docs-03` (Local machine run packet: `agy-cu-m9-media-docs-03-20260723`)
- **Prior Run ID**: `m9-g36-9ce36a-dogfood-02` (Local machine run packet: `agy-cu-m9-dogfood-02-20260723`)
- **Exact Source & Control-Plane HEAD**: `f205d85f29d5e7daa9bf4f69f9fa17a70eadd6cb`
- **Validated CI Runs**: GitHub Actions Runs [#30029581787](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30029581787) and [#30029585502](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30029585502) (both green on exact head `f205d85`)
- **Worktree Path**: `/Users/aiworker02/Developer/worktrees/agy-computer-use-m9-handoff`
- **Host Machine**: `aiworker-02.local`

---

## 1. Runtime & Host TCC Truth

- **Daemon Principal Registration**: `com.saariuslystoned.agy-computer-use.host` (Daemon PID `8557`, Native PID `8593`)
- **Screen Recording TCC Permission**: `granted`
- **Input Mutation State**: `enabled` (`accessibility_trusted`: `true`)
- **AX Tree Inspection**: `disabled` / `unavailable` (by design for M9 bounded input slice)

### Staged Bundle Preservation Metrics
- **Bundle Inode**: `1664439` (preserved without restaging)
- **Executable Inode**: `1664447` (preserved without restaging)
- **Executable mtime**: `2026-07-23T12:45:18-04:00` (`1784825118.4656406`)
- **Executable SHA-256**: `4fe024f63248f65fc375d4549e5746cb19dba8baf1a810a21c91def03676b457`
- **Executable CDHash**: `113930837f41afc9163e225eb1d9a815b0cdcd6e`

### Precise Provenance Boundary
Source code, lifecycle controller (`bin/host-lifecycle-core.mjs`), and TypeScript MCP server (`mcp/computer-use-mcp`) are at exact commit `f205d85`. The running native host binary is the deliberately preserved staged bundle (`mtime: 2026-07-23T12:45:18-04:00`), which was not rebuilt or restaged after later `f205d85` source fixes in order to maintain active OS TCC authorization without invalidating bundle identity. Live physical perception and input synthesis are proven on this running host; native Swift source deltas between build time and `f205d85` are verified via green CI runs `30029581787` and `30029585502`.

---

## 2. Antigravity Skill & MCP Interaction Loops

### Loop 1: Initial Focus & Typing (`M9-F205-7QK2-ACK`)
1. `computer_use_status` -> `connected: true`, `tcc_permission_state: "granted"`, `input_mutation_state: "enabled"`
2. `computer_use_observe` -> Frame captured (`display_id: 1`)
3. `computer_use_click` -> Focus target TextEdit document
4. `computer_use_observe` -> Verification frame captured
5. `computer_use_type` -> Typed text `M9-F205-7QK2-ACK`
6. `computer_use_observe` -> Confirmed visible token `M9-F205-7QK2-ACK`
7. `computer_use_shortcut` -> Dispatched `["cmd", "tab"]`
8. `computer_use_observe` -> Final state verified

### Loop 2: Verification Token & Media Capture (`M9-F205-PROOF-2`)
1. `computer_use_observe` -> `capture_id`: `cap-DF8EAAE6-024B-4A21-916A-DE370E1E365F` (SHA-256: `6a016e6827a81098ca26e644957d777a659b67cbf52b99af4a8d55edaa4be326`)
2. `computer_use_observe` -> `capture_id`: `cap-F1B58F0C-9EB9-4887-9505-8B58CD2167D0` (focused frame)
3. `computer_use_click` -> `action_id`: `act-d0baad92-0979-4389-a03d-eafffb22ffd0` (x=275, y=280)
4. `computer_use_observe` -> `capture_id`: `cap-750E44D9-AE56-4F1E-8CB9-8758517DFE9A`
5. `computer_use_type` -> `action_id`: `act-f728d6d8-f7ef-40a8-bcc0-dfb1748402b8` (typed `M9-F205-PROOF-2`)
6. `computer_use_observe` -> `capture_id`: `cap-FC6CE571-8C34-477D-8287-83CF990F122A` (SHA-256: `1a93ead080e0eddc77ab5bcde12a93a39d56987da1a5783a73eaca219cc9d1fa`)
7. `computer_use_observe` -> `capture_id`: `cap-560DF535-2D9B-4D2D-B5A7-5A29BE4AB35E` (SHA-256: `1f1ca6926052d94a4018d0f53a5bd020a3678d4b3a229d929228a3f1a518e19a`)

---

## 3. Media Artifact Proof & Hashes

- **Before Frame (`proof/m9_proof2_before.jpg`)**:
  - Size: `1,715,291` bytes
  - Resolution: `3456 x 2234`
  - SHA-256: `6a016e6827a81098ca26e644957d777a659b67cbf52b99af4a8d55edaa4be326`
- **After Frame (`proof/m9_proof2_after.jpg`)**:
  - Size: `1,191,996` bytes
  - Resolution: `3456 x 2234`
  - SHA-256: `1f1ca6926052d94a4018d0f53a5bd020a3678d4b3a229d929228a3f1a518e19a`
  - Visible Token: `M9-F205-PROOF-2`
- **Video Recording (`proof/m9_proof2_recording.mp4`)**:
  - Size: `2,188,116` bytes
  - Duration: `10.0` seconds (no audio)
  - Resolution: `3456 x 2234`
  - Codec: H.264 (`avc1`)
  - SHA-256: `a1a095e240f4422380a04468bb4615cbe0dbc2d14754a6a2fc51829732777105`

---

## 4. Multi-Display Physical Proof (By Reference)

The committed multi-display physical perception and input dispatch proof is accepted and incorporated by reference from `proof/physical_multi_display_proof.md` and associated visual evidence (`multi_display_1.jpg`, `multi_display_3.jpg`, `multi_display_5.jpg`). This single-display physical dogfood run (`m9-g36-media-docs-03`) verifies the single-display vertical slice on Display 1 without re-running or invalidating the prior 3-display campaign.
