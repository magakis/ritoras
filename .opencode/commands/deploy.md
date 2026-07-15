---
description: Deploy Ritoras to the connected iPhone via CI + SideStore
agent: adeline
---

# Deploy Command

Orchestrate the full Ritoras deploy pipeline: commit, push to GitHub, poll CI, download .ipa, serve to SideStore, and stream device logs: $ARGUMENTS

Pass `refresh` to skip commit and push — just download the latest CI artifact and re-install.

## Your Task

1. **Check prerequisites** — iPhone connected, deploy script exists, changes to deploy
2. **Commit changes** (skip if `refresh`) — stage and commit locally
3. **Push and build** (confirmation gate) — run the deploy script
4. **Trigger SideStore Install** — guide user to open the URL on iPhone
5. **Stream logs** — monitor device output for app start or crashes
6. **Report** — summarize everything

### Step 1: Check Prerequisites

1. **iPhone connection** — run `idevice_id -l`. If the output is empty, report error: `No iPhone detected. Connect the device and ensure usbmuxd is running on the host.`
   - Verify the connected UDID matches the expected device: `00008140-001A2D312688801C`
   - If unexpected UDID appears, flag it but proceed — the device may have been re-paired

2. **Deploy script** — verify `scripts/deploy-ipa.mjs` exists in the repo root

3. **Uncommitted changes** (skip if `refresh`) — run `git status --porcelain`:
   - If clean: inform the user `No changes to deploy. Use '/deploy refresh' to re-install the existing build.` and stop
   - If dirty: proceed to Step 2

### Step 2: Commit Changes (skip if `refresh`)

1. Show the user what will be committed — run `git diff --stat` and display the output
2. Stage everything — run `git add -A`
3. Commit — run `git commit -m "deploy: <description>"` where description comes from:
   - If the user passed extra words in `$ARGUMENTS` (e.g., `/deploy fix keyboard layout`), use those words
   - Otherwise use `"update"`
4. This is a LOCAL commit only — fully reversible. Do NOT push yet.

### Step 3: Push and Build (CONFIRMATION GATE)

This is the only confirmation gate. **Before pushing**, ask the user:

- **Tool**: `question` with message: `Ready to push to main and trigger CI build? This will deploy to your iPhone.`
- **Options**: `Push and deploy` / `Cancel`

If user selects `Push and deploy`:

- If `$ARGUMENTS` contains `refresh`: run `node scripts/deploy-ipa.mjs refresh`
- If NOT `refresh`: run `node scripts/deploy-ipa.mjs deploy`

The script handles everything:
- Push with PAT auth (reads token from `/home/michael/.config/opencode/gh-token`)
- Poll CI workflow run (15-minute timeout)
- Download `.ipa` artifact
- Start HTTP server on port 8765-8770
- Print install URLs
- Block until SideStore downloads the `.ipa` or 5-minute timeout

If the script exits with non-zero code, report the error and stop.

If user selects `Cancel`, stop and report: `Deploy cancelled.`

### Step 4: Trigger SideStore Install

After the script finishes (download detected or timeout):

1. Collect the install URLs printed by the script
2. Use the `question` tool:
   - **Message**: `📱 Open this URL on your iPhone Safari to install via SideStore: <url>. Press Enter when the install is complete.`
   - **Options**: `Install complete`
3. After the user confirms, proceed to log streaming

If the script timed out waiting for download (printed a warning), include the timeout notice in the question message so the user knows the server is still running.

### Step 5: Stream Logs

1. Run `idevicesyslog -m Ritoras -x` with a 120-second timeout
2. Monitor the output for:
   - App process starting (messages containing `Ritoras Keyboard` or `com.ritoras.app`)
   - Error messages or crashes
3. If no Ritoras-related logs appear after 30 seconds:
   - Remind the user: `If this is a first install, enable the keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → Ritoras. Then try typing in any app.`
   - Also suggest: `Launch the Ritoras container app to trigger initial setup.`
4. If crash logs appear (messages containing `Crash`, `Exception`, `SIGABRT`, `SIGSEGV`):
   - Run `idevicecrashreport -e -o /tmp/ritoras-crashlogs`
   - Note the crash file path for the report

### Step 6: Report

Summarize the deployment:

- **Build status**: success / failure
- **Artifact**: path and size
- **Install status**: confirmed by user
- **Log observations**: key lines, app start detected, errors found
- **Crash reports**: file paths if any extracted
- **Next steps**: any follow-up actions
