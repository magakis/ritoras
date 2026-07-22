---
name: "Ritoras Committer Protocol"
description: "Apply when committing changes in the Ritoras project — dispatch the committer agent for a numbered commit plan first, present it to the user, then execute. Uses prose-style commit messages (lowercase imperative, no prefix tags). XcodeGen auto-includes new .swift files without editing project.yml. If not committing in the Ritoras repository, skip."
confidence: 0.8
domain: "workflow"
source: "session-extraction"
version: 1.0.0
created: "2026-07-18"
last_confirmed: "2026-07-18"
metadata:
  opencode:
    tags: [git, commit, committer, ritoras, xcodegen]
    related_skills: [committer-empty-result]
---

# Ritoras Committer Protocol

## When to Apply

Apply when committing changes in the Ritoras project — a specific protocol governs how the committer agent is dispatched, how commits are structured, and how to handle partial staging when the same file is touched across multiple feature phases. If not committing in the Ritoras repository, skip.

## Overview

The Ritoras project uses opencode's committer subagent for all commits. The workflow involves a two-phase dispatch (plan first, execute after user approval) to give the user control over commit organization. The project has a prose-style commit convention (multi-paragraph, lowercase imperative summary line, no prefix tags like `fix:` or `feat:`). Because the project uses XcodeGen with a recursive glob on `keyboard/`, new `.swift` files and bundled resources are auto-included in the Xcode project without editing `project.yml`. A notable quirk: the committer agent frequently returns empty output even when commits succeed, so manual verification is essential.

## Action

1. **Dispatch the committer agent** with a brief asking for a numbered commit plan. Say: "Please propose a numbered commit plan (don't execute yet)." The committer will run `git status`, `git diff --stat`, and `git log --oneline -10` to assess the changes.

2. **Present the committer's plan verbatim** to the user. Do NOT summarize or interpret it.

3. **Ask the user** which commits to create: "All / specific numbers / Cancel."

4. **Re-dispatch the committer** with execution instructions matching the user's choice.

5. **Verify afterwards** — the committer often returns empty output even when commits succeed. Always check:
   ```bash
   git log --oneline -5
   git status -sb
   ```

### Partial staging across commits

When two planned commits (e.g. Phase 1 + Phase 4) both touch the same file with interleaved hunks:

1. Try `git diff > /tmp/file.patch`, manually edit the patch to keep only the relevant hunks, then `git apply --cached /tmp/file.patch`.
2. If the hunks are too interleaved (editing the patch would be error-prone), **fall back to combining the commits** into one with a commit message that mentions both concerns.

### Commit message convention

- Prose-style, multi-paragraph explaining WHY not just WHAT
- Lowercase imperative summary line (e.g., "fix EmojiDataFile scope to unbreak CI build")
- No prefix tags like `fix:`, `feat:`, `chore:` — just plain English

## Common Pitfalls

- **The committer returns empty output even when commits succeed.** Do NOT interpret empty output as failure. Always verify with `git log --oneline -5` and `git status -sb`.
- **XcodeGen auto-includes** — new `.swift` files and new bundled resources in `keyboard/` are automatically picked up because `project.yml` has a recursive glob. No need to edit `project.yml`.
- **Patch-file splitting is brittle** when hunks are interleaved (same function modified for different purposes). Combining commits with a compound message is safer than trying to disentangle interleaved hunks.
- **Generated files** (like `emojis.json`) that are committed to the repo WILL be picked up by XcodeGen. Make sure they're tracked in git so CI builds match local builds.

## Evidence

- Session 2026-07-18 (commits bfcf20e–da185eb): The committer was dispatched twice for the emoji-picker feature. Both times it returned empty output but the commits were created successfully. Protocol of "plan first, then execute" was established.
- `git log --oneline -20` shows the prose-style convention in every commit: "keyboard: replace hardcoded emoji arrays with JSON-backed dataset", "fix EmojiDataFile scope to unbreak CI build", etc.
- `project.yml` confirms recursive glob for `keyboard/` with XcodeGen, eliminating the need for manual project file edits.

## Verification Checklist

- [ ] `git log --oneline -5` shows the expected commit(s)
- [ ] `git status -sb` shows a clean working tree (no unstaged changes)
- [ ] Commit messages follow prose style (no `fix:`/`feat:` prefixes)
- [ ] If new files were added, they are tracked in git
