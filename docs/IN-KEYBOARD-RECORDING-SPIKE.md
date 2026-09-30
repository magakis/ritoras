# In-keyboard recording spike

This experimental path captures and streams audio inside the keyboard extension.
It is disabled by default; the existing container-app dictation flow remains
the default and is unchanged.

## Enable and exercise on device

1. Open Ritoras once and grant microphone access.
2. Enable **Full Access** for Ritoras under iOS Keyboard settings.
3. In Ritoras Settings → Keyboard, enable **In-keyboard recording (experimental)**.
4. Return to a text field, tap the keyboard microphone, speak with pauses, then
   tap the microphone again to stop. The latest server partial appears in the
   keyboard's top status/suggestion strip; the final transcript is inserted at
   the cursor. Dismissal or interruption cancels the active stream.
5. For the regression check, turn the option off and confirm the microphone
   continues to open the Ritoras app as before.

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
