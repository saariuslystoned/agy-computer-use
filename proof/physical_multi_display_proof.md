# Multi-Display Live Physical Proof Record

- **Date**: 2026-07-23
- **Target OS**: macOS Sonoma / Sequoia (Apple Silicon arm64)
- **Connected Displays**: 3 Active Monitors (Primary Retina, External 4K, Vertical Portrait)
- **Branch**: `codex/bobby-computer-use-v0-20260721t174022z-a9ab71173113`
- **Draft Pull Request**: [#1](https://github.com/saariuslystoned/agy-computer-use/pull/1)

---

## 1. Discovered Multi-Display Topology

| Display ID | Orientation / Type | Points | Scale | Physical Pixels | Global Origin | Status |
|---|---|---|---|---|---|---|
| **Display 1** | Primary Retina | `1728 × 1117` | `2x` | `3456 × 2234` | `(0, 0)` | **VERIFIED** (`804 KB`) |
| **Display 3** | External 4K Monitor | `1920 × 1080` | `2x` | `3840 × 2160` | `(0, -1080)` | **VERIFIED** (`854 KB`) |
| **Display 5** | Vertical / Portrait Monitor | `1440 × 2560` | `1x` | `1440 × 2560` | `(-1440, -1443)` | **VERIFIED** (`651 KB`) |

---

## 2. Multi-Display Perception Artifacts

- **Display 1 Screenshot**: `proof/multi_display_1.jpg` (`804,156 bytes`, `3456 × 2234 px`)
- **Display 3 Screenshot**: `proof/multi_display_3.jpg` (`854,148 bytes`, `3840 × 2160 px`)
- **Display 5 Screenshot**: `proof/multi_display_5.jpg` (`651,075 bytes`, `1440 × 2560 px`)
- **Full Topology Dump**: `proof/topology_multi_display.json`
- **Targeted Application AX Tree**: `proof/calculator_ax_tree.json`

---

## 3. Multi-Display CGEvent Input Dispatch Verification

- **Display 1 Move**: Grid `(500, 500)` -> Logical Point `(864, 558)` (`11.38 ms`)
- **Display 3 Move**: Grid `(500, 500)` -> Logical Point `(960, -540)` (`0.01 ms`)
- **Display 5 Move**: Grid `(500, 500)` -> Logical Point `(-720, -163)` (`0.01 ms`)

---

## 4. Codebase Integrity
- Codebase restored to 100% pristine state without uncommitted code modifications.
- All proof artifacts published additively to document live multi-monitor computer use capabilities.
