# Baseline diagnosis: 2026-10-24 12:46:19 session

## Provenance and replay status

- Session ID: `20261024-124619`
- Telemetry job ID: `C71C1494-3A06-4B32-95D4-EA8254DCFBC2`
- Recording start: `2026-10-24T10:46:15Z` (`Europe/Athens`)
- Read-only source: `czechpi:whisper/benchmark/recordings/ritoras/20261024-124619/client_telemetry.json`
- Archived original: `client_telemetry.json` (schema version 2)
- Replay input: `session.jsonl` (119 frames, original 1900 ms endpoint override)
- Swift source reviewed at current worktree HEAD:
  `d93fa62b699c3de0a5fe7e11a3da0384428e3d42`

This is a diagnosis of the recorded fields and current Swift source, not a
claim that the JS baseline replay has passed. Run the separate
`VERIFICATION.md` runbook before using replay parity as evidence for Phase 2.

## Recorded no-latch onset

The first emitted segment ends at `s1=2679.5 ms`. The second soft phrase is
visible in frames 50–55 while the endpoint remains idle. The encoded `q` is
the frame sequence number; frame-start times below are cumulative `dt` before
that frame.

| Frame | Start (ms) | `db` | `ct` | `db-ct` | `dy` | `fl` | `fc` | `lr` | `ls` (ms) | `ll` | `e` / `ps` / `d` |
|---:|---:|---:|---:|---:|---:|:---:|:---:|:---:|---:|:---:|:---|
| 50 | 4991.312 | -30.534 | -33.430 | +2.896 | 8.132 | -36.430 | true | true | 108.000 | false | continuing / idle / none |
| 51 | 5099.312 | -32.837 | -33.865 | +1.028 | 7.884 | -36.865 | true | true | 193.313 | false | continuing / idle / none |
| 52 | 5184.625 | -32.489 | -34.109 | +1.620 | 7.636 | -37.109 | true | true | 301.313 | false | continuing / idle / none |
| 53 | 5292.625 | -37.849 | -34.315 | -3.534 | 7.604 | -37.315 | true | true | 0 | false | silence / idle / none |
| 54 | 5377.937 | -38.398 | -34.444 | -3.954 | 7.818 | -37.444 | true | true | 0 | false | silence / idle / none |
| 55 | 5485.937 | -32.368 | -34.621 | +2.253 | 5.962 | -37.621 | true | true | 108.000 | false | continuing / idle / none |

The span from frame 50's start to frame 55's start is about 495 ms, but it is
not one sustained-continuing streak: frames 53–54 are silence and reset the
streak. The actual longest idle continuing run is frames 50–52, 301.313 ms;
frame 55 starts a separate 108 ms run.

## Which latch conditions failed

`shared/StreamingAudioRecorder.swift` currently requires a converged adaptive
floor and an eligible idle continuing frame before it can promote the latch
(around lines 624–703). The quiet-floor branch requires `quietRegimeEvidence`,
stable floor movement (at most +2 dB from the streak-start floor), and
`sustainedContinuingOnsetSeconds = 1.0` seconds. The loud-regime branch
requires `loudLatchMs = 400` ms plus a dynamics witness (`loudLatchWitnessDb`
is 3 dB in the recorded config).

- **Not a convergence veto:** `fc=true` on frames 50–55. They are adaptive
  (`fl` is present), idle (`ps=idle`), and eligible (`e=continuing`) on frames
  50–52 and 55.
- **Quiet-floor time requirement fails:** frames 50–52 reach only
  `ls=301.313 ms`, below 1000 ms; frame 55 reaches only 108 ms after the
  silence reset. `ll=false` and `d=none` throughout.
- **The direct `ct+3 dB` witness is below threshold, but quiet evidence still
  qualifies through dispersion:** `db-ct` is +2.896, +1.028, +1.620, and
  +2.253 dB on frames 50, 51, 52, and 55 respectively. However, the current
  Swift quiet-evidence condition is an OR: `dy >= effectiveFlatSpreadDb` **or**
  `db >= ct+3`. The configured flat-spread threshold is 5 dB, and each of
  those frames has `dy >= 5` (7.636–8.132 dB for frames 50–52; 5.962 dB for
  frame 55). Therefore the quiet-evidence condition passes via dispersion;
  it is inaccurate to diagnose the `ct+3` shortfall as a failed overall
  quiet-evidence gate.
- **Quiet floor stability passes:** across frames 50–52, `fl` moves from
  -36.430 to -37.109 dB (current minus streak-start is -0.678 dB, within the
  Swift `<= 2 dB` limit). Frame 55 is its own one-frame streak.
- **Loud-regime time requirement also fails:** `lr=true`; the dynamics witness
  exceeds the configured 3 dB witness, but the longest contiguous run is
  301.313 ms, below `loudLatchMs=400`. Frame 55 is only 108 ms. The floor is
  below the -35 dB regime boundary on frames 50–55, while `lr=true` selects
  the current loud-latch branch as well.

The next onset is frame 56: it begins at 5593.937 ms, has `db=-29.116 dB`,
`th=-30.758 dB`, `e=strong`, and `d=start_utterance`. That ordinary strong
frame starts the utterance after the soft frames have already been discarded.

## Why the floor remains high after the first segment

At frame 50 the retained floor is `fl=-36.430 dB`, making the recorded strong
threshold `th=-29.430 dB`. Relative to the first segment boundary
`s1=2679.5 ms`, frame 50 starts 2311.812 ms later. The floor remains in the
roughly -36 to -38 dB range through the soft onset: frame 55 starts 2806.437
ms after that boundary with `fl=-37.621 dB`. Thus the exact -36.430 value is
frame 50 (about 2.31 seconds after the recorded chunk boundary), not exactly
three seconds later.

The stale-floor re-anchor does not get a 1.5-second evidence-free run. In
`shared/VADGate.swift` (around lines 403–426), silence evidence resets
`elapsedSinceSilenceEvidence` to zero; the idle stale re-anchor is considered
only after that timer reaches `staleFloorSeconds=1.5`. After the first endpoint
finalize at frame 41, the next continuing/ambiguous evidence lasts only frames
42–43 before silence at frame 44 resets the timer. Later, the 301 ms continuing
run at frames 50–52 is followed by silence at frames 53–54, resetting it again.

`noteUtteranceEnded` in `shared/VADGate.swift` (around lines 327–343) may update
the speech ceiling when its guard passes, then calls `resetAdaptiveRollingWindow`.
That reset (around lines 798–803) clears rolling-window indices, elapsed time,
and percentile cache; it does not re-seed or clear `floorDb`. Consequently the
stale floor value survives finalize, and the silence-reset timer prevents the
post-finalize stale re-anchor from replacing it before the next phrase.

## Phase 2 guardrail

Do not treat the `ct+3 dB` alternative or `floorConverged` as this session's
failing gate: dispersion already satisfies the current quiet-evidence OR, and
`fc` is true. The recorded blockers are insufficient contiguous latch time
(301.313 ms maximum, then a silence reset) and the retained floor path above.
At the time of this baseline diagnosis, no Phase 2 behavior was changed.

## FIX-NOTES: post-finalize soft-latch blackout

The previous static reasoning that frames 44-45 would remain ambiguous was
falsified by the fixed replay: frame 45 opened an utterance at 4496.6875 ms
with `e=continuing` and `db=-34.580 dB`. The re-seeded floor changed the actual
classification, so evidence-class reasoning alone did not protect the
post-finalize noise bump.

The fix now starts a fixed 700 ms soft-latch suppression window at
`finalize_endpoint`. During that window it clears the continuing-streak/latch
state and prevents continuing or ambiguous evidence from being promoted to
endpoint-strong. It does **not** suppress normal strong evidence: a frame that
is `.strong` through the ordinary VAD path still reaches the endpoint. The
quiet-floor evidence OR, its 300 ms dwell, and the 900 ms pre-roll are otherwise
unchanged; the legacy-loud dwell remains 1.5 seconds. Additionally, the
quiet-floor latch now requires the floor to be flat or falling across its
streak; any positive rise rejects that streak. This prevents a fast 300 ms
latch while adaptive P10 is still chasing upward ambient energy. It also
requires a rise from the preceding frame of at least the existing flat-spread
threshold (5 dB in this fixture) within the active quiet-latch window;
dispersion alone is not an onset-direction witness. The edge may occur on the
current frame or the immediately preceding idle, non-silence frame. Once
consumed by a continuing streak, the witness stays with that streak (including
the JS-only `quietLatchWitnessEnabled` candidate's existing `quietLatchMs`
window); a silence or a broken standard quiet streak clears it.

Frame 41 ends at 4195.375 ms. The 700 ms blackout therefore covers frame starts
42-49 (4195.375-4883.312 ms for frames 42-48; frame 49 starts at 4883.312 ms,
with about 12 ms of blackout remaining). This blocks the empirically observed
frame-45 start regardless of its re-seeded-floor classification, and prevents
the decaying tail from carrying a partially accumulated latch into the next
frame. Frame 50 starts at 4991.312 ms, about 796 ms after finalize, after the
blackout has expired.

The target onset is distinguished by its large rising edge from frame 49 to
frame 50: `db` rises from -36.805 to -30.534 dB (+6.271 dB). Frames 50-52 then
provide the needed continuing streak; their recorded dispersion values are
8.132, 7.884, and 7.636 dB, above the unchanged 5 dB quality threshold. The
300 ms latch can therefore promote the real soft onset on frame 52 (start
about 5184.625 ms, within one recorded frame of the requested onset window).
The floor estimate at the end of frame 41 is approximately -34.167 dB
(`th=-27.167` with a 7 dB delta); the 4 dB re-seed cap gives an initial floor
no lower than approximately -38.167 dB. At frame 52's start (5184.625 ms),
989.25 ms of idle audio has elapsed since frame 41 ended, leaving about 211 ms
of the 1.2 s idle-only rise hold. Frames 50-52 are therefore flat or downward
relative to frame 50's floor and pass the new non-rising-floor gate; after the
endpoint starts, floor updates are non-idle and cannot rise. The q49→q50
+6.271 dB edge also exceeds the existing 5 dB onset witness. The intended latch
still matures after their 301.3125 ms streak.
The blackout trades away soft/continuing-only turn-taking in the first 700 ms
after finalize; normal strong onsets remain available during that interval.

The quiet-floor gates also protect the no-latch pre-onset corpus. Its first
301.3125 ms continuing run is q=12-14 at 1.1822-1.4836 s
(`db=-28.950, -29.007, -27.624 dB`); the 300 ms dwell alone previously
promoted q=14. The rolling P10 rises from -35.343 dB at q11 to -35.070 dB at
q14, so the non-rising-floor condition rejects that pre-onset run. Later exact
301 ms runs are rejected by the edge witness: q56 starts with only +2.567 dB
from q55, and q97/q98 rise only +1.261/+3.189 dB from q96/q97. The recorded
evidence counts and pre-baseline no-start assertion therefore remain pinned.

The ambiguous-interruption re-onset case retains its initial +5 dB edge from
the -50 dB prefill to its first -45 dB ambiguous frame. The following three
-43 dB continuing frames provide 300 ms on a non-rising floor, so the edge is
still fresh at latch time. In the pre-roll test's JS-only witness mode, the
edge window follows its existing 1000 ms `quietLatchMs`; its ten continuing
frames therefore still latch after the configured duty-cycle window. Later
ambiguous frames are handled by the endpoint's speech-like silence reset and
do not suppress that initial fallback onset.

If `noteUtteranceEnded` has an already validated `speechCeilingDb`, the floor
re-seed is skipped. In the N5 ambient-wedge guard, lowering its -50 dB floor by
4 dB would turn the existing `floor+7 dB` ambient probe into raw strong
evidence, bypassing any soft-latch blackout. The ceiling-anchored floor is kept
instead. This fixture has no accepted ceiling: its quietest strong frame
(-33.519 dB) does not clear the frame-41 floor (-34.167 dB) by the required
strong-delta-plus-margin headroom, so its trailing-silence re-seed still runs.

The 4 dB floor-drop cap and 1.2 s upward-floor hold remain as defenses against
floor contamination. The fixture's captured `endpointSilenceMs=1900` and
`silenceMs=1900` semantics are unchanged. The regression explicitly rejects
any start whose frame start is within 4200-4950 ms, in addition to requiring
the soft start and chunk-1 boundary at or before 4950 ms.
