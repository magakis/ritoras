# Prediction-rank client — implementer brief (Ritoras keyboard)

**Purpose of this document:** self-contained handoff for the agent implementing the keyboard-side consumer of the server's prediction slot. Read this top to bottom; it captures the live server contract, the behavioral requirements the plan has already committed to, the codebase integration points, and the verification gates. Deeper background (not required reading): `docs/LANGUAGE-INTELLIGENCE-RESEARCH.md`, `.opencode/plans/2026-10-23-prediction-slot-child.md`, and `/home/michael/whisper/server-v2/SLOTS.md`.

**Status of the server side:** DONE and LIVE. Deployed on czechpi at commit `54227b5` (2026-10-23), slot enabled, verified end-to-end. You are building only the client.

---

## 1. Mission

Add an async, never-blocking server ranking layer to the keyboard: after the instant local suggestions are computed and displayed (exactly as today), fire a request to the Pi which re-ranks the SAME candidate list with a Gemma-3-270M model (measured quality: intended word ranked first 20.5% vs the local stack's KenLM 11.0% top-1 on our eval). If a fresh, in-budget response arrives, re-order the suggestion bar; in every other case — server slow, cold, unreachable, non-EN, disabled, error — behavior must be **byte-identical to today**. This is an enhancement layer, not a replacement: the on-device prediction stack stays fully intact and untouched (its deletion is a later, separate phase after device-proven acceptance).

## 2. The live endpoint

`POST {serverBaseUrl}/slots/prediction/rank`

- **Auth:** Bearer API key — the SAME key and base-URL plumbing the dictation client already uses (reuse `shared/WhisperClient`'s server selection/auth configuration; do not invent a second config path).
- **Request body:**

```json
{
  "context": "last ~2-3 words of text before the cursor (≤512 chars, required)",
  "candidates": ["park", "party", "..."],   // 1–16 strings, required — the locally-generated candidate pool
  "word_in_progress": "par",                 // optional, string
  "language": "en"                           // optional, defaults to "en"
}
```

- **Response (200):**

```json
{
  "candidates": [{"candidate": "cafe", "score": 0.31}, {"candidate": "park", "score": 0.27}],
  "engine_id": "gemma",
  "scoring_duration_ms": 3.3
}
```

- **Errors:** `401` no/bad key · `422` non-EN language or invalid payload (0 or 17+ candidates, context >512 chars) · `503` slot disabled or engine error (with a structured `detail.status`). **Treat every non-200 exactly like unreachable: silently keep local ordering.** Other configured servers (if more than one) do not have this endpoint — a `404` there is a normal miss, never an error worth surfacing.
- **Live latency profile (measured 2026-10-23 over VPN):** warm ≈ **3 ms server + ~150 ms round-trip**; cold (model not loaded / idle-evicted) ≈ **1.3–1.5 s**. Recommended client timeout: **≤500 ms** — do not wait for cold; the next keystroke re-fires anyway.
- **Cache semantics you should know:** the server keeps a bounded prefix-state cache keyed on the EXACT context string. Contexts that change every keystroke will miss (cold-ish path). Fire on word boundaries with a stable `context` and put the changing fragment in `word_in_progress` — that hits the cache by design.
- **EN only in v1.** Greek must not call the slot (guard on the active `KeyboardLanguage`; local-only for EL).

## 3. Hard behavioral requirements (already committed to in the approved plan)

1. **Never block typing.** The request fires only after local suggestions are displayed; key handling, autocorrect, and dictation never await it. Single in-flight request, superseded by newer input; at most one outstanding call at any time.
2. **Freshness-only application.** Apply a server ranking only if the response is still current when it arrives — reuse the existing staleness guards (suggestion epoch + display-context token in `KeyboardView`/`SuggestionCache` interplay). A late answer is dropped, never queued.
3. **Kill-switch, default OFF.** New `SharedConfig.Defaults` flag (naming convention like `chunkFinalMergeEnabled` / `symspellMappedIndexEnabled`), e.g. `serverPredictionRankEnabled`, default `false`. The feature ships dark; enabling is a user setting flip. Zero behavior change when the flag is off — ideally zero network attempts.
4. **EN-only gating + flag gating checked before every fire**, cheaply, on the hot path (no string building; see logging below).
5. **Zero degradation guarantee:** with the flag ON and the server unreachable, suggestions and autocorrect must behave exactly as today (verify this explicitly — it's a device-session acceptance item).
6. **No changes to the local prediction path.** `PredictionEngine`, `SharedPredictionStack`, `SuggestionCache`, providers, autocorrect machinery: read/observe only. The server layer re-orders the display list; it must not feed back into autocorrect decisions in v1.
7. **48 MB Jetsam cap:** no new resident memory beyond tiny request/response state (a few KB). No new resources, no model data, no caches on disk. The existing MemoryMonitor conventions apply; reason about footprint in the PR description.
8. **Pure logic goes to the JS mirror, same commit.** Any new pure decision logic (apply/stale policy, coalescing rules, candidate-list shaping, response-validation rules) gets a mirror module + tests under `scripts/prediction-sim/` (lib + test, `node --test`). This is the repo's official pure-logic test surface; Swift XCTest is forbidden.
9. **Logging per `docs/LOGGING.md`:** component `.network`/`.prediction`; first-attempt errors `.debug`, exhausted/consistent failures `.warn`, no lifecycle spam, NO string construction on the hot path (build log strings only when actually logging).
10. **UI:** suggestion-bar re-order only, using the existing bar mechanics (`.suggestionTap` origin semantics must be preserved for tapped server-suggested words so they aren't autocorrected afterwards). No new UI surfaces in v1.

## 4. Codebase integration points (verified this session)

- **Server plumbing to reuse:** `shared/WhisperClient.swift` / `WhisperStreamClient.swift` — base URL selection, Bearer auth, timeout handling. The app may have multiple configured servers (see multi-server selection work); the prediction client rides whatever server is selected/pinned for dictation and must tolerate servers without the slot (404 → silent local).
- **Fire site:** where local suggestions settle after edits — `keyboard/Sources/Prediction/PredictionEngine.swift` outputs via `SharedPredictionStack`; the display/token guards live around `SuggestionCache` + `KeyboardView.swift` (suggestion bar, epoch-guarded apply path around lines 736–745).
- **Config:** `shared/Config.swift` (`SharedConfig.Defaults` pattern, keys + clamps).
- **Candidate list source:** the same candidate pool the engine already produces (cap at 16 for the wire; the draw should include the locally-top suggestions — they're what the user would see anyway).
- **New files:** anything under `keyboard/Sources/`, `app/Sources/`, `shared/` auto-includes via XcodeGen globs — never edit `Ritoras.xcodeproj` or `project.yml` just to add a source file.
- **Device constraints:** keyboard extension has `RequestsOpenAccess=true` (Full Access already required by dictation) — network from the keyboard is permitted, same as the dictation polling precedent.

## 5. Repo rules that bind you (from AGENTS.md — non-negotiable)

- Linux-only dev: no Xcode, no `xcodebuild`, no simulator. CI on push (`macos-15`) is the ONLY compile gate — type errors surface there, so be conservative with Swift API usage.
- Mandatory pre-commit gate for any `.swift` change: `node scripts/parse-check.mjs` (exit 0 or fix, don't commit).
- The orchestrator runs command gates (coders don't execute); no build-fixer subagent exists for this repo.
- Prose-style commits (`keyboard: …`, `shared: …`), body for non-trivial changes, wrapped at 75 cols. ff-only merges to main; never force-push.
- No XCTest targets, no new test targets in `project.yml`.
- Device verification uses the `ritoras-ios-debugging` skill (libimobiledevice/pymobiledevice3) — that's a user-gated session at the END, not during development.

## 6. Verification checklist (definition of done)

- [ ] `node scripts/parse-check.mjs` clean (full sweep)
- [ ] `node --test 'scripts/prediction-sim/test/**/*.{js,cjs,mjs}'` green including new mirror tests
- [ ] CI green on push (the only compile gate)
- [ ] Flag-off: zero network traffic, zero diff in suggestion behavior
- [ ] Flag-on, server reachable: server rankings applied only when fresh; suggestion bar re-orders; taps on server-ranked words behave like local taps
- [ ] Flag-on, server unreachable / VPN dropped: byte-identical to today, zero typing block, no error surfaces
- [ ] Device session (user gate — schedule with the user): the above live on hardware + MemoryMonitor `phys_footprint` within the 48 MB cap across a typing session; artifacts logged per the skill
- [ ] PR description documents Jetsam reasoning and the kill-switch name

## 7. Boundaries / non-goals (do not do these)

- Do NOT delete, disable, or refactor the on-device prediction stack (that is Phase 10, only after this layer is device-proven).
- Do NOT send Greek contexts to the slot (422 by contract; gate locally instead).
- Do NOT implement free-form generation, completion streaming, or top-k fetching — v1 re-ranks client-supplied candidates only.
- Do NOT add server discovery/health-polling for the prediction slot — one attempt per eligible word boundary, silent fallback on any miss.
- Do NOT touch the whisper server repo; the endpoint is finished and live. If the contract seems wrong, re-read §2, then check `/home/michael/whisper/server-v2/SLOTS.md` — if it genuinely needs a server change, STOP and escalate; do not work around it client-side.

## 8. Quick reference

- Live sample (from the 2026-10-23 deploy verification): `{"context": "I will see you at the", "candidates": ["park","party","store","meeting","house","beach","office","school","concert","gym","station","cafe","market","library","hotel","mall"], "language": "en"}` → ranked `cafe, park, library, concert, store, …` (200 OK, warm 3.3 ms server-side).
- Capability probe (optional, not required): `GET /slots` with key returns the slot catalog; prediction shows `"ready"` with occupant `gemma` on czechpi.
- Server-side context: `engine_id` tells you which engine answered (always `gemma` on the Pi today; a future config could make it `kenlm` — the client treats them identically).
