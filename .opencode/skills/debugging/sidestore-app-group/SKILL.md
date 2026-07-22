---
name: "SideStore App-Group Container Unavailable"
description: "Apply when an iOS app or extension distributed via SideStore/AltStore gets nil from containerURL(forSecurityApplicationGroupIdentifier:) or when cross-process UserDefaults/clipboard/inbox transports work intermittently — SideStore rewrites entitlements at resign time, appending TeamID to app-group identifiers. If not distributing via SideStore/AltStore, skip."
confidence: 0.9
domain: "debugging"
source: "session-extraction"
created: "2026-07-21"
last_confirmed: "2026-07-21"
metadata:
  opencode:
    tags: [sidestore, altstore, app-group, entitlements, containerURL, ios]
    related_skills: [localhost-ipc, ritoras-ios-debugging]
---

# SideStore App-Group Container Unavailable

## When to Apply

Apply when an iOS app or extension distributed via SideStore/AltStore gets nil from `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` or when cross-process communication via the shared app-group container works intermittently or not at all.

## Overview

SideStore (and AltStore) rewrite the binary's entitlements at resign time. The `FetchProvisioningProfilesOperation.swift` in SideStore's source appends the user's TeamID to every app-group identifier: `group.com.example.app` becomes `group.com.example.app.XM66X5B256`. The binary's signed entitlements then contain the suffixed identifier, not the original.

When your code calls `containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.app")`, iOS checks the binary's signed entitlements, doesn't find the original identifier (because the binary has the suffixed version), and returns nil. Every app-group-dependent feature silently breaks.

The insidious part: `UserDefaults(suiteName: "group.com.example.app")` returns a **non-nil** object even without a matching entitlement. It creates a per-process plist that is never actually shared. This masks the problem — the code "works" (no crash) but data written by one process is invisible to the other.

## Action

### 1. Diagnose: confirm the container is truly unavailable

```swift
let original = "group.com.example.app"
if let _ = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: original) {
    print("container available — problem is elsewhere")
} else {
    print("container nil — SideStore likely rewrote the entitlement")
}
```

If nil, check the binary's actual entitlements by reading `embedded.mobileprovision`:

```swift
if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
   let data = try? Data(contentsOf: url),
   let raw = String(data: data, encoding: .isoLatin1),  // NOT .ascii — CMS wrapper has binary bytes
   let start = raw.range(of: "<?xml"),
   let end = raw.range(of: "</plist>"),
   let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .utf8),
   let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
   let entitlements = plist["Entitlements"] as? [String: Any],
   let groups = entitlements["com.apple.security.application-groups"] as? [String] {
    print("actual app-group identifiers: \(groups)")
}
```

The output will show the team-suffixed identifier(s).

### 2. Resolve: use AppGroupResolver pattern

Try multiple strategies to find a working identifier at runtime:

1. **Try the original identifier** — works on App Store, TrollStore, Simulator (no rewriting).
2. **Try the team-suffixed identifier** — extract TeamID from the bundle ID suffix (`com.example.app` → `com.example.app.XM66X5B256` → TeamID = `XM66X5B256`), construct `group.com.example.app.XM66X5B256`.
3. **Read from embedded.mobileprovision** — parse the actual app-group string from the provisioning profile (most authoritative).

Cache the result (NSLock + optional). All callers use the resolved identifier.

### 3. Bypass app groups for single-process persistence: use Application Support

For files that only the **container app** needs to read/write (audio recordings, recovery metadata, local caches), bypass the app-group container entirely. Use `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` — it is:

- **Persistent** — survives app suspension, process death, and iOS memory pressure
- **Entitlement-free** — no app-group dependency, works under SideStore/AltStore/App Store/Simulator
- **Always available** — part of every iOS app's sandbox

```swift
guard let appSupport = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask).first else {
    // This should NEVER happen — fail loudly, do not fall back to temp
    throw StorageError.unavailable
}
let recordingsDir = appSupport.appendingPathComponent("Recordings")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
```

This is the correct storage location for recovery files, saved audio, failed-job indexes — anything the container app owns and the keyboard extension does not need to read.

### 4. Alternative: bypass app groups for cross-process communication

If you need data shared between the keyboard extension and the container app, use a **localhost HTTP server** instead of the app-group container. See the `localhost-ipc` skill.

### 5. Validate UserDefaults is genuinely shared

`UserDefaults(suiteName:)` returning non-nil does NOT prove sharing. To validate: write a test value from one process, read from the other. If they diverge, the suite is per-process (entitlement mismatch).

## Common Pitfalls

- **`UserDefaults(suiteName:)` false positive**: returns non-nil even without matching entitlement — silently writes per-process. This masked the SideStore container issue for weeks in the Ritoras project.
- **`.ascii` encoding fails on mobileprovision**: the CMS-signed binary wrapper contains bytes >127. Use `.isoLatin1` which maps every byte 1:1.
- **Intermittent vs structural**: the nil return is structural (every call fails under SideStore), not intermittent. If you see intermittent failures, the issue is likely elsewhere (timing, race condition).
- **AppGroupResolver fallback masks failure**: if all resolution strategies fail, returning the original identifier as a "graceful fallback" silently perpetuates the problem. Log loudly when all strategies fail.
- **NSTemporaryDirectory fallback causes silent data loss**: falling back to `NSTemporaryDirectory()` when the app-group container is unavailable allows recording to continue, but iOS purges temp on app suspension. The user thinks audio is saved, but it is gone by the time they retry. **Never use NSTemporaryDirectory as a fallback for user data — throw instead.** This caused the user to lose speech twice before being caught.

## Evidence

- Session 2026-07-21: Ritoras keyboard-container IPC was broken for the entire session. The user reported phantom idle, stale auto-paste, missed transcriptions. Root cause traced to SideStore rewriting `group.com.ritoras.app` → `group.com.ritoras.app.64GGL77Z3X`.
- SideStore source code (`FetchProvisioningProfilesOperation.swift`): `adjustedGroupIdentifier = groupIdentifier + "." + team.identifier` with comment "Append just team identifier to make it harder to track."
- fcitx-contrib/fcitx5-iOS README: "Without developer account, App Group can't be used" — the only open-source SideStore-distributed keyboard documents the same issue.
- User's runtime log confirmed: `"app group container unavailable — using temporary fallback directory"` — the error that exposed the structural failure.
- Session 2026-07-21 (dictation resilience): Audio recordings fell back to `NSTemporaryDirectory()` when the app-group container was unavailable under SideStore. iOS purged temp on suspension, and the user's 6-minute recording was lost. Fixed by moving all persistence to Application Support — no entitlement dependency, works under all installation methods. The user tested and confirmed across 3 build iterations.

## Verification Checklist

- [ ] `containerURL(forSecurityApplicationGroupIdentifier:)` returns non-nil for the resolved identifier
- [ ] `UserDefaults(suiteName:)` data written by one process is readable by the other (cross-process test)
- [ ] AppGroupResolver logs which strategy succeeded (not silently falling back)
- [ ] If using localhost IPC fallback: server starts and accepts connections from the other process
- [ ] Single-process persistent files use Application Support, not app-group or NSTemporaryDirectory
- [ ] No silent fallback to NSTemporaryDirectory for user data (throw instead)
