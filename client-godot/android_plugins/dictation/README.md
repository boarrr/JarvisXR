# Android dictation plugin (optional)

This Gradle project builds the optional `AndroidDictation` Godot Android plugin
used by `services/android_speech_service.gd`. It wraps `android.speech.SpeechRecognizer`
so the headset can dictate with on-device speech. Only finalized text reaches
the game; raw audio stays inside the operating system speech service.

## Requirements

- JDK 17
- Android SDK 35 with build tools
- Gradle 8.x (or add a wrapper)
- A Godot Android build template already installed in `client-godot/android/`
  (`./scripts/quest.sh setup`)

## Build and install

From the project root:

```sh
./scripts/quest.sh dictation-plugin
```

The helper builds `dictation-release.aar`, installs it as
`client-godot/android/plugins/AndroidDictation/DictationPlugin.aar` together
with `DictationPlugin.gdap`, and reminds you to export with Gradle enabled.

If Gradle or the Android SDK is missing the helper stops with a clear message;
the application still runs and `ASK / VOICE` falls back to the hand-only quick
intent panel.

## Verification status

The GDScript boundary, state machine, and failure handling are covered by
`tests/android_speech_service_smoke.gd` using an injected bridge. Building the
AAR, microphone permission prompts, and real recognition quality have not been
verified in this repository environment; they require the user's Android
toolchain and a physical headset.
