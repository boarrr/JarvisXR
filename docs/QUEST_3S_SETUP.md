# Meta Quest 3/3S Setup

The Android export is configured for passthrough mixed reality, ARM64, optical hand tracking, no controller dependency, and the Meta OpenXR vendor only. Desktop remains offline/fake by default; Android selects the WebSocket backend through a feature-tag override.

## 1. Workstation prerequisites

Install:

- Godot 4.7.2 and its matching export templates.
- OpenJDK 17. Godot's Android guide currently requires JDK 17, Android platform/build tools 35.0.1, Android 35, and the listed NDK/CMake versions.
- Android SDK platform-tools so `adb` is on `PATH`.
- A Quest 3 or 3S with developer mode, USB debugging, and hand tracking enabled.

In Godot's Editor Settings, set the Java SDK path to JDK 17 and Android SDK path to your SDK. The authoritative requirements are in Godot's [Android export guide](https://docs.godotengine.org/en/4.7/tutorials/export/exporting_for_android.html).

Install Godot's matching export templates from **Editor → Manage Export Templates** before continuing.

## 2. Prepare the project

From the project root:

```sh
./scripts/quest.sh setup
./scripts/quest.sh doctor
```

`setup` performs two bounded operations:

1. Downloads Godot OpenXR Vendors `5.1.0-stable`, verifies its published SHA-256, and installs its `addons/godotopenxrvendors` folder.
2. Asks Godot to install the Android Gradle build template into this project.

The plugin is not bundled in this repository because its compiled multi-platform archive is large. Version `5.1.0-stable` supports Godot 4.6 and later; the configured Meta export uses its hand-tracking and passthrough features. See the vendor project's [installation instructions](https://godotvr.github.io/godot_openxr_vendors/getting-started/installation.html) and [release page](https://github.com/GodotVR/godot_openxr_vendors/releases/tag/5.1.0-stable).

If `doctor` reports Java or SDK problems, fix them in Godot Editor Settings. It deliberately does not alter machine-wide SDK configuration.

### Troubleshooting the first export

Verified on macOS with Godot 4.7.2, Corretto JDK 17, Android SDK 35/36:

- **"A valid Java SDK path is required in Editor Settings."** `JAVA_HOME` is not
  enough for the export check. Set Editor Settings → Export → Android →
  `Java SDK Path` to the JDK 17 home (for example
  `/Library/Java/JavaVirtualMachines/amazon-corretto-17.jdk/Contents/Home`).
  The value lives in `~/Library/Application Support/Godot/editor_settings-4.7.tres`.
  Close the editor before editing that file by hand, or it will overwrite it.
- **"ETC2/ASTC texture compression is required for Android export."** Rev 2
  enables `rendering/textures/vram_compression/import_etc2_astc=true` in
  `project.godot`. If you export an older copy, enable it in Project Settings.
- **"No project icon specified."** Rev 2 ships `client-godot/icon.svg` and sets
  `config/icon`. Add any 128×128 icon if you fork the project.
- **"Trying to build from a gradle built template, but no version info for it
  exists."** Godot expects the marker at `client-godot/android/.build_version`
  (the *parent* of `android/build`) containing the template identifier, e.g.
  `4.7.2.stable`. `Project → Install Android Build Template` writes it; if the
  headless `quest.sh setup` step idles without writing it (observed when a
  Godot editor session holds the project, or on some headless runs), create the
  file by hand:

  ```sh
  printf '4.7.2.stable\n' > client-godot/android/.build_version
  ```

  Also make sure `client-godot/android/build/build.gradle` exists; if not,
  extract `android_source.zip` from the export templates into
  `client-godot/android/build/`.

The helper honors a JDK-17 `JAVA_HOME` and, on macOS, automatically discovers an installed JDK 17 with `/usr/libexec/java_home -v 17`. It scopes that path to setup/export commands and does not replace the machine's default Java.

## 3. Start a backend

For a no-key test:

```sh
cd backend
python3 -m venv .venv
.venv/bin/python -m pip install -e .
.venv/bin/spatial-agent-backend
```

For OpenAI, Claude, or Council, copy `.env.example` to `.env`, install `.[openai]`, `.[claude]`, or `.[hosted]`, and select the provider explicitly. Council needs both keys and sends context to both providers. Keys remain on the computer; they are never exported into the APK.

Keep the backend at its default `127.0.0.1:8787`. The deploy helper uses Android Debug Bridge reverse-port mapping, so the Quest's `ws://127.0.0.1:8787/ws` reaches the computer without exposing an unauthenticated service on Wi-Fi.

## 4. Export and install
Connect the Quest by USB, accept its debugging prompt, then run:

```sh
./scripts/quest.sh deploy
```

This exports `build/quest/spatial-agent.apk`, installs it with `adb install -r`, and creates `adb reverse tcp:8787 tcp:8787`. Open **Spatial Agent XR** from Quest's Unknown Sources library.

Individual commands are available when iterating:

```sh
./scripts/quest.sh export
./scripts/quest.sh install
./scripts/quest.sh tunnel
```

ADB reverse mappings disappear when the device or daemon restarts; rerun `tunnel` when the backend link remains offline.

### First deploy after initial headset setup (verified checklist)

Once the headset has finished its first-run setup with the controllers:

1. Enable Developer Mode for the headset (Meta Horizon app → Devices → Headset
   Settings → Developer Mode). It is usually already on for a developer org.
2. Plug the headset into the Mac and accept **Allow USB debugging** with
   *Always allow from this computer* inside the headset.
3. Confirm `adb devices` shows the serial as `device` (not `unauthorized`).
4. Start the backend from the project copy:
   `backend/.venv/bin/spatial-agent-backend` (loopback, fake provider is fine).
5. Run `./scripts/quest.sh deploy` — exports, installs the APK, and maps
   `tcp:8787` to the Mac.
6. Launch **Spatial Agent XR** from Library → Unknown Sources. The project
   settings select the WebSocket transport on Android, so the headset connects
   to `ws://127.0.0.1:8787/ws` through the ADB tunnel with no LAN setup.
7. Hand tracking is the intended input. If the app cannot see your hands,
   verify Settings → Hands and Controllers → Hand Tracking is on.

## 5. Hand interaction acceptance pass

Test without controllers in your hands:

1. Confirm passthrough is visible and cyan agent instruments are world-space.
2. Point an index finger; verify the cyan ray tracks it and turns amber during pinch.
3. Pinch an orb to focus it.
4. Turn to the left-palm console and use the right hand to pinch **Next Agent**, **Code Trace**, **Cognition**, **Mission Map**, **Privacy Veil**, **Ask / Voice**, and **Dismiss**.
5. On Code Trace, pinch-drag vertically to scroll.
6. Target Code Trace, pinch with both hands, then spread and rotate to resize/yaw it; release either hand to finish.
7. On Cognition Lens, pinch Rewind and Forward, then Return Live; confirm fake mode reads **No Provider Egress**.
8. With mobile speech unavailable, select **Ask / Voice** and send each quick intent by pinch.
9. Summon Mission Map; verify bounded pulses connect active agents and the header calls inferred edges correlations rather than dependencies.
10. Open code containing a fenced diff and verify the red/green sculpture remains readable and comfortable.
11. Activate Privacy Veil; verify identity labels, transcript, code, and telemetry disappear, then clear it from the same palm target.
12. Request `/tool note private test`; verify the amber approval gate omits `private test`, shows a local-only Ghost Future, blocks the workspace, and requires a deliberate Approve or Deny pinch.
13. Confirm focus/attention/approval tones appear spatially located but remain quiet and non-verbal.

Godot exposes optical joint data through `XRHandTracker` at `/user/hand_tracker/left` and `/user/hand_tracker/right`; this project accepts only tracked, valid positions and rejects controller-derived tracking sources. See Godot's [XRHandTracker reference](https://docs.godotengine.org/en/4.7/classes/class_xrhandtracker.html) and [OpenXR settings guide](https://docs.godotengine.org/en/stable/tutorials/xr/openxr_settings.html).

## Network alternative

For wireless development, change `spatial_agent/backend_websocket_url` to a TLS-protected reachable service and implement authentication. Do not simply bind the included unauthenticated backend to `0.0.0.0` for sensitive material. ADB reverse is the recommended development path.

## Current external validation boundary

The code, export preset, plugin installer checksum, headless fallback, hand gesture interpreter, bounded visual geometry, procedural audio generation, and semantic anchor boundary are automated. Meta Scene API is deliberately disabled. Final optical comfort, hand-ray tuning, spatial-audio loudness, passthrough behavior, Android signing, and store packaging must be checked on the user's physical Quest and SDK installation.
