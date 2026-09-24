# Reliable adb & wireless updates

## Why wireless adb is flaky

- **The host adb server restarts.** When it does, the `tcp:5555` transport to the
  headset is lost (the device keeps listening, but the server has to
  `adb connect` again). Symptom: `daemon not running; starting now`.
- **The headset goes `offline` when idle.** Wi-Fi power-save / battery saver
  shuts the radio down, adbd's TCP connection times out, and the device flips to
  `offline` mid-transfer. Symptom: `device offline` right after connecting.
- **`tcpip 5555` is not persistent.** It resets on every headset reboot, so
  wireless adb has to be re-armed once over USB.
- **RF conditions.** At RSSI ≈ -67 dBm on 5 GHz the link is workable but lossy;
  a 90 MB push has a long failure window and drops with
  `failed to read copy response: EOF`.
- **USB churn.** Unplugging mid-operation resets the transport.

## Mitigations (implemented)

- `scripts/adb_ensure.sh` centralises recovery: starts the host server, prefers
  a USB device, reconnects the cached wireless address with retries, heals
  `offline` entries (`disconnect` + `connect`), and waits a bounded budget.
  `scripts/quest.sh` installs now go through it.
- `scripts/adb_tune.sh` (run automatically by `scripts/daemon_config.sh`) sets
  `wifi_sleep_policy=2` (never sleep), disables low-power/adaptive battery, and
  enables stay-awake. This removes the idle `offline` drops.
- The daemon's `update.apply` install (`_adb_install`) now starts the server,
  prefers USB, reconnects the cached Wi-Fi address, and **retries the install up
  to 4 times**, healing the transport between attempts, with a long timeout.
- **Smaller payload.** Release builds with compressed native libraries are
  **~30 MB instead of ~95 MB** (`./scripts/quest.sh export-release`) — a 3×
  smaller transfer that is far less likely to drop.
- The app still falls back to in-app download + install if adb is unavailable.

## Setup checklist

1. Mac and headset on the **same SSID**; prefer **5 GHz** and RSSI better than
   about -60 dBm (move closer to the router).
2. Keep the headset **charging** while updating so stay-awake and Wi-Fi tuning
   take effect.
3. After a headset reboot, re-arm wireless adb once over USB:
   `./scripts/quest.sh wifi` (or `./scripts/adb_ensure.sh --arm`).
4. For the most reliable installs, **keep USB connected** and use
   `./scripts/quest.sh install`. Use Wi-Fi when you want to be untethered.
5. Apply device tuning after pairing: `./scripts/quest.sh tune`.

## Commands

- `./scripts/adb_ensure.sh` — pick a usable device, print its serial.
- `./scripts/adb_ensure.sh --arm` — enable wireless via USB and cache the IP.
- `./scripts/quest.sh tune` — Wi-Fi/stay-awake tuning on the device.
- `./scripts/quest.sh export-release` — publish the ~30 MB update payload.
- `./scripts/quest.sh deploy-release-wifi` — export + install over Wi-Fi.
- `./scripts/quest.sh export` / `deploy` — debug build (larger, for logging).

## Notes

- Release builds are signed with the Android **debug keystore** for sideloading;
  swap in a real keystore before any distribution. Debug and release share the
  same signing key, so `adb install -r` upgrades across them.
