# Hand Lab: testing without a headset

Double-click **Launch Hand Lab.command** in the project folder. It starts Godot with OpenXR explicitly off, so an installed Meta runtime cannot take over. No headset, Python backend, key, or microphone is required in the default fake mode. Normal graphical desktop launches also use Hand Lab; append `-- --classic-desktop` to restore the old centre-ray controls.

## The optimal test loop

1. **Hand Lab every day:** test selection, agent conversations, code reading, quick intents, two-hand transforms, privacy and approval flows. Synthetic finger joints pass through the production pinch, scroll and grab interpreter. The toolbar is a convenience route to the same application actions.
2. **Automated suite after changes:** run `./scripts/test_all.sh`. This exercises backend and scene behavior, including real socket/reconnect tests and the hand gesture interpreter.
3. **Meta XR Simulator periodically:** verify OpenXR startup, supported extensions, joint-tracker names, stereo rendering and passthrough integration. It is not a Quest hardware performance emulator.
4. **Quest 3S acceptance:** test real finger tracking, occlusion, reach, binocular readability, fatigue, thermal performance, passthrough and comfortable hand-only use. Laptop performance does not establish Quest performance.

## Controls

| Input | Effect |
|---|---|
| Move mouse | Aim the synthetic right index finger |
| Left click | Pinch/select through the real hand interpreter |
| Left drag on Code Trace | Pinch-scroll vertically |
| Wheel over Code Trace | Convenient code scrolling |
| Shift + left drag on Code Trace | Pinch with both hands and move the panel |
| Wheel while holding that grab | Spread/close hands to scale |
| Alt + wheel while holding that grab | Twist hands to rotate |
| Hold right mouse and move | Look around |
| WASD, Space, Ctrl | Move horizontally, up, down |
| Home / Reset view | Return to the original viewing position |
| Tab / Next agent | Focus the next agent |
| C / Code | Toggle the code viewer |
| Enter | Type a message or slash command; Enter submits |
| J / K | Scroll code down/up |
| P / Palm | Show or hide the left-palm console |
| T / Tracking | Simulate tracking loss/recovery |
| F1 / Guide | Toggle the practice guide |
| F3 | Existing detailed diagnostics |
| Escape / Dismiss | Dismiss the focused agent |

For two-hand testing, point at the code surface before pressing Shift+left. Release left mouse to end the gesture. The first code opening hides the palm/guide to make room; use P/F1 to restore either. Switching to another application releases all synthetic pinches.

## Five-minute practice

1. Click the amber **Code** orb. A transcript appears and the agent begins a canned local reply.
2. Choose **Code**, then scroll and Shift-drag its floating surface. The offline agent includes a clearly labelled, 80-plus-line demonstration. Increase its size with the wheel while holding Shift+left. Watch the on-screen practice checklist.
3. Choose **Ask**, then pinch **Explain Code**. This sends a quick intent to the focused agent using the configured backend.
4. Toggle **Cognition** and **Mission map**. These show observed events and labelled correlations, not private model reasoning.
5. Toggle **Privacy**. Workspace content disappears; other action buttons cannot reveal it until you clear the veil.
6. In the default fake mode, press Enter and send `/tool note Hand Lab test`. Choose **Deny** on the spatial approval panel. No external file is written by this demo tool.
7. Long transcripts have **Previous / Next** pinch targets and a page counter. All pages stay inside the glass panel; incoming streaming updates preserve the current page.
8. Press T during interaction: the hand ray/palm and hover should clear. Press T to recover.

## Visuals and performance

The reactor floor and 384/1,200/3,200 background motes animate on the GPU. The motes use one bounded MultiMesh batch rather than thousands of nodes. Orb shells have animated surface lattices, a Fresnel rim and a plasma core. The decorative room field is desktop-only; actual XR hides it and the development floor/grid to preserve passthrough.

The top bar reports FPS, the 95th-percentile **frame interval** over at most 180 frames, draw calls and 3D resolution. This is not a GPU timer. At the desktop 60 FPS cap, roughly 16.7 ms is expected even when the GPU has spare capacity.

Click the quality button to cycle **Auto → Eco → Balanced → Ultra → Auto**:

- Auto starts at Balanced. Sustained p95 intervals above 23 ms lower 3D resolution in steps to a 65% floor; sustained recovery below 18 ms gradually restores it. UI text stays native resolution. This adjusts desktop rendering only.
- Eco uses 75% resolution, no MSAA, and 384 motes.
- Balanced uses native resolution, 2× MSAA, and 1,200 motes.
- Ultra uses native resolution, 4× MSAA, and 3,200 motes.

Code-view rendering pauses when the texture is not visible. Procedural sound waveforms are reused. Fake local mode is clearly separate from a hosted provider; the lab does not configure or upload credentials.

## References

- [Meta XR Simulator scope and graphics panel](https://developers.meta.com/horizon/documentation/native/xrsim-intro/)
- [Godot GPU vertex animation](https://docs.godotengine.org/en/stable/tutorials/performance/vertex_animation/index.html)
- [Godot spatial shader reference](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html)

Synthetic hand tests validate application logic. They do not reproduce optical noise, hand self-occlusion, tracking confidence, physical ergonomics, or headset GPU cost.
