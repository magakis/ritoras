# In-keyboard recording spike

This experimental path captures and streams audio inside the keyboard extension.
It is disabled by default; the existing container-app dictation flow remains
the default and is unchanged.

## Enable and exercise on device

1. Open Ritoras once and grant microphone access.
2. Enable **Full Access** for Ritoras under iOS Keyboard settings.
3. On App-Group-capable installs, enable **In-keyboard recording
   (experimental)** in Ritoras Settings → Keyboard. If Settings reports the
   option unavailable, use the keyboard's two-finger language-badge gesture
   described below and cycle until the flash says `local=on`.
4. Return to a text field, tap the keyboard microphone, speak with pauses, then
   tap the microphone again to stop. The latest server partial appears in the
   keyboard's top status/suggestion strip; the final transcript is inserted at
   the cursor. Dismissal or interruption cancels the active stream.
5. For the regression check, set the local override to `unset` (or turn the app
   option off on an App-Group-capable install), confirm the flash reports
   `effective=false`, and verify the microphone opens the Ritoras app as before.

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

## Phase 1 self-diagnostics

The build workflow stamps both app and keyboard `Info.plist` files with
`RitorasBuildCommit` (8-character short SHA); `CFBundleVersion` remains the CI
run number. The workflow passes `RITORAS_BUILD_COMMIT=<short SHA>` to
`xcodebuild` and verifies both resulting bundle plists against that SHA and
`github.run_number`. The on-screen identity is displayed as `<short SHA>/<run>`.

On keyboard summon, the existing status strip cycles through the build identity,
App Group resolver strategy and availability, the mode inputs (local override
and fresh App Group value), Full Access and microphone permission, and the next
mic branch. It clears itself after a few seconds and gives way immediately to
transcript/status text. Re-show it with a two-finger tap on the language
badge at the right end of the suggestion strip. The badge's existing single-tap
language picker remains a single-tap action. The two-finger gesture now cycles
the keyboard-local override through `unset → on → off → unset`; every tap
immediately shows the refreshed flash so the selected state and resulting
effective mode/next route are visible. `unset` follows the freshly-read App
Group value; explicit `on` and `off` take precedence. The value lives in the
keyboard extension's standard `UserDefaults` and survives extension process
death.

The app's Settings → Diagnostics rows show the app bundle's identity, resolved
suite, resolver strategy, container availability, and the in-keyboard toggle
value last written by the app. Compare these values with the keyboard flash to
identify build mismatch and cross-process App Group availability without
retrieving logs.

When the app-side resolver reports no App Group container, Settings replaces
the app toggle with an unavailable message directing the user to the keyboard
gesture. When the container is available, the app toggle retains its normal
App Group write and Darwin-notification behavior.

For CI or another XcodeGen build pipeline, set the user-defined build setting
`RITORAS_BUILD_COMMIT` to the built commit's 8-character short SHA. The custom
bundle key is `RitorasBuildCommit`; the build/run number is `CFBundleVersion`
(`CURRENT_PROJECT_VERSION`). Both values must be stamped into the app and
embedded keyboard extension Info.plists. The in-repository GitHub Actions
workflow performs this injection; an external pipeline must use the same
contract.

The flash's mode line reports `local=unset|on|off`, `group=<bool>`, and the
effective mode. The branch preview and mic action use the same mode-selection
inputs: local override when present, otherwise a fresh App Group read. With a
local override of `unset` and App Group false, the legacy container-app flow
remains the expected default.
