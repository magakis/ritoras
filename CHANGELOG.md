# Changelog

All user-visible changes to Ritoras are recorded here, newest build first.
Each section is keyed to the **build number** shown on your device under
Settings → Ritoras (the *Build* field) and on the SideStore install page.
Build numbers are GitHub Actions run numbers — one per successful CI build.

Categories: **Added**, **Changed**, **Fixed**. Entries are hand-written and
curated for users, not a git-log dump. Pure-refactor and CI-only changes are
omitted. See CONTRIBUTING.md for the authoring workflow.

Builds before the first numbered section below had no changelog.

## Unreleased

### Added

### Changed

### Fixed

- Starting a new dictation immediately after stopping or cancelling one no longer corrupts the new session — the new recording used to be torn down or left in a broken state.
- Switching to another text field while a transcription is still being processed no longer inserts the dictated text into the wrong field.
- Holding the backspace key while a dictation times out no longer causes unwanted deletions in the next text field you focus.
- Rapidly double-tapping the stop/cancel control no longer fires duplicate cancel requests.
- Fixed a rare concurrency issue in the local dictation server that could affect running dictations.
- The dictation state server inside the app now restarts itself automatically if it stops responding, so the keyboard's recording and transcribing indicators no longer get stuck after the app has been backgrounded or the system disrupted the server. Previously you had to force-close and reopen the app to recover.

<!-- To cut a build: rename "## Unreleased" to "## Build <run_number> — <YYYY-MM-DD>",
     then open a fresh "## Unreleased" above it. <run_number> = latest CI run
     number + 1 (see the install page or `gh run list --workflow build.yml -L 1`). -->

## Build 245 — 2026-08-09

### Added

- Stop a dictation by tapping the mic button, or cancel it by holding the mic button for 3 seconds — no need to switch back to the app.
- Added diagnostic logging that shows exactly which app-group resolution step fails, making sharing problems easier to track down.

### Changed

- The on-screen keyboard now has matching spacing above the top row of keys and below the spacebar, giving the keys a bit more breathing room.

### Fixed

- Fixed the cursor jumping back to its previous position after typing a space or punctuation, and after pasting a dictation result.
- The dictation button now shows the recording indicator while you speak, instead of jumping straight to the transcribing state.
- Mic button now shows the red recording dot (instead of the waiting ellipsis) when you switch back to the keyboard during an active dictation.
- Fixed a SideStore issue where the dictation button never showed the red recording dot (and cross-app sharing silently failed) because the keyboard and app could not locate their shared app-group container.
- Fixed dictation results not reaching the keyboard on SideStore installs where the shared app-group container was unavailable — results now arrive through a localhost fallback.
- Made the red recording dot on the dictation button appear more reliably at the start of speech on SideStore installs, where it could previously be missed and the button would jump straight to the transcribing state.
- The Debug Logs screen no longer jumps back to the top while you're scrolling through older log entries.
- Fixed an issue where the dictation recording indicator could briefly disappear right after starting, making it seem like the recording had stopped.
- A dictation result that comes through while you're in a different text field now waits for the original field instead of pasting into the wrong one.
- When a dictation times out or fails, the keyboard now fully stops its background polling instead of letting it run silently.
- Under memory pressure, the keyboard now sheds restartable background work alongside its dictionary so iOS is less likely to kill it mid-typing; an in-flight dictation keeps its recovery path.
