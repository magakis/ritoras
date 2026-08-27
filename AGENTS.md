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

## Local Swift syntax check — mandatory pre-commit gate

**Before every commit that touches any `.swift` file, run this script. If it exits non-zero, fix the error — do not commit.** This is not optional.

```bash
node scripts/parse-check.mjs
```

The full sweep parses ALL git-tracked `.swift` files with `swiftc -parse` (~3–5 s). This is the authoritative commit gate.

### Invocation modes

```bash
# Full sweep — MANDATORY commit gate (all git-tracked .swift files)
node scripts/parse-check.mjs

# Changed-only — files modified vs HEAD (falls back to full sweep if none changed)
node scripts/parse-check.mjs --changed

# Explicit paths — files and/or directories (non-.swift silently ignored, missing paths warned)
node scripts/parse-check.mjs keyboard/Sources/KeyboardViewController.swift shared/
```

### What it does NOT catch

**Type errors are uncatchable on Linux** — there is no iOS SDK, so `swiftc -typecheck` cannot run on UIKit imports. This is permanent on this hardware. The only real type-check gate is GitHub Actions CI on push (see [CI / deploy](#ci--deploy)).

### Reassurance for agents

You do NOT need to manually inspect Swift syntax, eyeball code for typos, or stress about catching syntax errors by eye. The script is the authoritative local gate. Run it, read its output, fix what it reports. That's it.

### Prerequisite

[Swiftly](https://github.com/swiftlang/swiftly) (`swiftly install latest --use`). The script auto-discovers the toolchain or prints install instructions.

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

### Test policy

This repository uses a **two-tier testing model**:

1. **Pure-logic tests (Node.js — ALLOWED, the official test surface).** Pure-logic
   components — `CurrentWordExtractor`, `ApostropheNormalizer`,
   `WordBoundaryPunctuation`, `SymSpell` delete-index + lookup, `QwertyGeometry`,
   `Trie`, `Contractions`, `AutocorrectController`, and the `PredictionEngine`
   fusion formula (Apple boost + KenLM min-max normalization + two-tier threshold)
   — are unit-tested via a co-maintained JavaScript port under
   `scripts/prediction-sim/`. These tests run on the Linux dev machine
   (`node --test 'scripts/prediction-sim/test/**/*.{js,cjs,mjs}'`) with no Mac, Xcode, or simulator.
   The JS port is a **first-class mirror** of the Swift pure-logic modules, kept in
   sync as the Swift evolves — not a throwaway reproduction. It serves triple duty:
   (a) regression net for algorithmic changes, (b) parameter sweeper for α and the
   autocorrect thresholds, (c) precision/recall measurer against a typo corpus.

2. **Swift XCTest targets (FORBIDDEN).** Do not create XCTest files, do not re-add
   a `RitorasTests` (or any other) target to `project.yml`, and do not add an
   `xcodebuild test` step to CI. The historical `RitorasTests` target accumulated
   119 compilation errors and was removed; pure-logic coverage now lives in the
   Node harness. Swift is verified only by build-on-push CI on `macos-15`.

**Device/UI/end-to-end testing remains manual** via the `ritoras-ios-debugging`
skill (libimobiledevice / pymobiledevice3). The Node harness does NOT cover UIKit,
AVFoundation, `textDocumentProxy` interaction, the 48 MB Jetsam cap, or any runtime
behavior — only pure algorithmic logic.

**Working rule:** when a change touches pure logic, add or update the corresponding
JS port + test in `scripts/prediction-sim/` in the same commit. When a change
touches UIKit/AVFoundation/device behavior, verify on device manually.

### 48 MB Jetsam memory cap

The keyboard extension is killed without warning if it exceeds ~48 MB resident memory. This is a hard OS limit, not a guideline.

- `SymSpell` index alone uses ~25 MB.
- Prediction data is mmap-backed; clean, file-backed pages are excluded from `phys_footprint`.
- Regenerate `keyboard/Sources/Prediction/Resources/symspell_index_*_v1.blob` with `node scripts/prediction-sim/bin/build-symspell-blob.mjs` whenever wordlists or `symspellMaxEditDistance`/`symspellPrefixLength`/`symspellMinWordFreq` change.
- The in-memory build remains the automatic fallback (kill-switch: `SharedConfig.Defaults.symspellMappedIndexEnabled`); KenLM loads lazily via mmap with a read-mode fallback.
- Any change to `keyboard/` or `shared/` that touches memory must be reasoned about against this 48 MB cap before a keyboard change is considered done. There is no automated test enforcing the memory cap (the Node harness covers pure logic only, not runtime memory — see *Test policy*); verify on device with the `ritoras-ios-debugging` skill.
- Prefer streaming / in-place approaches over holding full data structures.
- Release builds strip debug dylibs in `build.yml` specifically to fit this budget — do not disable that step.

### Keyboard `Info.plist`

`keyboard/Info.plist` is hand-written (`GENERATE_INFOPLIST_FILE: NO` in `project.yml`). These fields are load-bearing — removing any of them crashes the keyboard on device:

- `NSExtension.NSExtensionPrincipalClass` must be the literal string `RitorasKeyboard.KeyboardViewController` (not a variable reference).
- `NSExtension.NSExtensionAttributes.RequestsOpenAccess` must be `true`.
- `NSExtension.NSExtensionAttributes.PrimaryLanguage` must be present — omitting it crashes iOS 27.

Do not switch `GENERATE_INFOPLIST_FILE` to `YES` — XcodeGen will overwrite the custom plist.

### Pre-commit parse check

Before every commit touching `.swift` files, run the mandatory syntax check (see [Local Swift syntax check](#local-swift-syntax-check)). A non-zero exit means a Swift syntax error — fix it, do not commit.

## Git workflow

This repository is checked out as multiple git worktrees. Agents work independently, each in its own worktree on its own branch. The shared `main` branch is the integration point.

**Never push to the remote.** The remote (`magakis/ritoras` — the "gate" repository) is pushed only by the user, manually. Agents must never run `git push`, never run `scripts/deploy-ipa.mjs`, and never trigger CI by pushing. CI runs only after the user pushes.

**When an agent's commits are finished:**
1. Make sure all work is committed on the worktree's branch.
2. Integrate the branch into `main` using a fast-forward merge only — no merge commits: `git merge --ff-only <branch>`.
3. Stop and report "merged to main, ready for you to push." Do not push.

If a fast-forward is not possible because another worktree has already merged new commits onto `main`, rebase the branch onto `main` first, then fast-forward merge again. Never force-push to `main`, and never create a merge commit for routine integration.

## Commits

**Prose-style messages, not conventional commits.** No `feat:` / `fix:` prefixes.

Format: `subsystem: concise summary of the change` — subsystem from the table in CONTRIBUTING.md (`keyboard:`, `shared:`, `ci:`, `app:`, etc.). Example: `keyboard: cap PCM buffer ring to stay under Jetsam limit`.

Body required for non-trivial changes, wrapped at 75 columns.

The repo uses the OpenCode committer protocol: dispatch the committer agent for a numbered commit plan, present it to the user, then execute the chosen commits. After execution, verify with `git log --oneline -5` — the committer sometimes returns empty output on success. After commits land, follow [Git workflow](#git-workflow): fast-forward merge into `main` and stop. Never push.

## CI / deploy

**Single workflow:** `.github/workflows/build.yml`. Triggers: push to `main`, pull requests, `workflow_dispatch`. Runner: `macos-15` (Xcode 16.4).

The workflow produces an unsigned `Ritoras.ipa` (~3.1 MB) uploaded as a build artifact. Build time is 5–10 minutes once the runner starts.

**Deploy to device:** SideStore (on-device signing). The full pipeline — push → CI wait → artifact download → HTTP serve → `sidestore://install?url=` — is automated in `scripts/deploy-ipa.mjs`, but **the push step is the user's manual action** (see [Git workflow](#git-workflow)). Agents never push and never run the deploy script themselves; the user pushes `main` and then, optionally, runs the pipeline.

**Load the `ritoras-deploy-pipeline` skill before any deploy**; it documents the complete commit-to-device cycle including rollback from `~/.local/share/ritoras/builds/<runId>/`. GitHub token lives at `/home/michael/.config/opencode/gh-token`; repo is `magakis/ritoras`. These credentials are for the user's manual push — agents must not use them to push.

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
