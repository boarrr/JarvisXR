# Spatial UX Notes

## Visual language

- The interface is an original holographic instrument system: near-black optical glass, restrained cyan/teal emission, fine calibration marks, segmented arcs, and layered depth.
- Agent states animate through core pulse, gimbal motion, a segmented status arc, color, text, and unread cues instead of relying on a glossy sphere.
- Amber and red are reserved for approval, blocked, and error states. Decorative light stays subordinate to readable content.
- A hand-ray reticle establishes aim without turning the view into an opaque screen dashboard.

## Orb workspace

- Orb centers sit about 2.2 m from the user near eye height.
- Stable slots expand symmetrically from straight ahead: center, left, right, then outward.
- The primary ring spans 200 degrees with ten slots; overflow uses a slightly higher, more distant ring instead of shrinking targets indefinitely.
- The active instrument diameter is about 0.44 m and collision targets are slightly larger for reliable hand-ray pointing.
- Color, label, motion, ring emphasis, and unread cue distinguish idle, listening, working, waiting, complete, error, and selected states.

These are tunable defaults. Physical Quest comfort and reach still need hardware validation.

## Focus and transcript

- Selecting an orb focuses its thread and places one world-space transcript in a forward-right reading zone.
- The transcript shows the seven most recent messages and marks a streaming assistant message with a block cursor.
- Push-away or a palm-menu dismiss action clears focus without archiving the thread.

## Code trace

- The Vim-inspired viewer is a read-only floating trace, not a complete IDE. It shows the latest fenced assistant/tool code with line numbers, syntax highlighting, current-line emphasis, minimap, path, and position.
- In XR, pinch-drag scrolls; the palm console opens or closes the trace; a two-hand pinch uses midpoint, separation, and yaw to reposition, scale, and rotate it.
- The viewer remains attached to the focused thread and updates during streaming while preserving its scroll position.
- A fenced `diff` or `patch` grows a small animated sculpture beside the surface: additions occupy the green/right lane, removals the red/left lane, and context remains dim cyan. Geometry is capped at 48 lines for Quest.

## Spatial cognition lens

- Focusing an agent materializes a lightweight causal constellation around its core. Ten reusable event nodes encode memory, cognition, tool, consent, completion, and fault classes through color and pulse rather than exposing hidden reasoning text.
- The temporal black box retains at most 32 sanitized records. Rewind and Forward inspect the sequence; Return Live snaps back to the newest event. Token deltas aggregate into activity pulses instead of creating an unreadable node per token.
- A three-node privacy route shows **Hand → Local Core → Sealed** in offline mode and names the selected hosted provider when prompt context can leave the machine. Amber marks consent boundaries; magenta marks hosted egress.
- Cognition Lens on the palm toggles the layer, allowing either a calm workspace or dense telemetry without changing the agent run.

## Message and command entry

- The left-palm console exposes Ask / Voice after a thread is focused. If speech is unavailable, it opens four explicit quick intents: Continue, Summarize, Explain Code, and Privacy Review.
- Commands use an explicit slash form so destructive and workspace operations are not confused with ordinary messages.
- Archive is explicit; dismiss never deletes a thread.

## Approval

- The backend, not the view, decides when approval is required.
- The world-space approval panel names the tool, summarizes the proposed action, and shows the permission level. Its Ghost Future renders the content-blind action route, scope, side-effect class, and reversibility without repeating arguments.
- The XR design requires an explicit pinch on spatial Approve or Deny targets. No tool handler begins before an approve response.

## Voice

- Ask / Voice starts push-to-talk where the speech service is available.
- Listening and transcribing are visually distinct states. The UI states that transcription is local.
- The speech service emits text only; `CommandRouter` applies the same focused-thread/global-command routing used by protocol commands.
- A 20-second default recording ceiling limits accidental capture. Audio retention is off by default.
- The shipped `whisper-cli` adapter runs only in headless tests. Quest uses quick intents until a mobile-native speech implementation can preserve the same text-only protocol boundary.

## Hand-only acceptance rule

- The final headset workflow must be completable with tracked hands alone: aim/direct touch, pinch select and grab, pinch-drag scrolling, palm controls, and two-hand panel manipulation.
- Gaze can stabilize aim but never confirms a selection or approval. No final task may depend on a controller, keyboard, mouse, or phone.

## Palm command console

- The console follows the tracked left palm with smoothing and faces the user's head for legibility; it hides when that hand is lost or outside a practical near-field range.
- The right index ray selects Next Agent, Code Trace, Ask / Voice, Cognition, Mission Map, Privacy Veil, or Dismiss. Live rows expose provider/model, backend link, and microphone state without opening a flat dashboard.
- The ray is cyan while aiming and amber while pinching. Loss of optical tracking immediately clears the selection state.

## Mission topology and privacy veil

- Mission Map overlays animated, status-coloured pulses between explicit parent relationships and focused-to-active correlations. Its legend says which edges are inferred and explicitly warns that the visualization is not task authority.
- Privacy Veil is a single deliberate palm pinch. It replaces sensitive holograms with one calm, content-free notice; the same target remains available to restore the prior workspace. The notice states that background runs continue.
- Procedural 3D tones make focus, completion, attention, approval, faults, and veil transitions distinguishable without looking away. They are quiet, short, and contain no speech.
