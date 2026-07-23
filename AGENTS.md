# Ritoras

iOS keyboard extension with voice dictation. Swift 5.9, UIKit (keyboard) + SwiftUI (container app), iOS 17.0+ deployment target. XcodeGen-managed project — no SPM, no CocoaPods.

**Read [`CONTRIBUTING.md`](CONTRIBUTING.md) first** — it is the authoritative source for the commit message format, PR workflow, and pre-submission checklist (440 lines). This file captures only what an agent would otherwise miss.

## Environment constraint (read first)

The user runs on **Linux, not macOS**. There is no local Xcode, no `xcodebuild`, no Console.app. All builds go through GitHub Actions CI on `macos-15` runners. Never suggest opening Xcode, running a local Release build, or inspecting Console — those commands cannot run here.

For iOS device debugging from Linux, use libimobiledevice (`idevicesyslog`, `idevicecrashreport`) and `pymobiledevice3`. Load the `ritoras-ios-debugging` skill.

## Build system

**Never edit `Ritoras.xcodeproj` directly.** It is generated from `project.yml` via XcodeGen. Regenerate after any change to build settings, targets, or non-auto-included paths:

```bash
xcodegen generate
```

New `.swift` files under `keyboard/`, `app/Sources/`, and `shared/` are **auto-included** by recursive globs in `project.yml` — do not edit `project.yml` just to register a new source file in those directories.

**Authoritative Release build (matches CI):**

```bash
xcodegen generate && \
  xcodebuild -project Ritoras.xcodeproj -scheme Ritoras \
    -destination 'generic/platform=iOS' -configuration Release build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Unsigned by design — CI produces an unsigned `.ipa` for SideStore on-device signing. No Apple Developer account is involved.

No `make`, `just`, `fastlane`, or pre-commit hooks. Custom scripts live in `scripts/`.

## Architecture

Two XcodeGen targets share one project:

| Target | Bundle ID | Role |
|---|---|---|
| `Ritoras` | `com.ritoras.app` | SwiftUI container app (settings, onboarding, transcription history) |
| `RitorasKeyboard` | `com.ritoras.app.keyboard` | UIKit keyboard extension (prediction, autocorrect, emoji) |

- App entrypoint: `app/Sources/RitorasApp.swift`
- Keyboard entrypoint: `keyboard/Sources/KeyboardViewController.swift`
- `shared/` is compiled into **both** binaries — AudioRecorder, WhisperClient, Config, FileLogger, etc. A change here rebuilds both targets.
- Both targets share the `group.com.ritoras.app` app group entitlement.
- **The keyboard uses UIKit, not SwiftUI.** SwiftUI adds 5–10 MB and does not fit the keyboard memory budget.

## Hard constraints

### No build-fixer subagent

Never dispatch the build-fixer subagent for this project. The orchestrator
must always skip the default "end-of-session full build verification" step
after coder phases complete.

Reason: the development environment is Linux with no local Xcode or
`xcodebuild` (see [Environment constraint](#environment-constraint-read-first)
above). Build-fixer cannot function here — any failure report it produces
is about the missing toolchain, not about broken code. Do not attempt to
substitute a local build check.

The only real build gate is GitHub Actions CI on push. Wait for that.

### No tests

This repository intentionally has **no test target and no automated tests.** Do not
create XCTest files, do not re-add a `RitorasTests` (or any other) target to
`project.yml`, and do not add a `xcodebuild test` step to CI. CI only builds; it has
never run tests here, and a test target is dead weight this repo does not carry.

When a change needs verification, prefer a build-only CI gate and manual on-device
checks (see the `ritoras-ios-debugging` skill). The 48 MB Jetsam cap below is enforced
by reasoning and on-device observation, **not** by an automated test.

Treat the absence of tests as a deliberate decision — not an oversight to "fix."

### 48 MB Jetsam memory cap

The keyboard extension is killed without warning if it exceeds ~48 MB resident memory. This is a hard OS limit, not a guideline.

- `SymSpell` index alone uses ~25 MB.
- Any change to `keyboard/` or `shared/` that touches memory must be reasoned about against this 48 MB cap before a keyboard change is considered done. There is no automated test enforcing it (see the *No tests* constraint) — verify on device with the `ritoras-ios-debugging` skill.
- Prefer streaming / in-place approaches over holding full data structures.
- Release builds strip debug dylibs in `build.yml` specifically to fit this budget — do not disable that step.

### Keyboard `Info.plist`

`keyboard/Info.plist` is hand-written (`GENERATE_INFOPLIST_FILE: NO` in `project.yml`). These fields are load-bearing — removing any of them crashes the keyboard on device:

- `NSExtension.NSExtensionPrincipalClass` must be the literal string `RitorasKeyboard.KeyboardViewController` (not a variable reference).
- `NSExtension.NSExtensionAttributes.RequestsOpenAccess` must be `true`.
- `NSExtension.NSExtensionAttributes.PrimaryLanguage` must be present — omitting it crashes iOS 27.

Do not switch `GENERATE_INFOPLIST_FILE` to `YES` — XcodeGen will overwrite the custom plist.

## Commits

**Prose-style messages, not conventional commits.** No `feat:` / `fix:` prefixes.

Format: `subsystem: concise summary of the change` — subsystem from the table in CONTRIBUTING.md (`keyboard:`, `shared:`, `ci:`, `app:`, etc.). Example: `keyboard: cap PCM buffer ring to stay under Jetsam limit`.

Body required for non-trivial changes, wrapped at 75 columns.

The repo uses the OpenCode committer protocol: dispatch the committer agent for a numbered commit plan, present it to the user, then execute the chosen commits. After execution, verify with `git log --oneline -5` — the committer sometimes returns empty output on success.

## CI / deploy

**Single workflow:** `.github/workflows/build.yml`. Triggers: push to `main`, pull requests, `workflow_dispatch`. Runner: `macos-15` (Xcode 16.4).

The workflow produces an unsigned `Ritoras.ipa` (~3.1 MB) uploaded as a build artifact. Build time is 5–10 minutes once the runner starts.

**Deploy to device:** SideStore (on-device signing). The full pipeline — push → CI wait → artifact download → HTTP serve → `sidestore://install?url=` — is automated in `scripts/deploy-ipa.mjs`. **Load the `ritoras-deploy-pipeline` skill before running any deploy**; it documents the complete commit-to-device cycle including rollback from `~/.local/share/ritoras/builds/<runId>/`.

**Do not push manually to deploy.** The deploy script handles credentials via a temporary git helper that wipes the PAT after use. GitHub token lives at `/home/michael/.config/opencode/gh-token`. Repo: `magakis/ritoras`.

### CI failure triage

- 24-second failure → hard Swift compile error.
- 5+ minute failure → runtime issue (CI does not run tests).
- Pull logs for a SHA:
  ```bash
  RUN_ID=$(gh api repos/magakis/ritoras/actions/runs?head_sha=<SHA> --jq '.workflow_runs[0].id')
  gh api repos/magakis/ritoras/actions/runs/$RUN_ID/logs > /tmp/run-logs.zip
  ```
- Swift compile errors land in `5_Build (unsigned, Release).txt` inside the zip.
- Common pattern: "cannot find type in scope" when a nested type is referenced from a sibling scope — fix by hoisting or fully-qualifying the reference.
- Do not trust any "verified the fix" claim without a green CI run on the new SHA.

## Whisper server contract

The dictation feature POSTs audio to a Whisper-compatible transcription server. The full spec is in `docs/SERVER-CONTRACT.md`. Two non-obvious details worth knowing without opening the doc:

- Multipart field name is `audio`, not `file`.
- No auth header by default.

## Logging standard

Every `FileLogger` call across the codebase follows the level definitions and decision rules in [docs/LOGGING.md](docs/LOGGING.md). The four levels — `.debug`, `.info`, `.warn`, `.error` — map onto Apple's `os.Logger` severity scale and are defined with concrete Ritoras examples and anti-examples.

**Before writing any new log call, consult the standard.** Key rules every contributor must know:

- `.debug` for developer diagnostics (VAD transitions, first-attempt network errors, poll scheduling)
- `.info` for normal lifecycle and user-action confirmations (view loaded, connection established)
- `.warn` for unexpected but recoverable (memory-pressure unloading, fallback paths, retries exhausted)
- `.error` for hard failures with user impact (module init failure, audio unavailable)
- Do not log normal lifecycle events at `.warn`
- Retryable errors: `.debug` on first attempt, `.warn` after all retries exhausted
- In the keyboard extension (48 MB Jetsam cap), keep log messages lean — never construct large strings on the hot path

The component-to-subsystem mapping (`LogComponent` cases `.prediction`, `.keyboard`, `.network`, `.audio`, `.dictionary`, `.transcription`, `.app`, `.settings`, `.lifecycle`) is also documented there with typical level usage per component.

## OpenCode-local config

`.opencode/`:
- `skills/automation/ritoras-deploy-pipeline/` — full commit-to-device cycle. **Load before any deploy.**
- `skills/debugging/ritoras-ios-debugging/` — libimobiledevice / pymobiledevice3 device debugging from Linux.
- `instincts/ritoras.jsonl` — 21 verified facts covering keyboard plist quirks, memory caps, deploy pipeline edge cases, and the committer's empty-output behavior. Query via `ctx_search` before assuming something is undocumented.

`docs/`: `IMPLEMENTATION-PLAN.md`, `SERVER-CONTRACT.md`, `Sideload.md`, `THIRD-PARTY-NOTICES.md`.
