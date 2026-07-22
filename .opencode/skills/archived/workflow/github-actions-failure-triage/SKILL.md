---
name: "GitHub Actions Build Failure Triage"
description: "Apply when a GitHub Actions CI build fails for the Ritoras project — get the failed run URL, download and extract logs, find Swift compile errors with grep, apply minimal-diff fix, commit as NEW commit (do not amend), and re-run deploy. If not triaging a Ritoras CI failure, skip."
confidence: 0.9
domain: "workflow"
source: "session-extraction"
version: 1.0.0
created: "2026-07-18"
last_confirmed: "2026-07-18"
metadata:
  opencode:
    tags: [ci, github-actions, build-failure, swift, triage, ritoras]
    related_skills: [ritoras-deploy-pipeline, git-push-pat-auth]
---

# GitHub Actions Build Failure Triage

## When to Apply

Apply when a GitHub Actions CI build fails for the Ritoras project — the deploy script's `wait` phase reports failure, or you are notified that a CI run for a recent push did not complete successfully. If not triaging a Ritoras CI failure, skip.

## Overview

Ritoras CI builds on `macos-15` runners with Xcode 16.4 and the iPhoneOS 18.5 SDK. The build produces an unsigned `.ipa` (Release configuration) that is uploaded as a workflow artifact. Failures are almost always Swift compile errors. The triage process is: identify the failed run, download the build logs, locate the exact compile error, apply a minimal fix, commit as a new commit, and re-deploy. A key insight from this project: **CI is ground truth** for Swift compilation errors — reading code statically does not reliably catch scope/nesting issues.

## Action

1. **Get the failed run URL** for a specific commit:
   ```bash
   gh api repos/magakis/ritoras/actions/runs?head_sha=<SHA> \
     --jq '.workflow_runs[0] | {id, html_url, conclusion}'
   ```
   Or for the latest push to main:
   ```bash
   gh api repos/magakis/ritoras/actions/runs?event=push&branch=main \
     --jq '.workflow_runs[0] | {id, head_sha, conclusion, html_url}'
   ```
   Check both `status` (should be `completed`) and `conclusion` (should be `failure`). If `status` is `in_progress`, the build hasn't finished yet.

2. **Download and extract the logs:**
   ```bash
   RUN_ID=<the run id>
   gh api repos/magakis/ritoras/actions/runs/$RUN_ID/logs > /tmp/run-logs.zip
   cd /tmp && unzip -o run-logs.zip -d run-logs-$RUN_ID/
   ```

3. **Find the actual error** — build logs are split into per-job files inside the zip. The build job typically produces a file like `5_Build (unsigned, Release).txt`:
   ```bash
   grep -r "error:" /tmp/run-logs-$RUN_ID/ | head -20
   # For Swift specifically:
   grep -rE ":(error|warning):" /tmp/run-logs-$RUN_ID/ | head -20
   ```

4. **Read the specific file:line:column** cited in the error. Map the actual scope and structure of the code. Do NOT take any prior agent's claim about scope at face value.

5. **Apply a minimal-diff fix.** Use the build-fixer agent. A 24-second failure is a hard compile error (couldn't even start building). A 5+ minute failure is more likely a test failure or runtime issue.

6. **Commit as a NEW commit on top** — do NOT amend. Use a prose-style message explaining the root cause (e.g., "hoist Emoji Decodable structs to top-level scope").

7. **Re-run the deploy:** `node scripts/deploy-ipa.mjs deploy` — push the fix, wait for CI, download, serve.

## Common Pitfalls

- **DO NOT trust an agent's "verified the fix" claim when there's no compiler available.** In one session, a build-fixer removed `private` from a struct and reported "verified" by reading the code. CI failed with the identical error 24 seconds later because static reading doesn't catch scope/nesting issues. **CI is ground truth.**
- **For Swift nested-type errors:** "cannot find type X in scope" often means X is nested inside another type and referenced from a sibling scope. Removing `private` changes access level but NOT nesting. The fix is either (a) qualify the reference (`OuterType.InnerType`) or (b) hoist the type to top level. Option (b) is usually cleaner.
- **The failed-build log zip is named after the job, not the run.** Look for files like `5_Build (unsigned, Release).txt` inside the extracted directory. The number prefix indicates job order.
- **A "24-second failure" signals a hard compile error** (couldn't even start building). A "5+ minute failure" signals a test failure or runtime issue.
- **Check the run's `conclusion` field**, not just `status`. `status: completed` + `conclusion: failure` is the failure signal. `status: in_progress` means wait longer.
- **Broken commits on `origin/main` don't need to be reverted.** Just add a fix commit on top. Git history shows iteration; CI will rebuild on the fix.

## Evidence

- Session 2026-07-18 (commits 0bf1d34, da185eb): Two consecutive CI failures for Swift "cannot find type in scope" errors. The first fix attempt (removing `private`) failed because it didn't address the nesting issue. The second fix (hoisting the `Decodable` structs to top-level scope) resolved it.
- The failed build log filename was `5_Build (unsigned, Release).txt`. The error was a hard compile error (failed in ~24s).
- `grep -rE ":(error|warning):"` on the extracted logs was the reliable way to surface Swift compile errors.

## Verification Checklist

- [ ] `gh api .../actions/runs/<runId>` shows `conclusion: success` for the re-run
- [ ] Deploy script output shows `Build succeeded` and the run URL
- [ ] Downloaded artifact is non-zero size and valid `.ipa`
- [ ] `git log --oneline -3` shows the fix commit on top of the broken one
