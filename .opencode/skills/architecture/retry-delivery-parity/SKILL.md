---
name: "Retry Must Mirror Original Delivery Path"
description: "Apply when implementing retry for an operation that delivers results through multiple channels (clipboard, IPC, Darwin notifications, UI phase transitions) — the retry must use the same delivery path as the original, including all side effects and phase transitions. A retry that runs silently in the background without changing UI state looks like a dead button. If the operation has no multi-channel delivery, skip."
confidence: 0.8
domain: "architecture"
source: "session-extraction"
created: "2026-07-21"
last_confirmed: "2026-07-21"
metadata:
  opencode:
    tags: [retry, delivery, ipc, darwin-notifications, phase-transitions, ui-state, ios]
    related_skills: [localhost-ipc, sidestore-app-group]
---

# Retry Must Mirror Original Delivery Path

## When to Apply

Apply when implementing a retry mechanism for an operation that delivers its results through more than one channel — clipboard, IPC server, Darwin notifications, persistent history, UI phase transitions. The retry must go through the same delivery path, not a silent background path.

## Overview

When an operation fails and the user taps "Retry," the retry must behave indistinguishably from the original operation from the user's perspective. This means:

1. **Same UI transitions** — if the original transitions through `.recording → .transcribing → .done`, the retry must transition through `.transcribing → .done` (showing the loading UI)
2. **Same delivery channels** — if the original writes to clipboard, posts to an IPC server, fires Darwin notifications, and adds to history, the retry must do ALL of those
3. **Same cleanup** — if the original cleans up temporary files on success, the retry must clean up the saved audio and any recovery records

A common mistake: implementing retry as a "background" operation that runs silently (writes to clipboard only, no phase transition, no IPC, no notifications). The user taps Retry, nothing visibly happens, and they conclude the button is broken.

## Action

### 1. Catalog the original operation's delivery path

Read the success path of the original operation (e.g., `stop()` in a dictation view model). List every side effect:

- UI phase transitions (`phase = .transcribing`, `phase = .done(text)`)
- Clipboard writes (`writeToClipboard(status:text:)`)
- IPC server posts (`postResultToServer(status:text:)`)
- Darwin notifications (`DarwinNotifier.post(...)`)
- Persistent history (`TranscriptionHistory.shared.add(text:)`)
- In-memory result store (`resultStore.set(...)`)
- File cleanup (delete temp audio, remove recovery records)

### 2. Create a retry method that mirrors this path

```swift
func retryAsLiveDictation(jobId: UUID) async {
    // Look up saved audio
    guard let record = FailedJobStore.shared.list().first(where: { $0.jobId == jobId }),
          FileManager.default.fileExists(atPath: record.audioFilePath) else {
        phase = .error("Saved audio no longer available")
        return
    }

    let audioURL = URL(fileURLWithPath: record.audioFilePath)

    // Transition to transcribing — user sees the loading UI
    activeID = jobId
    phase = .transcribing

    do {
        let text = try await WhisperClient.transcribe(
            audioURL: audioURL, config: config, correlationId: jobId)

        // Supersede guard — same as the original operation
        guard activeID == jobId else { return }

        // MIRROR the original operation's success delivery — every call:
        writeToClipboard(status: "completed", text: text)
        postResultToServer(status: "completed", text: text)
        DarwinNotifier.post(.dictationCompleted)
        TranscriptionHistory.shared.add(text: text)
        resultStore.set(..., for: jobId)

        // Cleanup
        try? FileManager.default.removeItem(atPath: record.audioFilePath)
        FailedJobStore.shared.remove(jobId: jobId)

        phase = .done(text)   // ← MUST transition phase, not just write to clipboard
    } catch {
        guard activeID == jobId else { return }
        FailedJobStore.shared.updateErrorMessage(jobId: jobId, message: error.localizedDescription)
        phase = .error(error.localizedDescription)  // ← MUST transition back to error
    }
}
```

### 3. Distinguish foreground retry from background recovery

Two retry contexts need different delivery behavior:

| Context | Phase transitions? | IPC + Darwin? | When to use |
|---|---|---|---|
| **Foreground retry** (error screen button) | YES — user is watching | YES — result must reach the keyboard | User taps "Retry Transcription" on the error screen |
| **Background recovery** (history/settings screen) | NO — runs inline | NO — just clipboard + history | User opens Settings → Failed Transcriptions and taps Retry |

The foreground retry is a live operation. The background recovery is a maintenance action.

### 4. Wire the error screen button to the foreground retry

The error screen's "Retry" button must call the phase-driving method, NOT the silent background method:

```swift
// DictationView error screen:
Button("Retry Transcription") {
    Task { await viewModel.retryAsLiveDictation(jobId: requestId) }  // ✅ drives phases
}
// NOT:
// Task { await viewModel.retry(jobId: requestId) }  // ❌ silent, looks dead
```

### 5. Add visible feedback for background recovery

For the background recovery path (Settings screen), add inline feedback since there are no phase transitions:

- Loading spinner on the retry button
- Success/failure toast after completion (auto-dismissed after 3 seconds)
- Updated error message in the row if retry fails

## Common Pitfalls

- **Silent retry looks like a dead button**: a retry method that catches errors and does nothing visible makes the user think the button is broken. Always transition phase or show inline feedback.
- **Forgetting one delivery channel**: if the original fires Darwin notifications but the retry doesn't, the keyboard extension never learns about the retried result. Catalog every channel and mirror each one.
- **Two retry buttons with different behavior**: if the error screen has "Try Again" (starts new recording) and RecoveryView has "Retry" (re-transcribes saved audio), users will confuse them. Name them distinctly: "Retry Transcription" vs "Start New Recording."

## Evidence

- Session 2026-07-21: the Ritoras dictation retry was implemented as a silent background method (`retry(jobId:)`) that wrote to clipboard but didn't transition phase or fire Darwin notifications. The user tapped "Retry Transcription" on the error screen and reported "nothing happened — it's like the button is dead." Fixed by adding `retryAsLiveDictation(jobId:)` that mirrors `stop()`'s delivery path (clipboard, postResultToServer, DarwinNotifier, TranscriptionHistory, phase transitions). Commits `0d29314`.
- User explicitly requested: "I prefer when I click it to get the same transcribing screen that I have when I am actually transcribing."

## Verification Checklist

- [ ] The foreground retry method transitions through the same phases as the original operation
- [ ] Every delivery channel from the original success path is called in the retry success path
- [ ] The error screen's retry button calls the phase-driving method, not the silent background method
- [ ] Background recovery (Settings screen) shows inline loading + toast feedback
- [ ] Retry button labels are distinct ("Retry Transcription" vs "Start New Recording")
