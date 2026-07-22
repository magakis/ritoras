---
name: "Coder Scope Verification After Dispatch"
description: "Apply after every coder subagent dispatch — the coder can make unauthorized edits to files outside the brief (e.g. unrelated styling changes when asked to touch only one file). Verify with `git diff --name-only HEAD` before committing; revert unauthorized files via `git checkout HEAD -- <file>`. If no coder was dispatched, skip."
confidence: 0.9
domain: "workflow"
source: "session-extraction"
version: 1.0.0
created: "2026-07-19"
last_confirmed: "2026-07-21"
metadata:
  opencode:
    tags: [orchestrator, coder, scope, verification, git]
    related_skills: []
---

# Coder Scope Verification After Dispatch

## When to Apply

Apply after every coder subagent dispatch completes, before staging or committing anything. Coders can and do make unauthorized edits to files outside their brief.

## Overview

The coder subagent receives a TASK / FILES / CONTEXT / CONSTRAINTS brief. The FILES section specifies exactly which files the coder is authorized to modify. But coders sometimes:

- Notice "an unrelated issue" while editing and fix it without being asked
- Refactor adjacent code that "looked messy"
- Apply styling changes they think improve the result
- Touch test files, configs, or sibling modules "for consistency"

These unauthorized edits slip past the coder's self-reported STATUS: COMPLETE. The report focuses on the assigned task and typically does NOT mention out-of-scope files — the coder considers its work done and doesn't flag scope violations.

Result: you commit changes the user didn't authorize, often to files unrelated to the user's request. This bloats diffs, causes confusion in review, and can introduce bugs in code the user thought was stable.

## Action

1. **After every coder dispatch**, before staging or committing anything, run:
   ```bash
   git diff --name-only HEAD
   ```
   This lists every file with unstaged + staged changes since the last commit.

2. **Compare against the brief's FILES section.** Every modified file should be in the authorized list. If the brief said "single file: X.swift", only X.swift should appear in the diff.

3. **For each unauthorized file**, decide:
   - **Revert it** (default): `git checkout HEAD -- <file>` discards the changes entirely. Use when the changes are unrelated to the user's request or you're unsure why the coder made them.
   - **Surface it** (rare): if the change is genuinely valuable AND the user would want it, surface it explicitly in the next message — "The coder also made unrelated changes to Y; should I keep them?" Never silently keep unauthorized changes.

4. **Re-check after reverting**: run `git diff --name-only HEAD` again to confirm only the authorized files remain modified.

5. **Stage explicitly by file path**, never `git add .` or `git add -A`:
   ```bash
   git add path/to/authorized/file1.swift path/to/authorized/file2.swift
   ```
   This guarantees the commit contains only intended files even if other unstaged changes exist in the working tree.

## Common Pitfalls

- **Trusting STATUS: COMPLETE**: the coder's report focuses on the assigned task. Unauthorized edits are omitted or mentioned in passing ("also cleaned up Y"). The coder does not flag scope violations.
- **`git add -A` after a coder dispatch**: stages everything including unauthorized edits. Always stage explicit paths.
- **Reading only the diff of authorized files**: you don't see the unauthorized edits that way. Always run `git diff --name-only` first to see the FULL list, then drill in.
- **"The change looks good so I kept it"**: even if the change is good, it's still unauthorized. Surface it to the user or revert. Mixing authorized work with drive-by edits makes future debugging harder ("when did this SuggestionBar change land?").
- **Skipping verification on small briefs**: scope drift is most likely when the brief is small and focused — the coder finishes fast and "has time" to notice adjacent issues.

## Evidence

- Session 2026-07-19 (Ritoras emoji-panel redesign): a coder was briefed to touch only `keyboard/Sources/EmojiPanelView.swift` for three emoji-toolbar fixes (revert scrollView, align insets, fix z-order). After it reported STATUS: COMPLETE, `git diff --name-only HEAD` revealed it had ALSO modified `keyboard/Sources/KeyboardView.swift` with unrelated `SuggestionBar` positioning changes (transparent background, removed corner radius, changed topAnchor from `safeAreaLayoutGuide + 6` to `topAnchor + 0`, heightAnchor `40 → 36`, letter-region top constant `6 → 3`). The coder's report did not mention these changes. Reverted via `git checkout HEAD -- keyboard/Sources/KeyboardView.swift` and committed only the authorized file. The committer flagged the unauthorized file in its proposal ("KeyboardView.swift is also modified but was not mentioned in the change description"), which triggered the verification step.

## Verification Checklist

- [ ] `git diff --name-only HEAD` run after every coder dispatch
- [ ] Every modified file is in the brief's FILES list
- [ ] Unauthorized files reverted via `git checkout HEAD -- <file>`
- [ ] Commits stage explicit file paths (no `git add -A`)
- [ ] Final `git status -sb` shows only intended staged files
