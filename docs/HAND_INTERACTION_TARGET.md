# Hand-Only XR Interaction Target

The final product is controller-free. Keyboard, mouse, and desktop shortcuts were used only to make the interaction model testable before headset hardware was introduced; they are gone now that the desktop simulator has been retired.

## Core gesture language

| Intent | Hand interaction | Semantic application event |
|---|---|---|
| Aim at distance | Index-ray or stabilized hand ray | Pointer origin/direction and hover |
| Select an orb | Pinch begin | `SELECT` |
| Move a panel/orb | Pinch-hold and move | `GRAB_BEGIN`, `GRAB_MOVE`, `GRAB_END` |
| Scroll code | Pinch-hold inside the code surface and drag vertically | Semantic code scroll |
| Open workspace controls | Present tracked left palm | Palm console with spatial targets |
| Summon cognition telemetry | Pinch **Cognition Lens** on the palm | Show/collapse causal constellation |
| Summon mission topology | Pinch **Mission Map** on the palm | Show/collapse content-blind swarm links |
| Conceal sensitive holograms | Pinch **Privacy Veil** on the palm | Lock and hide workspace surfaces |
| Inspect event history | Pinch Rewind / Forward / Return Live | Move temporal event lens |
| Resize/reposition panel | Two-hand pinch and spread/move | Bimanual transform gesture |
| Dismiss | Push-away or explicit palm-menu action | `DISMISS` |
| Approve sensitive action | Pinch explicit approve target | `APPROVE` |
| Deny sensitive action | Pinch explicit deny target | `DENY` |

Voice remains complementary for message content, never a required substitute for explicit approval.

## Design constraints

- No workflow may require a tracked controller, keyboard, mouse, or handheld phone in the final XR build.
- Gaze may stabilize targeting but must not confirm an action by itself.
- Destructive and external actions require an explicit pinch on a clearly labeled spatial control; passive dwell is insufficient.
- Panels need generous hand targets, depth separation, and hysteresis to avoid accidental activation.
- Direct touch should be available at arm's length; hand ray serves distant objects.
- Pinch-drag scrolling must include dead-zone and velocity filtering so natural hand tremor does not move code.
- Hand-specific data stays in `OpenXRInteractionSource`; `AgentOrb`, `CodeViewer`, panels, commands, and backend remain device-neutral.

## Current implementation

`XRRuntime` owns a real OpenXR origin/camera; there is no desktop fallback. `OpenXRInteractionSource` polls both Godot `XRHandTracker` paths, rejects controller-inferred skeletons, requires valid/tracked joint flags, prefers the right hand for aim, and falls back to the left. A distal-index-to-tip vector becomes a smoothed ray; thumb/index distance drives a 24 mm begin / 36 mm release pinch hysteresis.

While the code surface is hovered, vertical pinch movement is quantized into Vim viewer scroll events. When both hands pinch that surface, midpoint, hand separation, and signed yaw become `GRAB_BEGIN/MOVE/END` events that reposition, scale, and rotate the whole panel. The left-palm console exposes agent focus, Code Trace, Cognition, Mission Map, Privacy Veil, Ask/Voice, and Dismiss. If mobile speech is unavailable, Ask opens four fixed quick intents, so the complete headset navigation and agent-direction path still needs only tracked hands.

The Cognition Lens follows the focused orb and turns backend event classes into a spatial causal constellation. Rewind, Return Live, and Forward are generous pinch targets on its temporal ribbon; no raw prompt, response token, or tool argument is stored in that visual history. Local/fake and hosted provider routes are visibly distinct.

The approval gate blocks lower-priority surfaces and provides separate Approve and Deny targets. Headset ergonomics and false-positive rates still require a physical Quest acceptance pass; headless tests feed simulated joints through `OpenXRInteractionSource.submit_joint_sample`, so the gesture interpreter is automated without hardware.

Privacy Veil is intentionally still reachable while an approval is pending. This prevents a sensitive consent surface from trapping the user: veil first, then clear it and decide. All other non-approval hand actions remain blocked by the consent gate.
