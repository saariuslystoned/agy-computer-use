# Observe-One-Action-Observe Loop Operational Guide

## Core Protocol Rules
1. Call `computer_use_observe` to capture visual desktop snapshot and topology token.
2. Store returned `capture_id` and `topology_version`.
3. Perform exactly ONE input action using that `capture_id`.
4. Receive fresh `post_action_observation` inside action response payload.
5. Reuse post-action `capture_id` for subsequent actions or issue explicit `computer_use_observe`.
