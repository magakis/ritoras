---
name: "Localhost HTTP IPC for iOS Keyboard"
description: "Apply when an iOS keyboard extension needs reliable cross-process communication with its container app and app-group containers are unavailable (SideStore/AltStore) — use NWListener HTTP server on 127.0.0.1 in the container app + URLSession client in the keyboard, with Darwin notifications for signaling. If app groups work, skip — use the simpler shared-container approach."
confidence: 0.8
domain: "architecture"
source: "session-extraction"
created: "2026-07-21"
last_confirmed: "2026-07-21"
metadata:
  opencode:
    tags: [ios, keyboard, localhost, nwlistener, ipc, http, sidestore]
    related_skills: [sidestore-app-group, ios-keyboard-plist, ios-keyboard-layout]
---

# Localhost HTTP IPC for iOS Keyboard

## When to Apply

Apply when building or modifying cross-process communication between an iOS keyboard extension and its container app, and the app-group container is unavailable (SideStore/AltStore environment). If the app-group container works (App Store, TrollStore, Simulator), use the simpler shared-container approach instead.

## Overview

The container app runs a lightweight HTTP server on `127.0.0.1` using Apple's Network framework (`NWListener`). The keyboard extension polls the server via `URLSession` to get dictation state and results. Darwin notifications provide push-style signaling (the server posts a notification on state changes, the keyboard re-queries immediately). Legacy transports (clipboard, remote server polling) remain as fallback.

This architecture was built for Ritoras after the app-group inbox transport proved unworkable under SideStore. It solves three problems: phantom idle (keyboard shows recording-in-progress UI via `/state` polling), result latency (~1ms localhost vs 300ms-1.2s remote), and crash regression (no file-I/O on the broken container).

**Key infrastructure files:**
- `app/Sources/LocalhostServer.swift` — NWListener server (container app only)
- `shared/LocalhostClient.swift` — URLSession async client (keyboard)
- `shared/DictationSnapshot.swift` — shared Codable types
- `keyboard/Sources/KeyboardLogShipper.swift` — ships keyboard logs to container via POST /logs

## Action

### 1. Build the server (container app only)

```swift
let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
params.requiredInterfaceType = .loopback  // CRITICAL: restricts to 127.0.0.1
listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
```

Expose 3 GET endpoints: `/health`, `/state?id=<UUID>`, `/result?id=<UUID>`. Plus 1 POST endpoint: `/logs` (for keyboard log shipping).

Set `Connection: close` on every response (simplifies lifecycle — no keep-alive state to manage).

**Thread safety**: `@Sendable` closures (stateProvider, resultProvider) must NOT touch `@MainActor`-isolated state directly. Use a `@unchecked Sendable` wrapper class with internal `NSLock` for shared mutable state.

### 2. Build the client (shared, used by keyboard)

Use `URLSessionConfiguration.ephemeral` with `timeoutIntervalForRequest = 1.0` (localhost is ~1ms; 1s is generous). Map `URLError.cannotConnectToHost` to a `connectionRefused` error — this is the expected signal that the container app is dead.

### 3. Wire the keyboard polling

In `viewDidAppear`, start a `DispatchSourceTimer` at 0.5s interval. Each tick calls `refreshStateFromLocalhost()` which:
1. `getState(id:)` — if phase is `recording`/`transcribing`, show recording UI (fixes phantom idle)
2. If phase is `done`/`error`, `getResult(id:)` → insert text

On 3 consecutive `connectionRefused` errors, fall back to legacy server polling.

### 4. Ship keyboard logs via POST /logs

Under SideStore, the keyboard's `FileLogger` writes to per-process Documents (invisible to container app's DebugLogView). Fix this:

- Add `public static var broadcast: ((LogLevel, LogComponent, String, [String: Any]?) -> Void)?` to FileLogger
- In keyboard's `viewDidLoad`, set the broadcast to feed entries into `KeyboardLogShipper`
- Shipper buffers up to 100 entries, POSTs every 2s (immediate flush on `.warn`/`.error`)
- Container app's `POST /logs` endpoint writes received entries to its own FileLogger → visible in DebugLogView

**Loop safety**: `FileLogger.broadcast` is nil in the container app (never set). Server-received log writes do not trigger re-shipping.

### 5. Strip diagnostic logging before shipping

During development, add `.error`-level diagnostic logs at every step of server startup to trace failures. Mark with `// DIAGNOSTIC LOGGING — TEMPORARY, REMOVE AFTER DEBUGGING`. Strip after diagnosis. Keep operational logs (server lifecycle, errors).

## Common Pitfalls

- **NWListener binds to all interfaces by default**: the default `NWListener(using:port:)` constructor binds to `0.0.0.0`. You MUST set `params.requiredInterfaceType = .loopback` BEFORE constructing the listener, or the server is exposed to any process on the device.
- **Keyboard killed by iOS during long recording**: iOS kills keyboard extensions aggressively for memory. On respawn, the keyboard process starts fresh — `pendingRequestId` (UserDefaults) survives, but in-memory state is lost. The localhost polling restarts on `viewDidAppear`.
- **`.debug` and `.info` logs may be filtered in DebugLogView**: use `.error` or `.warn` level for diagnostic logging to guarantee visibility.
- **NWListener startup is async**: `listener.start(queue:)` returns immediately; the `.ready` state fires later via `stateUpdateHandler`. Don't assume the server is ready the instant `start()` returns.

## Evidence

- Session 2026-07-21: Full architecture built across 4 phases + 5 reviewer fixes. User confirmed: "it seems to be very consistently responding... While waiting, there was this dictating icon where the microphone normally is and after a few seconds the transcription arrived and automatically got pasted."
- Commits `cbba564` through `c7dce19` — the full implementation, compile fixes, diagnostic cycle, and cleanup.
- Fcitx5-iOS (https://github.com/fcitx-contrib/fcitx5-ios) uses the same pattern (HTTP local server fallback when app group is unavailable) — the only mature open-source SideStore-distributed keyboard.
- User's diagnostic logs confirmed server startup: `NWListener constructed successfully` → `listener stateUpdateHandler fired: ready` → `LocalhostServer: ready`.

## Verification Checklist

- [ ] `curl http://127.0.0.1:<port>/health` returns `{"status":"ok"}` while container app is foregrounded
- [ ] Keyboard polls `/state` and shows recording UI when phase is `recording`/`transcribing`
- [ ] Keyboard polls `/result` and inserts text when phase is `done`
- [ ] 3-strikes connection-refused fallback works (kill container app → keyboard falls back to remote)
- [ ] Keyboard logs appear in container app's DebugLogView (log shipping)
- [ ] No `DIAGNOSTIC` log entries remain in production build
- [ ] `SymSpellMemorySpike` test passes (keyboard memory budget intact)
