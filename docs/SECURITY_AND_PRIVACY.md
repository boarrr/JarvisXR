# Security and Privacy

This is a local prototype, not a hardened multi-user service. Use the following boundaries deliberately when content is sensitive.

## Safest operating mode

Keep `backend_mode="fake"` and `speech_enabled=false`. In this mode no provider, backend, microphone, or network connection is used.

## Local backend mode

- The server binds to `127.0.0.1` by default. Do not bind it to a LAN or public interface without authentication, TLS termination, origin policy, and deployment-grade rate controls.
- Conversations are stored as plaintext in the configured SQLite database. Put that file on an appropriately protected volume and remove it according to your retention requirements.
- Structured logs include IDs, event types, timing, provider name, and error class. Prompt and response bodies are intentionally omitted.
- Packet-size and command-rate limits reduce accidental abuse; they are not a replacement for authentication.

## Hosted provider modes

- `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are read only by the backend process. They are not stored in Godot settings, SQLite, logs, or the WebSocket protocol.
- Prompt text and relevant conversation context are sent to OpenAI when `SPATIAL_AGENT_PROVIDER=openai` or Anthropic when `SPATIAL_AGENT_PROVIDER=claude`. Do not enable a hosted mode for content that policy or consent does not permit sending to that service.
- `SPATIAL_AGENT_PROVIDER=council` sends the same eligible context to both OpenAI and Anthropic and can roughly double API/token cost. It is never selected automatically. The client labels this **Dual Hosted Egress**, and the response preserves separate perspectives without a hidden judge.
- `backend/.env` is ignored by Git and parsed as literal assignments without shell expansion. Process environment variables take precedence.
- The prototype has no user authentication, tenancy isolation, billing controls, or remote deployment hardening.

## Local speech

- Voice is disabled by default.
- When enabled, Godot records to a muted capture bus and runs a local `whisper-cli` process. Raw audio is never included in the client/backend protocol.
- A temporary WAV is created under `user://spatial_agent_voice` and removed after transcription by default. `speech_retain_recordings=true` is an explicit opt-in.
- The transcript follows the same route as typed text. It remains local in fake mode but is sent in prompts when a hosted provider is enabled.
- `whisper-cli` is a desktop adapter and is not exported as a working Quest binary. The Quest UI falls back to fixed, visible hand-only quick intents rather than silently uploading microphone audio.

## Tools and approvals

- Only registered, typed tools can be called. There is no generic shell or filesystem tool.
- `SENSITIVE_READ`, write, external, and destructive permission classes require approval. `FORBIDDEN` tools cannot execute.
- `system.clock` and `system.diagnostics` expose only non-sensitive service telemetry and declare `external_side_effect=false`. The included `demo.write_note` handler returns a simulated result and also declares no external side effect, but retains its write-class approval gate as a policy test.
- The client displays backend-issued approval requests and cannot downgrade permission policy.
- The approval Ghost Future uses tool-definition metadata only: bounded route labels, scope, side-effect class, reversibility, and an external flag. Tool arguments are excluded, and the note summary exposes only its character count instead of repeating sensitive text.

## Privacy Veil, audio, and room anchors

- Privacy Veil hides agent identity labels, transcripts, code, approvals, cognition, and mission geometry and stops an active speech capture. Other palm actions are locked until the veil is deliberately cleared.
- Privacy Veil is shoulder-surfing mitigation, not deletion or cancellation. Provider runs may continue, SQLite still contains prior messages, and physical display privacy remains the user's responsibility.
- Procedural spatial cues encode only a semantic cue name, tone parameters, duration, and 3D position. They never receive message bodies or tool arguments. Set `spatial_agent/spatial_audio_enabled=false` to disable them.
- `RoomAnchorRegistry` stores bounded semantic transforms in memory for the current process. It rejects raw-scene-mesh classifications, does not persist anchors, and does not enable Meta Scene API. A future vendor adapter must preserve this minimization boundary.

## Cognition telemetry

- The spatial cognition layer receives normalized event types plus a separate command signal containing only command type and thread ID. Command payloads are intentionally absent.
- Its 32-record temporal buffer stores sanitized labels, timestamps, thread identifiers, event class, and risk class—never prompts, response deltas, code, tool arguments, credentials, or backend error bodies.
- Token events are counted and aggregated into visual pulses. A regression test injects a recognizable secret payload and verifies that it never appears in the visual buffer or labels.
- The privacy route is an awareness indicator, not a network security control. Hosted mode still requires the consent and data-handling judgment described above.

## Not yet production-ready

Authentication, encryption at rest, secure multi-user sessions, audit retention controls, remote TLS deployment, sandboxed tool workers, and threat-model review remain outside this prototype.

For Quest development, prefer the supplied `adb reverse` tunnel. It connects the headset to a loopback-bound backend without exposing the unauthenticated service to the local network.
