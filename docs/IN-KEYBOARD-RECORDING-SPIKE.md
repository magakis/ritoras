# In-keyboard recording experiment — closed

The in-keyboard recording experiment is closed as an OS-level limitation on the
tested SideStore install. The keyboard was dismissed by the system/host when the
capture audio session activated, both with the original `.record` session and
with the final mixable `.playAndRecord` + `.mixWithOthers` experiment. The
keyboard's teardown correctly cancelled the stream; this was not a server or
memory failure. The experiment remains removed, and the container-app dictation
flow is the supported path.

## What was established

- The extension reached the transcription server over WebSocket (connect and
  PONG succeeded) and streamed audio; the failure was the host dismissing the
  keyboard when microphone capture activated.
- The observed process footprint was about 45 MB with the prediction stack
  loaded, below the roughly 48 MB keyboard guard, and no jetsam occurred.
- A mixable `.playAndRecord` session did not prevent dismissal. Further
  in-extension capture changes are not planned unless the OS behavior changes.

## Retained and removed

- Retained: the cog key and lightweight, scrollable keyboard settings panel for
  English/Greek language switching; commit/build identity stamping remains in
  the app and keyboard bundles for future debugging.
- Removed: in-keyboard recording and its mode/server overrides, capture and
  WebSocket wiring, partial-preservation teardown, experimental app controls,
  session instrumentation, and diagnostic UI. The cog no longer exposes any
  recording controls.
- The cog temporarily occupies the former language-key slot. Language switching
  is available from the cog panel; no language key is present during this test
  cleanup.

The keyboard mic uses the existing container-app dictation flow. The app's
server configuration, audio session, and streaming recorder remain the supported
recording path.
