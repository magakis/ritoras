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

- Stop a dictation by tapping the mic button, or cancel it by holding the mic button for 3 seconds — no need to switch back to the app.

### Changed

- The on-screen keyboard now has matching spacing above the top row of keys and below the spacebar, giving the keys a bit more breathing room.

### Fixed

- The dictation button now shows the recording indicator while you speak, instead of jumping straight to the transcribing state.
- Mic button now shows the red recording dot (instead of the waiting ellipsis) when you switch back to the keyboard during an active dictation.

<!-- To cut a build: rename "## Unreleased" to "## Build <run_number> — <YYYY-MM-DD>",
     then open a fresh "## Unreleased" above it. <run_number> = latest CI run
     number + 1 (see the install page or `gh run list --workflow build.yml -L 1`). -->
