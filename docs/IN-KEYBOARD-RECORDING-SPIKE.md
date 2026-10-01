# In-keyboard recording spike

This experimental path captures and streams audio inside the keyboard extension.
It is disabled by default; the existing container-app dictation flow remains
the default and is unchanged.

## Enable and exercise on device

1. Open Ritoras once and grant microphone access.
2. Enable **Full Access** for Ritoras under iOS Keyboard settings.
3. On App-Group-capable installs, enable **In-keyboard recording
   (experimental)** in Ritoras Settings → Keyboard. If Settings reports the
   option unavailable, tap the keyboard's cog key, then choose **On** in its
   Dictation Mode control.
4. Return to a text field, tap the keyboard microphone, speak with pauses, then
   tap the microphone again to stop. The latest server partial appears in the
   keyboard's top status/suggestion strip; the final transcript is inserted at
   the cursor. Dismissal or interruption cancels the active stream.
5. In the cog panel, choose **Unset** and verify the displayed effective mode
   is off when the App Group setting is false; the mic should open Ritoras as
   before. On App-Group-capable installs, turning the app option off also
   restores the default flow when local mode is unset.

## What to observe

Inspect the device's Ritoras debug log (or unified device logs) for the
`in-kb-rec` prefix and the Audio component. Record `footprintBytes` and
`residentBytes` for `before-start`, `after-start-1s`, each `during-capture`
sample (approximately every five seconds), and `after-stop`. The startup line
also records whether `isOtherAudioPlaying` was true. Observe WebSocket connect,
chunk, partial, END/CANCEL, final, and insertion events as well.

## Spike pass/fail

Pass if the extension stays below the existing 48 MiB load guard throughout a
60+ second recording, audio reaches the configured transcription server, live
partials appear, manual stop inserts the final text, and dismiss/interruption
leaves no active recorder or stream. Fail if the extension is jetsammed or its
footprint exceeds 48 MiB during capture, if the stream fails to deliver audio or
the final result, or if teardown leaves capture/network work active. Record the
peak footprint and device/iOS version either way. A future refinement may duck
host playback rather than interrupt it; this spike deliberately mirrors the
container recorder's current audio-session behavior.

## Build identity and keyboard settings panel

The build workflow stamps both app and keyboard `Info.plist` files with
`RitorasBuildCommit` (8-character short SHA); `CFBundleVersion` remains the CI
run number. The workflow passes `RITORAS_BUILD_COMMIT=<short SHA>` to
`xcodebuild` and verifies both resulting bundle plists against that SHA and
`github.run_number`. The on-screen identity is displayed as `<short SHA>/<run>`.

Tap the cog key in the right-hand slot of the suggestion strip to open the
in-keyboard settings panel. Its Dictation Mode control offers **Unset**, **On**,
and **Off**. Unset follows the freshly-read App Group value; explicit on/off
take precedence. The selection is stored in the keyboard extension's standard
`UserDefaults` and survives extension process death. The panel displays local,
App Group, and effective mode values, the next mic branch, build identity,
resolver strategy/availability, Full Access, and microphone permission. It
blocks touches to the keyboard beneath it and can be dismissed with Close or a
tap outside the panel.

The suggestion/status strip no longer shows build or settings diagnostics. It
is reserved for dictation state, live partials, and guidance. The language key
is temporarily replaced by the cog for this test phase; language switching is
therefore unavailable from the keyboard until the language key is restored or
a future panel design adds language selection.

The app's Settings → Diagnostics rows show the app bundle's identity, resolved
suite, resolver strategy, container availability, and the in-keyboard toggle
value last written by the app. Compare these values with the keyboard panel to
identify build mismatch and cross-process App Group availability without
retrieving logs.

When the app-side resolver reports no App Group container, Settings replaces
the app toggle with an unavailable message directing the user to open keyboard
settings with the cog key. When the container is available, the app toggle
retains its normal App Group write and Darwin-notification behavior.

For CI or another XcodeGen build pipeline, set the user-defined build setting
`RITORAS_BUILD_COMMIT` to the built commit's 8-character short SHA. The custom
bundle key is `RitorasBuildCommit`; the build/run number is `CFBundleVersion`
(`CURRENT_PROJECT_VERSION`). Both values must be stamped into the app and
embedded keyboard extension Info.plists. The in-repository GitHub Actions
workflow performs this injection; an external pipeline must use the same
contract.

## Phase 3 device observation protocol

1. Open the keyboard settings panel from the cog and verify the expected build
   identity and App Group resolver strategy/availability there.
2. Compare the app Diagnostics row's last-written toggle value with the panel's
   fresh App Group value, then choose **On** in the keyboard-local Dictation Mode
   control.
3. Verify local mode is on, effective mode is on, and Next mic reports
   `in-keyboard-start` before leaving the panel.
4. Tap the mic, confirm Connecting → live partials → stop → final text inserted;
   verify a 60+ second recording completes without jetsam and that dismiss or
   interruption cancels cleanly.
5. Return to the cog panel and choose **Unset**. With App Group mode false, tap
   mic and confirm the legacy container-app flow opens and completes unchanged.
