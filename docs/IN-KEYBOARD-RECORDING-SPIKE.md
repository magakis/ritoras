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

The **Transcription server** field saves an optional keyboard-local base URL.
Save a valid `http://` or `https://` URL (trailing slashes are removed); an
invalid value is shown inline and is not saved. Saving the field empty clears
the override. A local URL takes precedence over the App Group server selection
and list; with no local URL, the existing App Group list/selection is used, then
the compiled-in server default. The panel reports the effective URL and its
source. Thus a SideStore install can use its real Whisper server without the
App Group container being available.

When the keyboard is dismissed or another field takes focus during active
in-keyboard recording, the latest non-empty partial is inserted at the cursor
once before the stream is cancelled and audio is torn down. With VAD chunking,
closing the keyboard keeps what you said up to the last pause; an unfinished
utterance that has not produced a partial is still cancelled without text.

## Final mixable-session dismissal experiment

The keyboard-only recorder explicitly configures `.playAndRecord` with
`.mixWithOthers`, then activates after the keyboard has already set its
recording state/Connecting status and completed the WebSocket handshake. It
does not request `.defaultToSpeaker`: this path only captures microphone input
and should not force an output route. The container app continues using its
existing non-mixable `.record` session.

For the next device run, confirm the keyboard Audio log reports
`session activation result` with `result=success`, then `session configured`
with `category=AVAudioSessionCategoryPlayAndRecord`, `options=mixWithOthers`,
`mixable=true`, and the active input sample rate. An activation
failure is logged at `.error` with NSError domain/code and the keyboard shows
guidance to pause host audio and retry. If the host still dismisses the keyboard
immediately after activation despite those mixable-session lines, record the
timestamps and conclude this is an OS-level keyboard/audio-session limitation;
the feature remains disabled by default rather than prompting another UX or
capture redesign.

The startup-path self-dismissal audit found no pre-capture `textDocumentProxy`
mutation, `dismissKeyboard`, or `advanceToNextInputMode` call. Before capture,
the controller only updates its own mic styling and transcript/status label,
then connects the WebSocket; `setDictationTranscript` changes a UILabel in the
keyboard's own view. `advanceToNextInputMode` remains on the separate globe-key
action. `viewWillDisappear` and controller deinit are teardown responses to a
dismissal, not calls made by the in-keyboard start path.

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
   `in-keyboard-start` before leaving the panel. If the compiled-in server is
   not reachable, enter the device's transcription server URL in the panel,
   save it, and verify the effective server/source display.
4. Tap the mic, confirm Connecting → live partials → stop → final text inserted;
   verify a 60+ second recording completes without jetsam. Also dismiss during
   active recording and confirm the latest partial remains inserted once while
   the stream is cancelled and audio tears down cleanly.
5. Return to the cog panel and choose **Unset**. With App Group mode false, tap
   mic and confirm the legacy container-app flow opens and completes unchanged.
