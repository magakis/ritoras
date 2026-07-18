---
name: "Ritoras iOS Deploy Pipeline"
description: "Use when shipping a change to the Ritoras iOS keyboard to a device — covers commit (prose-style messages, partial-staging support), deploy (push + CI wait + artifact download + HTTP serve for SideStore), diagnose CI build failures (extract logs, locate Swift errors, fix, redeploy), and re-deploy. Full commit-to-device cycle. Use ONLY for Ritoras."
confidence: 0.9
domain: "automation"
source: "session-extraction"
version: 1.0.0
created: "2026-07-18"
last_confirmed: "2026-07-18"
metadata:
  opencode:
    tags: [ios, keyboard, deploy, ipa, ci, sidestore, github-actions, swift, triage, commit]
    related_skills: [git-push-pat-sandbox, node-server-teardown, sandbox-detach-process]
---

# Ritoras iOS Deploy Pipeline

## When to Apply

Apply when shipping a change to the Ritoras iOS keyboard to a device — this skill covers the full end-to-end commit-to-serve workflow: committing changes (prose-style messages, partial-staging support), deploying via `scripts/deploy-ipa.mjs deploy` (push + CI wait + artifact download + HTTP serve for SideStore), diagnosing CI build failures (extracting logs, locating Swift compile errors, applying minimal fixes), and re-deploying. If not working on Ritoras, skip.

## Overview

The Ritoras deploy pipeline is a zero-dependency Node.js script (`scripts/deploy-ipa.mjs`) that orchestrates the full CI/CD cycle. It avoids storing credentials on the agent machine by using a temporary git credential helper from `/home/michael/.config/opencode/gh-token`. The unsigned `.ipa` is built by GitHub Actions on `macos-15` runners (Xcode 16.4, iPhoneOS 18.5 SDK, XcodeGen project generation). The built `.ipa` is served via a local HTTP server that SideStore's custom-scheme handler (`sidestore://install?url=...`) uses for on-device signing and installation. Builds persist locally at `~/.local/share/ritoras/builds/<runId>/` with `meta.json` (run number, SHA, commit message, size), enabling rollback if the latest CI run fails. The project uses prose-style commit messages (lowercase imperative summary, no prefix tags like `fix:`/`feat:`) and XcodeGen auto-includes new `.swift` files in `keyboard/` without editing `project.yml`.

## Action

### Phase 1 — Commit (Prose-Style, Partial Staging When Needed)

1. **Dispatch the committer agent** with a brief asking for a numbered commit plan. Say: "Please propose a numbered commit plan (don't execute yet)." The committer will run `git status`, `git diff --stat`, and `git log --oneline -10` to assess the changes.

2. **Present the committer's plan verbatim** to the user. Do NOT summarize or interpret it.

3. **Ask the user** which commits to create: "All / specific numbers / Cancel."

4. **Re-dispatch the committer** with execution instructions matching the user's choice.

5. **Verify afterwards** — the committer often returns empty output even when commits succeed. Always check:
   ```bash
   git log --oneline -5
   git status -sb
   ```

**Partial staging across commits:** When two planned commits both touch the same file with interleaved hunks, try `git diff > /tmp/file.patch`, manually edit the patch to keep only the relevant hunks, then `git apply --cached /tmp/file.patch`. If hunks are too interleaved, **combine into one commit** with a message mentioning both concerns.

**Commit message convention:** Prose-style, multi-paragraph explaining WHY not just WHAT. Lowercase imperative summary line (e.g., "fix EmojiDataFile scope to unbreak CI build"). No prefix tags like `fix:`, `feat:`, `chore:`.

### Phase 2 — Deploy (One-Command Push + CI + Download + Serve)

Do NOT push directly from git — the deploy script handles credentials.

1. **Run deploy** (15+ minutes):
   ```bash
   mkdir -p /tmp/ritoras-deploy-logs
   LOG=/tmp/ritoras-deploy-logs/deploy-$(date +%Y%m%d-%H%M%S).log
   nohup node scripts/deploy-ipa.mjs deploy > "$LOG" 2>&1 &
   ```
   Poll every 30s for markers: `Pushed`, `in_progress`, `success`, `Downloaded`, `Serving`, `sidestore://`, `error`, `BUILD FAILED`.

2. **Inside `deploy`, the script does:**
   - **Push:** Creates a temporary git credential helper at `/tmp/git-credential-helper-*.sh` from the token at `/home/michael/.config/opencode/gh-token`, pushes `main` to `origin` (`REPO = 'magakis/ritoras'`), and cleans up in a `finally` block.
   - **Wait:** Polls the GitHub Actions API in two stages — first for the workflow run to appear (every 10s), then for completion (every 15s). Timeout: 15 minutes total.
   - **Download:** On CI success, fetches the `Ritoras.ipa` artifact via the GitHub Artifacts API, extracts via `python3`, stores the `.ipa` + `meta.json` at `~/.local/share/ritoras/builds/<runId>/`. Retention capped at `RITORAS_KEEP_BUILDS` (default 10).
   - **Serve:** Starts an HTTP server on the first free port in range 8765–8770, listens on `0.0.0.0`. Prints install URL:
     ```
     sidestore://install?url=http://<ip>:<port>/v/<runId>/Ritoras.ipa
     ```

3. **Present the URL to the user.** Tailscale IP (`100.x.x.x`) preferred (works anywhere); LAN IP as fallback. User opens in iPhone Safari to trigger SideStore.

### Phase 3 — Diagnose CI Failures

When the `wait` phase reports failure or you are notified of a failed CI run:

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

3. **Find the actual error** — build logs are split into per-job files. The build job produces a file like `5_Build (unsigned, Release).txt`:
   ```bash
   grep -r "error:" /tmp/run-logs-$RUN_ID/ | head -20
   # For Swift specifically:
   grep -rE ":(error|warning):" /tmp/run-logs-$RUN_ID/ | head -20
   ```

4. **Read the specific file:line:column** cited in the error. Map the actual scope and structure of the code. Do NOT take any prior agent's claim about scope at face value.

### Phase 4 — Fix and Redeploy

1. **Apply a minimal-diff fix.** A 24-second failure is a hard compile error (couldn't even start building). A 5+ minute failure is more likely a test failure or runtime issue.

2. **Commit as a NEW commit on top** — do NOT amend. Use a prose-style message explaining the root cause (e.g., "hoist Emoji Decodable structs to top-level scope").

3. **Re-run deploy:** `node scripts/deploy-ipa.mjs deploy` — push the fix, wait for CI, download, serve.

### Subcommands Reference

When the full `deploy` command isn't appropriate, use these standalone subcommands:

| Subcommand | Action |
|---|---|
| `push` | Push to GitHub (triggers CI but doesn't wait) |
| `wait [sha]` | Wait for an in-progress CI run for a specific commit |
| `download [runId]` | Download latest or specific artifact |
| `refresh` | Re-download latest artifact + serve |
| `serve` | Serve existing local builds (no push, no CI) |
| `list` | List locally-stored builds |
| `list-remote [n]` | List last n successful CI runs |
| `prune` | Remove old builds beyond KEEP_BUILDS |

### Key Constants

| Constant | Value |
|---|---|
| `REPO` | `magakis/ritoras` |
| `BRANCH` | `main` |
| `ARTIFACT_NAME` | `Ritoras.ipa` |
| `TOKEN_PATH` | `/home/michael/.config/opencode/gh-token` |
| `BUILDS_DIR` | `~/.local/share/ritoras/builds` (override: `RITORAS_BUILDS_DIR`) |
| `KEEP_BUILDS` | 10 (override: `RITORAS_KEEP_BUILDS`) |
| `SERVE_WINDOW` | 15 min (override: `RITORAS_SERVE_MIN`) |
| CI runner | `macos-15`, Xcode 16.4, iPhoneOS 18.5 SDK |

## Common Pitfalls

### Phase 1 (Commit)
- **Committer returns empty output even when commits succeed.** Do NOT interpret empty output as failure. Always verify with `git log --oneline -5` and `git status -sb`.
- **XcodeGen auto-includes** — new `.swift` files and bundled resources in `keyboard/` are automatically picked up because `project.yml` has a recursive glob. No need to edit `project.yml`.
- **Patch-file splitting is brittle** when hunks are interleaved (same function modified for different purposes). Combining commits with a compound message is safer.
- **Generated files** (like `emojis.json`) committed to the repo WILL be picked up by XcodeGen. Make sure they're tracked in git so CI builds match local builds.

### Phase 2 (Deploy)
- **Do NOT push separately from `deploy`.** The deploy script's `push` subcommand creates a git credential helper using the GitHub token; pushing manually would either fail (no creds in agent env) or conflict with the deploy script's expectations.
- **`deploy` is long-running (15+ min).** Always launch in background with log redirection. Poll the log for progress markers rather than blocking the agent.
- **The HTTP server auto-shuts after 15 minutes** (configurable via `RITORAS_SERVE_MIN`). User must install before then, or re-run `node scripts/deploy-ipa.mjs serve` for a fresh window (no re-push needed).
- **Do NOT kill the server process** once it's up — SideStore needs it alive to download the .ipa.
- **Previous successful builds persist** at `~/.local/share/ritoras/builds/<runId>/`. If the latest CI fails, you can `serve` the previous build as rollback without re-pushing.
- **If a skill named `automation/ios-device-deploy` is listed in `available_skills` but cannot be loaded**, proceed anyway — this brief is self-contained.

### Phase 3–4 (Diagnose & Fix)
- **DO NOT trust an agent's "verified the fix" claim when there's no compiler available.** Static code reading does NOT catch scope/nesting issues. **CI is ground truth.**
- **For Swift nested-type errors:** "cannot find type X in scope" often means X is nested inside another type and referenced from a sibling scope. Removing `private` changes access level but NOT nesting. The fix is either (a) qualify the reference (`OuterType.InnerType`) or (b) hoist the type to top level. Option (b) is usually cleaner.
- **The failed-build log zip is named after the job, not the run.** Look for files like `5_Build (unsigned, Release).txt` inside the extracted directory. The number prefix indicates job order.
- **A "24-second failure" signals a hard compile error** (couldn't even start building). A "5+ minute failure" signals a test failure or runtime issue.
- **Check the run's `conclusion` field**, not just `status`. `status: completed` + `conclusion: failure` is the failure signal. `status: in_progress` means wait longer.
- **Broken commits on `origin/main` don't need to be reverted or amended.** Just add a fix commit on top. Git history shows iteration; CI will rebuild on the fix.

## Evidence

- Session 2026-07-18 (commits bfcf20e through da185eb): Full commit-to-serve cycle exercised multiple times for the emoji-picker feature. The `deploy-ipa.mjs` script was the sole deploy path throughout.
- Two consecutive CI failures (0bf1d34, da185eb) for Swift "cannot find type in scope" errors. First fix (removing `private`) failed because it didn't address nesting. Second fix (hoisting `Decodable` structs to top-level scope) resolved it.
- `scripts/deploy-ipa.mjs` contains the full implementation (795 lines): `push()`, `wait()`, `download()`, `serve()`, `deploy()`, `refresh()`, `list()`, `listRemote()`, `prune()`.
- `.github/workflows/build.yml` builds on `macos-15` with Xcode 16.4, runs XcodeGen, builds unsigned Release, packages as `.ipa`, uploads as artifact. CI build takes ~5-10 min once the runner starts. Artifact is ~3.1 MB.
- `git log --oneline -20` shows the prose-style convention in every commit. `project.yml` confirms recursive glob for `keyboard/`.

## Verification Checklist

- [ ] `git log --oneline -5` shows the expected commit(s)
- [ ] `git status -sb` shows a clean working tree
- [ ] Commit messages follow prose style (no `fix:`/`feat:` prefixes)
- [ ] Deploy log shows `Pushed`, then `Found workflow run`, then `success`
- [ ] Deploy log shows `Downloaded` and `Serving`
- [ ] `curl -s http://localhost:<port>/` returns an HTML page with install buttons
- [ ] Tailscale IP URL works from iPhone Safari
- [ ] User reports successful SideStore install
- [ ] If CI failed: `gh api .../actions/runs/<runId>` shows `conclusion: success` for re-run
