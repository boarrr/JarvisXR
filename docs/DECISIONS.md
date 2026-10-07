# Architecture Decision Records

## ADR-001: Godot desktop-first client

- **Status:** Superseded by ADR-035
- **Context:** Spatial ergonomics must be tested before headset integration adds platform complexity.
- **Decision:** Build and keep a complete desktop simulation path in Godot.
- **Consequences:** Iteration needs no headset; device input must remain behind adapters.
- **Note:** The desktop runtime was removed once the OpenXR hand boundary matured.

## ADR-002: GDScript for client implementation

- **Status:** Accepted
- **Context:** The first client should stay close to Godot's scene and editor workflow.
- **Decision:** Implement client behavior in typed, readable GDScript.
- **Consequences:** The prototype has a small toolchain and no native extension requirement.

## ADR-003: Mobile renderer

- **Status:** Accepted
- **Context:** The future targets include standalone XR hardware with constrained rendering budgets.
- **Decision:** Use Godot's Mobile renderer from the first desktop build.
- **Consequences:** Early rendering choices follow a path suitable for later XR exports.

## ADR-004: Semantic InteractionSource abstraction

- **Status:** Accepted
- **Context:** Hand rays, pinches, direct touch, and optional gaze stabilization must drive the same application behavior; the earlier desktop simulation was retired.
- **Decision:** Translate hardware input behind interchangeable `InteractionSource` implementations.
- **Consequences:** Presentation objects stay device-neutral; adapters carry device-specific complexity.

## ADR-005: Backend owns agents and secrets

- **Status:** Accepted
- **Context:** Exported clients cannot safely contain provider credentials or authoritative tool policy.
- **Decision:** Keep agents, credentials, tools, permissions, and durable state in a separate backend.
- **Consequences:** The Godot client remains a replaceable presentation client.

## ADR-006: Versioned WebSocket event protocol

- **Status:** Accepted
- **Context:** Multiple agent threads will stream asynchronous updates.
- **Decision:** Use provider-neutral JSON envelopes with a protocol version over WebSocket.
- **Consequences:** Events can evolve explicitly, provider SDK objects cannot leak into the client, and both commands and events share one v1 envelope with a machine-readable JSON Schema.

## ADR-007: Fake backend as a supported mode

- **Status:** Accepted
- **Context:** Spatial UI work should not require credentials, a network, or a running provider.
- **Decision:** Preserve a fake/offline transport that implements the same transport boundary.
- **Consequences:** Important UI states can be developed deterministically and offline.

## ADR-008: Hand-only OpenXR abstraction boundary

- **Status:** Accepted
- **Context:** Target devices span Meta and Android XR families.
- **Decision:** Use OpenXR as the headset boundary, target hand-ray/direct-touch and pinch interaction, and isolate vendor extensions. Controllers are not part of the final required workflow.
- **Consequences:** The simulator was retired; `OpenXRInteractionSource` is the sole interaction source. Android initializes a real origin/camera and polls standard hand trackers; hardware logic remains isolated in `XRRuntime` and `OpenXRInteractionSource`.

## ADR-009: Stable spatial slots

- **Status:** Accepted
- **Context:** Constant orb reordering would damage spatial memory and orientation.
- **Decision:** Future thread layout will assign deterministic stable slots.
- **Consequences:** Layout code must preserve identity-to-slot mappings as threads change.

## ADR-010: Defer a custom engine

- **Status:** Accepted
- **Context:** No measured engine limitation exists at prototype time.
- **Decision:** Stay on Godot until profiling demonstrates a concrete platform or performance blocker.
- **Consequences:** Work remains focused on interaction design instead of rendering infrastructure.

## ADR-011: A reducer isolates backend events from presentation state

- **Status:** Accepted
- **Context:** Fake and WebSocket transports must produce identical client behavior without gaining direct ownership of scene or presentation state.
- **Decision:** All transports emit normalized `BackendEvent` envelopes; `BackendBridge` alone reduces them into `AppState`.
- **Consequences:** The fake implementation is replaceable, UI scenes remain transport-neutral, and real protocol parsing can be added without rewriting orb or panel behavior.

## ADR-012: SQLite is the local source of durable conversation state

- **Status:** Accepted
- **Context:** The prototype needs restart-safe threads without introducing a remote database or account system.
- **Decision:** Store thread metadata and messages in backend-owned SQLite using WAL mode.
- **Consequences:** Setup stays local and deterministic; sensitive conversation text is not encrypted by the application and must be protected at the filesystem/volume level.

## ADR-013: Backend policy is authoritative for tools

- **Status:** Accepted
- **Context:** A presentation client cannot safely decide whether an agent-requested side effect is allowed.
- **Decision:** Keep an allowlisted tool registry and permission classification in the backend. Sensitive and side-effecting classes require an `approval.respond` command before the handler starts.
- **Consequences:** The approval panel is only a policy view; there is no arbitrary shell tool, and the initial write tool is deliberately simulated.

## ADR-014: Desktop speech uses an optional local process adapter

- **Status:** Accepted
- **Context:** Voice is useful, but uploading raw microphone audio conflicts with the sensitive-data requirement and couples the client to a speech vendor.
- **Decision:** Capture audio in Godot and invoke local `whisper.cpp` asynchronously behind `SpeechService`; keep the feature disabled until a model is configured.
- **Consequences:** Audio remains local and temporary by default. Desktop users install a model themselves, exported mobile/XR builds will need another adapter, and only finalized text enters the backend protocol.

## ADR-015: Reconnect creates a new session and reconciles a snapshot

- **Status:** Accepted
- **Context:** A dropped socket invalidates session-scoped runs and may leave local presentation stale.
- **Decision:** Retry with bounded exponential backoff, perform a new handshake, then request an authoritative thread snapshot.
- **Consequences:** Durable state recovers automatically; disconnected runs are cancelled server-side rather than silently resumed, and pending approvals do not survive the expired session.

## ADR-016: Original holographic instrument language

- **Status:** Accepted
- **Context:** A flat dashboard does not communicate spatial agent state clearly in mixed reality.
- **Decision:** Use dark optical glass, restrained cyan emission, concentric instrument rings, calibrated ticks, depth-separated panels, and amber/red only for attention and risk. Avoid film branding and literal screen replicas.
- **Consequences:** The workspace evokes a high-information AR instrument system while remaining original, legible, and feasible on the Mobile renderer.

## ADR-017: Vim-inspired code trace is a read-only spatial instrument

- **Status:** Accepted
- **Context:** Users need a glanceable way to inspect code emitted by working agents without turning the XR workspace into a full desktop IDE.
- **Decision:** Extract the latest streamed fenced code into a floating `CodeEdit` with line numbers, syntax highlighting, minimap, normal-mode status line, and semantic navigation actions.
- **Consequences:** Desktop shortcuts were retired with the desktop runtime; the XR surface scrolls with pinch-drag and uses two-hand midpoint, spread, and yaw to reposition/scale/rotate without changing code extraction or thread state.

## ADR-018: Hosted providers remain backend-selectable

- **Status:** Accepted
- **Context:** The workspace should work with OpenAI, Claude, or an explicit comparison of both without provider code entering the XR client.
- **Decision:** Select `fake`, `openai`, `claude`, or the explicit `council` composition at backend startup; normalize OpenAI Responses and Anthropic Messages streams into the same text delta contract.
- **Consequences:** Switching providers is an `.env` change and server restart. Keys and SDK objects never enter Godot, but prompts leave the local machine in either hosted mode.

## ADR-019: Quest development uses verified external vendor binaries

- **Status:** Accepted
- **Context:** Meta passthrough/export integration needs Godot OpenXR Vendors, whose compiled multi-platform addon is much larger than the application source.
- **Decision:** Pin version `5.1.0-stable` and its published SHA-256 in a setup helper instead of committing the binary addon.
- **Consequences:** Project archives stay small and dependency origin is explicit; first-time Quest setup requires network access and a checksum match.

## ADR-020: Hand tracking rejects controller-derived skeletons

- **Status:** Accepted
- **Context:** OpenXR runtimes may infer hand joints from a held controller, which would accidentally make controller use part of the apparent acceptance path.
- **Decision:** Accept only trackers with real tracking data whose source is neither controller-derived nor not-tracked, and require both valid and tracked joint-position flags.
- **Consequences:** The product honors the hand-only constraint. Temporary optical occlusion clears selection instead of reusing stale or inferred data.

## ADR-021: Fixed quick intents preserve a no-keyboard headset path

- **Status:** Accepted
- **Context:** The desktop-local `whisper-cli` process cannot run unchanged inside an Android APK, while a headset user still needs to direct an agent without physical input devices.
- **Decision:** Fall back from Ask/Voice to a spatial panel of four visible exact prompts: Continue, Summarize, Explain Code, and Privacy Review.
- **Consequences:** Core agent direction remains hand-only and predictable without uploading audio. Free-form mobile dictation remains a future replaceable speech adapter.

## ADR-022: Spatial cognition telemetry is content-blind

- **Status:** Accepted
- **Context:** A causal XR visualization can make agent activity intelligible, but copying prompt text, model deltas, code, or tool arguments into a second telemetry surface would create an unnecessary sensitive-data exposure.
- **Decision:** Render only normalized event class, sanitized state label, timestamp, thread ID, provider route, and risk class. Emit content-free command notifications from `BackendBridge`, aggregate token deltas into pulse counts, and cap the in-memory temporal black box at 32 records.
- **Consequences:** Users can rewind visible system behavior and see hosted egress or consent boundaries without the interface pretending to expose private chain-of-thought or retaining a duplicate transcript. Detailed content remains in the dedicated thread/code surfaces under their existing privacy policy.

## ADR-023: Council preserves independent hosted perspectives

- **Status:** Accepted
- **Context:** A second model can expose disagreement, but an opaque automatic judge would introduce false authority and another undocumented model decision.
- **Decision:** Council concurrently calls the configured OpenAI and Claude adapters with the same eligible context, then labels both replies separately and adds only a deterministic disclosure note.
- **Consequences:** Users see disagreement directly and remain the decision-maker. Both keys are required, both providers receive context, latency waits for both completions, and API usage can roughly double.

## ADR-024: Approval previews are argument-free Ghost Futures

- **Status:** Accepted
- **Context:** Consent improves when users can preview an action's effects, but repeating tool arguments on another surface creates additional sensitive-data exposure.
- **Decision:** Tool definitions supply bounded route, scope, side-effect, reversibility, and external-system metadata. Approval events never derive this visualization from arguments.
- **Consequences:** The panel explains the class of future state without copying note text or credentials. Metadata must remain accurate and is part of tool review.

## ADR-025: Mission topology distinguishes fact from inference

- **Status:** Accepted
- **Context:** Spatial links are compelling but can falsely imply orchestration relationships that do not exist.
- **Decision:** Draw explicit parent edges plus focused-to-active correlations, cap the field at 12 links, and label inferred links as correlations rather than task authority.
- **Consequences:** The swarm is glanceable and mobile-friendly without claiming a scheduler or dependency graph the backend does not own.

## ADR-026: Privacy Veil is concealment, not cancellation

- **Status:** Accepted
- **Context:** Sensitive AR content needs a fast shoulder-surfing defense that remains reachable with hands alone.
- **Decision:** A palm action hides content-bearing surfaces, locks other workspace actions, stops active microphone capture, and leaves a content-free disclosure that background runs continue.
- **Consequences:** Concealment is immediate and fail closed. It does not erase SQLite, revoke provider requests, or guarantee physical privacy; documentation and UI state this explicitly.

## ADR-027: Spatial cues are synthesized from semantic state

- **Status:** Accepted
- **Context:** Hand-only XR lacks controller haptics, while spoken cues could leak content and asset packs add unnecessary distribution weight.
- **Decision:** Generate short non-verbal WAV cues in memory from fixed semantic tone definitions and play them at the relevant orb position.
- **Consequences:** State can be heard without prompt-derived audio. Cues are independently disableable and need physical loudness/comfort validation.

## ADR-028: Room anchors are semantic and session-only

- **Status:** Accepted
- **Context:** Stable placement is useful, but raw room meshes and persistent home geometry create a disproportionate privacy burden.
- **Decision:** Store at most 16 allowlisted semantic transforms in memory, reject raw-scene-mesh classifications, and keep vendor Scene API disabled until a reviewed adapter exists.
- **Consequences:** Current panels can publish safe placement anchors and a future Meta adapter has a narrow contract. No room scan or persistent spatial map is claimed.

## ADR-029: Headset is a terminal; the daemon owns the workspace

- **Status:** Accepted (rev 2)
- **Context:** Standing alone on a headset fights Horizon OS background suspension, thermals, and the developer toolchain, while the code and MCP servers live on the developer machine.
- **Decision:** Keep agents, repositories, credentials, and durable state in a companion daemon; the headset stores only cached review state.
- **Consequences:** Agent work requires a reachable daemon (USB, LAN, or tunnel), and the client remains a replaceable presentation surface.

## ADR-030: Agent changes use one git worktree per run

- **Status:** Accepted (rev 2)
- **Context:** Agents that write code need isolation from the user's checkout and a cheap undo path.
- **Decision:** Create a `git worktree` on a `spatial/agent-<run_id>` branch per run; apply commits on that branch, reject deletes it.
- **Consequences:** The user's checkout is never touched by an agent, concurrent runs cannot collide, and diffs become the natural review payload.

## ADR-031: Reviews show code; telemetry stays content-blind

- **Status:** Accepted (rev 2), revises ADR-024 for code context
- **Context:** Approving code changes requires seeing them, while the cognition layer must not become a second copy of sensitive content.
- **Decision:** Diff review, file browsing, and tool arguments for review surfaces may render code and diffs. Approval impact previews and cognition telemetry remain argument-free and content-blind.
- **Consequences:** Consent screens for code are informative; the telemetry boundary still omits prompt text, code, and arguments.

## ADR-032: MCP permissions derive from policy, annotations, and approval

- **Status:** Accepted (rev 2)
- **Context:** MCP servers are arbitrary third-party code with heterogeneous safety claims.
- **Decision:** Resolve each tool to an existing permission level from explicit policy first, then annotations, defaulting to approval-required; keep side effects behind the spatial approval gate.
- **Consequences:** Remote tool inventories cannot grant themselves safe-read status, and misconfigured policy fails closed.

## ADR-033: LAN access requires pairing, TLS, and explicit configuration

- **Status:** Accepted (rev 2)
- **Context:** The prototype trusted loopback only; a wireless headset needs a larger reach without opening an unauthenticated service.
- **Decision:** Keep loopback open for development; require device pairing, hashed tokens, TLS, and an explicit `SPATIAL_AGENT_AUTH_REQUIRED=1` for any non-loopback bind, validated at startup.
- **Consequences:** Wireless use is a deliberate deployment step rather than a default, and the daemon cannot silently expose itself.

## ADR-034: Android dictation is a replaceable platform adapter

- **Status:** Accepted (rev 2)
- **Context:** The desktop whisper.cpp process cannot run inside an APK, and the desktop runtime has been retired, but headset users still need free-form input.
- **Decision:** Add an `AndroidSpeechService` adapter over an optional `AndroidDictation` plugin wrapping the platform recognizer; keep whisper.cpp as a headless-test adapter and quick intents as the fallback.
- **Consequences:** Only finalized text crosses the protocol; the whisper adapter now runs only in headless tests, the user-facing client degrades to hand-only intents without the plugin, and plugin builds remain a user-toolchain step.

## ADR-035: XR-only client with headless tests

- **Status:** Accepted
- **Context:** The desktop simulator was retired once the OpenXR hand boundary was mature enough to carry interaction work.
- **Decision:** The Godot client targets OpenXR hand-tracking only. Device-free CI feeds simulated joint samples through `OpenXRInteractionSource.submit_joint_sample`, so the real interaction pipeline is exercised without a headset.
- **Consequences:** There is no desktop product surface and hand ergonomics are verified on device, while automated tests remain headless and require no hardware.
