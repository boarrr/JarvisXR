# Spatial Agent XR 0.4 — Autonomous Supervision

Version 0.4 turns the prototype from a spatial chat surface into a hand-operated agent supervision environment.

## New in this release

- **Council mode:** explicit concurrent OpenAI + Claude comparison with separate labelled perspectives, shared cancellation, dual-egress disclosure, and no hidden judge.
- **Ghost Future:** approval gates show a content-blind 3D effect route, scope, side-effect class, reversibility, and external-system status before a hand confirms.
- **Diff Sculpture:** fenced diffs become bounded animated red/green/context geometry beside the Vim-inspired Code Trace.
- **Mission Map:** at most 12 live status paths connect explicit parent relationships and clearly labelled focused-agent correlations.
- **Privacy Veil:** one palm pinch conceals content-bearing holograms, locks other workspace actions, and stops active microphone capture; another restores the workspace. Background runs are explicitly not cancelled.
- **Spatial sonification:** short non-verbal WAV cues are synthesized in memory and emitted from relevant agent positions.
- **Safe anchor boundary:** surfaces publish session-only semantic transforms; raw room mesh and Meta Scene API remain disabled.
- **Leaner Quest payload:** tests and demo showcases are excluded from export while production XR features remain included.

## Verification

- 28 Python unit/integration tests passed.
- 18 Godot, WebSocket, reconnect, speech-boundary, and full-stack scenes passed.
- Godot 4.7.2 produced a 276 KB Quest resource pack containing hand tracking, cognition, mission topology, Ghost Future, diff sculpture, Privacy Veil, spatial audio, and semantic anchors.
- Protocol schema JSON, Godot scripts/scenes, provider failure cancellation, sensitive-argument minimization, and the offline/real-WebSocket paths were verified.

## External acceptance boundary

No API key, microphone, or headset was used. Before physical Quest testing:

1. Install Godot's matching export templates.
2. Run `./scripts/quest.sh setup` and `./scripts/quest.sh doctor`.
3. Connect a Quest 3/3S and run `./scripts/quest.sh deploy`.
4. Complete the hand-only checklist in `docs/QUEST_3S_SETUP.md`.

Live Council testing additionally requires both user-owned provider API keys and sends eligible context to both providers.
