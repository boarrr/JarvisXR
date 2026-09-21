# Untethered daemon link

The headset talks to the Spatial Agent daemon over the local network with TLS
and per-device pairing. USB is only needed to install the APK and (optionally)
seed the device configuration once.

## What is proven

- **Dev CA and server certificate** are generated locally by `scripts/tls.sh`
  with SANs for the LAN address, the machine hostname, `localhost`, and
  `127.0.0.1`. Regeneration is automatic when the LAN address changes.
- **LAN daemon**: `scripts/run_backend.sh --lan` binds `0.0.0.0:8787` with
  `SPATIAL_AGENT_AUTH_REQUIRED=1` and the generated certificate, and holds the
  Mac awake with `caffeinate`.
- **WSS + pairing over TLS** is covered by `backend/tests/test_tls_auth.py`:
  the self-signed chain is trusted via the CA, an untrusted client is rejected,
  plain `ws://` cannot skip TLS, and the pairing → token → authenticated
  session flow completes.
- **Device token over Wi-Fi** was verified from a separate machine client:
  the token seeded into the headset authenticated against
  `wss://<lan-ip>:8787/ws` with `auth: paired`.
- **Keypad pairing UI** (poke-touch 8×4 grid) is exercised by
  `cockpit_panels_smoke`; the panel opens itself in pairing mode when the
  daemon rejects an unauthenticated session.

## Operating it

1. Generate certificates (idempotent, re-runs when the LAN IP changes):

   ```sh
   ./scripts/tls.sh
   ```

2. Start the daemon on the LAN:

   ```sh
   ./scripts/run_backend.sh --lan
   ```

3. Pair a headset. Two paths:

   - **On-screen keypad (product path).** Point the app at the daemon URL, then
     open the daemon panel and poke **PAIR WITH CODE**. If the URL is wrong the
     panel opens automatically after an auth error.
   - **USB bootstrap (fast dev path).** With the APK installed and the headset
     attached, run:

     ```sh
     ./scripts/daemon_config.sh          # writes URL, CA, and a fresh device token
     ./scripts/daemon_config.sh --show   # inspect what the device holds
     ```

     Then relaunch the app; it connects over Wi-Fi with no further input.

4. Bluetooth keyboard users can still type `/pair CODE` in the composer.

## Performance measurement

- A `PerfProbe` node prints one line per 10 s window:

  ```text
  PERF {"fps_avg":...,"frame_ms_p95":...,"draw_calls":...,"static_mem_mb":...,
        "interactables":...,"threads":...,"ui_mode":"xr_hands"}
  ```

  Collect with `adb logcat -d | grep "PERF "`.
- The palm screen renders on demand (`UPDATE_ONCE`) and is disabled while
  hidden, so it does not consume the frame budget when out of view.
- The XR runtime requests a **72 Hz** display refresh rate
  (`spatial_agent/xr_refresh_rate`, set to 90 only as an experiment).
- Gesture telemetry prints at 1 Hz when enabled with
  `--gesture-telemetry` in the export preset's extra arguments or the
  `spatial_agent/gesture_telemetry` project setting. It contains only
  distances (pinch gap, fingertip-to-palm) and tracking-loss counts — never
  positions or content.
- Thermal and battery snapshots:

  ```sh
  adb shell dumpsys thermalservice | grep -i "thermal status"
  adb shell dumpsys battery | grep -E "level|temperature"
  ```

## Device acceptance checklist

- [ ] Install over USB, then disconnect USB; app reaches `connected` over Wi-Fi.
- [ ] Keypad pairing works on-device (remove `files/daemon.cfg` to force it).
- [ ] Daemon restart keeps the device paired (token persists).
- [ ] Wi-Fi drop and return reconnects without app restart.
- [ ] Wrong CA or wrong host fails cleanly instead of connecting insecurely.
- [ ] 15-minute session: record PERF series, thermal status, battery delta.
- [ ] Gesture thresholds reviewed against telemetry and tuned.

## Known limits

- No mDNS discovery yet; the daemon address is seeded or typed.
- The device token is stored in `user://daemon.cfg` on the headset in plain
  form inside the app sandbox; a production build should move it to the
  Android Keystore.
- `spatial_agent/allow_unsafe_tls` exists only as an explicit development
  escape hatch and must remain `false` in shipping builds.
- A Mac that sleeps still suspends agent runs; `--lan` uses `caffeinate`, but
  Lid closed still sleeps unless the machine is on power with a display.
