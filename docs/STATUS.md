# Release Completion Status

Latest verification: September 16, 2026, macOS, Apple M2, Godot 4.7.2 and Python 3.12.3.

## Hand Lab update

Desktop launches now offer synthetic joint-based Hand Lab interaction, a practice circuit, quality presets and frame-interval telemetry. A double-click launcher explicitly disables OpenXR. Real OpenXR sessions retain the optical-hand source and do not show the desktop reactor field. See [Hand Lab](HAND_LAB.md).

Added animated plasma/Fresnel orb materials, GPU reactor/mote effects, native-resolution UI with adaptive desktop 3D scaling, long offline code samples and pinch-addressable transcript pages. Corrected desktop camera ownership, quick-click loss, hidden collision occlusion, stale hover after tracking loss and reversed cognition labels. Hidden code surfaces no longer render continuously; procedural sound buffers are cached and headless tests do not create audio playbacks.

Local rendered checks at 1440×900, Balanced (2× MSAA), full 3D scale and the 60 FPS cap recorded approximately 60 FPS and 16.7 ms p95 frame intervals, including the code/cognition/mission workspace. These are short desktop measurements, not headset or sustained thermal benchmarks.

| First-prototype criterion | Status | Evidence |
|---|---|---|
| Runs on desktop without headset | Complete | Milestone 0 and visual render |
| Move/look and spatial hover/select | Complete | Milestones 0–1 |
| 8–12 data-driven orbs with stable layout | Complete | Milestone 2 |
| Focus/dismiss/create/archive threads | Complete | Milestone 3, command test, backend integration |
| Readable transcript and streaming state | Complete | Milestone 3 and full-stack test |
| Offline fake backend drives important states | Complete | Transport and command/approval tests |
| Real local WebSocket backend | Complete | Socket handshake and full-stack test |
| Reconnect restores authoritative snapshot | Complete | Two-session reconnect test |
| Persistence, cancellation, error flow | Complete | Backend and transport tests |
| Tool approval blocks execution | Complete | Fake and real-backend integration tests; modal exposes separate hand-pinch Approve/Deny targets and blocks lower-priority surfaces |
| Claude provider streams normalized text | Implemented; credential-dependent | Official async SDK adapter constructs in test; a live API request was not made because no user key was supplied |
| OpenAI provider streams normalized text | Implemented; credential-dependent | Responses API adapter and installed SDK construct in tests; a live API request was not made because no user key was supplied |
| DeepSeek provider streams normalized text and tool calls | Implemented; credential-dependent | Chat-completions adapter with streamed text, tool-call accumulation, and tool history mapping covered by fake-client tests; a live API request was not made because no user key was supplied |
| OpenAI + Claude Council | Complete in code; credential-dependent | Both adapters run concurrently, cancellation is shared, labelled perspectives remain separate, and Cognition shows dual hosted egress; live calls require both user keys |
| Push-to-talk voice routes to focus | Implemented; hardware-dependent | Local asynchronous speech boundary and routing are tested with a process fixture; a real microphone/model was not exercised by automation |
| No client provider secret | Complete | Provider import/key lookup exists only in backend |
| Device-neutral orb interaction | Complete | `AgentOrb` consumes domain state and semantic events only |
| Hand-only OpenXR boundary exists | Complete in code; hardware acceptance pending | Real origin/camera startup, optical tracker filtering, joint-derived ray, pinch hysteresis, code scroll, palm controls, explicit approval, and bimanual transforms are implemented; headset ergonomics remain hardware-dependent |
| Quest 3/3S build path | Complete in project; workstation/hardware-dependent | ARM64 Meta OpenXR export preset, Android feature overrides, pinned vendor installer, ADB tunnel, doctor, and deploy commands are included |
| Agent direction without keyboard/voice | Complete | Four fixed quick intents are world-space pinch targets and are tested as the speech-unavailable fallback |
| Safe Jarvis telemetry tools | Complete | Clock and non-sensitive system status execute without approval or side effects; simulated note stays approval-gated |
| Vim-inspired floating code trace | Complete | World-space viewer extracts streaming fenced code, highlights it, and exposes semantic scroll/navigation actions |
| Holographic instrument visual pass | Complete | Procedural rings, ticks, status arcs, dark-glass panels, reticle, and floor grid render in the Mobile pipeline |
| Spatial cognition and temporal inspection | Complete | Content-blind causal constellation, bounded temporal black box, privacy route, palm summon control, and hand-addressable rewind/live/forward targets are automated |
| Ghost Future approval impact | Complete | Approval payload/schema and 3D route visualization are bounded, argument-free, and tested not to repeat sensitive note text |
| Holographic diff sculpture | Complete | Fenced diffs produce bounded red/green/context geometry attached to the Vim trace |
| Mission topology | Complete in code; hardware comfort pending | Palm-only toggle, content-blind links, explicit inference labelling, animated pulses, and 12-link Quest budget are automated |
| Privacy Veil | Complete in code; hardware privacy check pending | Palm-only conceal/restore, workspace lock, microphone stop boundary, and fail-closed view behavior are automated |
| Spatial audio cues | Complete in code; hardware loudness pending | Non-verbal WAVs are synthesized locally, placed in 3D, and tested without prompt content |
| Privacy-safe room anchor boundary | Complete in code | Session-only semantic transform registry rejects raw room mesh; Meta Scene API remains deliberately disabled |

Automated verification currently includes 28 Python tests (26 passed; two optional installed-provider-SDK checks skipped in the minimal environment) plus 19 Godot test scenes. `scripts/test_all.sh` runs the entire suite, including Council separation/failure cancellation, impact minimization, joint/pinch interpretation, quick intents, cognition privacy/history behavior, mission topology, Privacy Veil, procedural spatial audio, semantic anchors, code-viewer/diff geometry, fixture sockets, reconnect, and the real full-stack path. Hand Lab adds joint-based ray selection, buffered clicks, scrolling, two-hand movement/scale, tracking loss, privacy/approval gates, transcript pagination and adaptive-quality coverage.

## Rev 2: spatial dev cockpit

| Criterion | Status | Evidence |
|---|---|---|
| Paired LAN access with hashed device tokens | Complete in code; deployment-dependent | Pairing flow, expiry, one-time use, revocation, and TLS-required validation covered by backend tests |
| Isolated agent worktrees with apply/reject | Complete | Worktree lifecycle, diff parsing, commit, reject, path traversal, and audit tests |
| MCP host with stdio transport and policy mapping | Complete | Fixture MCP server tests: initialize, tools/list, tools/call, resources, config validation, unreachable-server handling |
| Provider tool-calling loop behind approvals | Complete in code; credential-dependent | Scripted-provider loop tests for safe, approved, denied, unknown, and cancelled tool calls |
| Protocol v2 (workspaces, diffs, files, catalog) | Complete | Schema update, server integration flow tests, v1 compatibility gating, client bridge reducers |
| Cockpit panels | Complete at simulator level | Workspace, diff review, file viewer, and daemon panels covered by `cockpit_panels_smoke`; hand-ergonomics pending hardware |
| Android dictation adapter boundary | Complete in code; plugin build user-gated | Adapter state machine tested with an injected bridge; Kotlin plugin source and build helper included |
| Portable Android XR export preset | Complete in project; toolchain-dependent | Vendor-neutral Khronos preset alongside the pinned Meta preset |

Automated verification for rev 2 currently includes 64 Python tests (62 passed; the same two optional provider-SDK checks skipped) plus 22 Godot test scenes, with `scripts/test_all.sh` refreshing Godot's class cache and running the complete original suite plus cockpit transport, cockpit panel, and Android dictation boundary coverage.

## Deliberate hardware/service gates

Three checks cannot be completed honestly without external state owned by the user:

1. A live hosted response requires the corresponding API key and sends prompt content to OpenAI or Anthropic; Council requires both and sends context to both.
2. Real desktop push-to-talk acceptance requires microphone permission and a downloaded local Whisper model; Quest dictation additionally requires building the optional Android plugin with the user's Android toolchain.
3. Hand tracking, passthrough comfort, spatial-audio loudness, Android signing, headset performance, and real MCP server processes require the user's OpenXR runtime, SDK setup, and physical Quest; no final workflow is intended to require controllers.
