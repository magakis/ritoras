# Language Intelligence Migration — Research Compendium

**Date:** 2026-10-22 · **Status:** research complete, implementation plan to follow
**Scope:** moving Ritoras's on-device dictation grammar / vocabulary / error-correction / prediction onto the self-hosted Whisper server (`~/whisper/server-v2`) as decoupled, swappable model slots.
**Provenance:** five parallel investigations (app-side explorer, server-side explorer, three web researchers). This document is the durable record — consult it before re-researching any question below.

---

## 1. Objective and architectural decisions

**Goal:** remove on-device language intelligence from the iOS app/keyboard and serve it from the Whisper server over VPN, keeping the best available model per capability.

Decisions made by the user (2026-10-22):

- **D1 — Decoupled best-in-slot model slots.** ASR, spelling correction, grammar correction, vocabulary, and prediction are completely separate projects under one umbrella. Each slot gets the best model available for it on Pi-class hardware, independently downloaded and swappable when something better appears. ("If a 3rd model is better for vocabulary, we download and use that one there.")
- **D2 — VPN-secured transport.** Phone↔server runs over VPN; security/privacy of the link is considered solved. Remaining constraints are latency and reachability only.
- **D3 — Benchmark-first gating.** Before committing to any slot design, run the candidate models on the actual Raspberry Pi and collect real quality + speed numbers. No slot choice is final until measured.
- **D4 — Sequential deep-dives.** After benchmarks, improve one keyboard aspect at a time, one after the other — not in parallel.
- **D5 — ASR is not the vocab mechanism.** Parakeet vs Whisper was never about ASR quality; it was about vocab-biasing mechanics (hotwords exist only in faster-whisper). Under D1 that concern disappears — vocabulary gets its own slot.

**Primary motivation (from app-side findings + project memory):** the keyboard extension runs at ~90 MB+ `phys_footprint` against a hard 48 MB Jetsam cap. The on-device prediction stack (SymSpell blobs, KenLM, trie, wordlists ≈ 24 MB of resources, ~25 MB resident SymSpell in fallback mode) is the main offender.

---

## 2. Current state — iOS app (Ritoras worktree)

### 2.1 Keyboard prediction/autocorrect stack (keyboard-only, ~24 MB resources)

| Module | ~LoC | Role |
|---|---:|---|
| `keyboard/Sources/Prediction/PredictionEngine.swift` | 379 | Fuses provider candidates; Apple boost ×1.2 when best SymSpell <0.7; KenLM min-max normalization, final = `(1-α)·provider + α·kenLM`, α=0.5; two-tier correction thresholds 0.65 (fused) / 0.70 (unfused); KenLM floor −8.0 |
| `SharedPredictionStack.swift` | 576 | Process-global lazy stack, language switching, mapped-vs-in-memory SymSpell selection, memory-pressure degraded paths |
| `SuggestionProvider.swift` / `SuggestionCache.swift` | 39 / 129 | Provider protocol + 3-entry LRU |
| `Trie.swift` / `WordListLoader.swift` | 92 / 211 | Prefix completion + membership; streams frequency dicts into SymSpell/Trie with phys_footprint checks |
| `CurrentWordExtractor.swift` | 117 | Token around cursor + 2 preceding words; mid-word/apostrophe/punctuation handling |
| `Contractions.swift` / `AmbiguousContractions.swift` | 84 / 41 | `dont→don't` fast path; ambiguous real words gated by LM margin 1.0 |
| `AppleSpellCheckerProvider.swift` | 79 | Wraps iOS `UITextChecker` (system resource, zero bundled cost); guesses score .85, completions .6 |
| `SymSpell/SymSpell.swift` | 344 | Delete-index spell correction (in-memory fallback path) |
| `SymSpell/MappedSymSpellIndex.swift` | 1125 | mmap blob reader with hash validation (primary path) |
| `SymSpell/SymSpellProvider.swift` | 199 | Candidates → suggestions, capitalization templates, learned-word respect |
| `SymSpell/QwertyGeometry.swift` | 291 | Key-distance weighting (EN + EL layouts), β=1.5 |
| `Trigram/TrigramProvider.swift` + `SideIndex.swift` + kenlm C bridge (h/cpp) | 512+34+221 | KenLM .klm scoring via vendored C++; lazy load, read-mode fallback; side index = bigram→≤20 followers |
| `Autocorrect/*` (9 files) | ~570 | Controller (origin/length/confidence gates), retroactive apply + guards, backspace revert, host-field traits (disable in URL/email/numeric fields), 4-entry RecentWordBuffer |
| `AutoCapitalization/*`, `GreekText.swift` | ~280 | Typed-character capitalization; Greek final-sigma conversion (typing path only, not dictation) |

**User-visible behavior:** suggestion bar in `KeyboardView` (taps replace current word, tracked as `.suggestionTap` origin); autocorrect applied on space/`. , ! ? ; :` triggers; rejected corrections enter `LearnedWordsStore`.

### 2.2 Data resources (exact sizes)

| Resource | Bytes |
|---|---:|
| `frequency_dictionary_en_wordfreq_50k.txt` (49,999 rows) | 643,297 |
| `frequency_dictionary_el_wordfreq_50k.txt` (42,858 rows) | 955,307 |
| `symspell_index_en_v1.blob` | 5,741,504 |
| `symspell_index_el_v1.blob` | 11,319,376 |
| `trigram_en_v1.klm` (Tatoeba EN, order-3 Kneser-Ney, 20k vocab) | 3,475,971 |
| `trigram_side_index_v1.json` (23,000 keys) | 1,980,243 |
| `trigram_meta_v1.json` | 941 |
| **Total** | **24,116,639** |

Key tuning: max edit distance 2, prefix length 7, min word freq 1500 (prunes 53.7% of EN list), load-time phys_footprint bounds 40 MiB general / 38 MiB trigram. No master prediction kill-switch exists — only `autocorrectOnSpaceEnabledKey`, `autoCapitalizationEnabledKey` (user toggles), `symspellMappedIndexEnabled` (mapped-vs-memory, not off-switch), `chunkFinalMergeEnabled`.

### 2.3 Dictation-side processing (surprisingly small)

- `shared/ChunkFinalMerger.swift` (~105 LoC): merges chunk-boundary spurious periods when gap ≤2500 ms (clamp 500–10000). Called in `DictationViewModel` after stream completes, gated on telemetry presence.
- `normalizedDictationInsertion(of:)` in `KeyboardViewController`: whitespace trim + trailing space at insertion. Boundary handling only.
- **No** on-device grammar engine, profanity filter, vocab handling, `initial_prompt`/hotword path, or `SFSpeechRecognizer` exists. Dictation language field: EN omitted, Greek sends `el`.
- Dictation pipeline runs in the **container app**, not the keyboard — dictation changes don't add keyboard memory.

### 2.4 Personal dictionary

`shared/LearnedWordsStore.swift` + `app/Sources/DictionaryView.swift` — app/extension shared via app group; never sent to the server today.

### 2.5 JS mirror

`scripts/prediction-sim/` — first-class mirror: `lib/` (~20 modules incl. fused-pool, top-correction, kenlm-normalize, symspell, blob parsing, autocorrect-controller, chunk-final-merge, auto-capitalizer, greek-text) + `node --test` suite (~615 tests). Official test surface for pure logic; would shrink/migrate as on-device logic is removed.

### 2.6 Deletion blast radius (if on-device stack goes)

- Delete outright: Prediction/** (≈4,600 LoC + 24 MB resources), vendored KenLM in `project.yml`, most of prediction-sim mirror.
- Must stay on-device: `textDocumentProxy` insertion, `normalizedDictationInsertion`, basic key handling; `AppleSpellCheckerProvider`/`UITextChecker` is free and can remain as instant/offline fallback.
- Needs replacement or rewiring: suggestion bar UI + `KeyboardViewController`/`KeyboardView` compile-time references; `LearnedWordsStore`/`DictionaryView` → becomes vocab-sync UI; `ChunkFinalMerger` → moves server-side (server already joins chunk texts before the final).
- Shared files compiled into both targets: `Config.swift`, `KeyboardLanguage.swift`, `TextNormalization.swift`, `LearnedWordsStore.swift`, `ChunkFinalMerger.swift`.

---

## 3. Current state — server (`~/whisper/server-v2`)

### 3.1 Architecture

- FastAPI + Uvicorn, Python ≥3.11 <3.14; binds 0.0.0.0:5000 (`WHISPER_PORT` override). Model load/inference/unload isolated in a **model-worker subprocess** (serialized engine requests); single-worker thread executor for blocking request-side work.
- Engines: `whisper` (faster-whisper small.en, CPU int8, beam 5, VAD 0.15) · `parakeet-v2` (**currently selected**: nemo-parakeet-tdt-0.6b-v2, unquantized ONNX, 4 intra-op threads, ITN on, no engine VAD, long-audio 60 s windows/1 s overlap) · `parakeet-v3`.
- Pi hardware (czechpi, from project memory, Oct 2026): 4×2.4 GHz, 8.8 GB RAM available; Parakeet ONNX external data 2.4 GB; **S1-mini cleanup latency 1.84–2.13 s median, 6.2–8.4 s p95**.
- Deployment: `start-server.sh` (uv + locked deps); systemd user service on the Pi per project memory; no unit file in repo. Local `config.json` (gitignored) ≠ Pi live config (Pi was `model_load="always"` in Oct 12 snapshot; local is `on-demand-trim`/300 s).
- Git: `main...origin/main [ahead 6]`, clean besides ignored files.

### 3.2 Endpoints (all behind `APIKeyAuthMiddleware`, Bearer; WS also accepts `api_key` query param; SHA-256 digest store)

| Route | Notes |
|---|---|
| `POST /warmup` | warm/skipped/warming(202) |
| `GET /status` | model_loaded, engine; parakeet-v2 also `cleanup_llm` state |
| `POST /dictation_result` / `GET /dictation_result/latest` | in-memory JSON store per key label, ≤1 MiB |
| `POST /transcribe` | multipart field **`audio`**; empty→400, >200 MiB→413, engine fail→503 |
| `WS /stream` | `?format=pcm` (float32 mono 16 kHz; client frames = 4-byte BE chunk id + audio) or container formats |
| `POST /transcriptions` + `GET /jobs/{job_id}` | async, Idempotency-Key support, 600 s terminal retention, key-label isolation |
| `/docs` `/redoc` `/openapi.json` | only with `WHISPER_DOCS=1` |

**/stream text protocol:** client→server `END`, `CANCEL`, `PING`, `TELEMETRY` (≤1 MiB, before END, stored as `client_telemetry.json`), `CONTEXT` (reconnect context). Server→client lowercase `partial`/`final`/`error` (with `transcription`, `chunk_id`), uppercase `PONG` (echoes `ping_seq`).

### 3.3 Pipeline + existing language intelligence

1. Whisper path: static style prompt (punctuation/numbers/clock), `condition_on_previous_text=True`, streaming uses previous 300 chars as context; hardcodes `language="en"`.
2. **Parakeet-v2 S1-mini LLM cleanup (active):** llama-cpp-python, `s1-mini-q4_k_m.gguf`, n_ctx 2048, temp 0, 3-word minimum, filler-word handling, **constrained** — rejects word additions and non-filler deletions, only accepted normalization-equivalence replacements; `stream_chunk_cleanup: true` cleans punctuation-complete spans during streaming (partials still sent raw).
3. NeMo ITN (EN whitelist, edge-punctuation restoration) + money + 24/7 formatting, run after cleanup.
4. Shared formatter: `apply_substitutions → convert_time_format → normalize_text` (whitespace collapse, NFKC, control-char strip, ellipsis repair, first-char uppercase) + trailing space. `word_substitutions` map exists (15 built-ins) but is **disabled**.
5. **Not present:** prediction endpoint, autocorrect/grammar endpoint, caller-supplied vocabulary/hotwords, N-best/LM rescoring, `/health`.

### 3.4 Extension points

- Routes in `server.py`; seam for upload finalization = `_convert_transcribe` (1873–1915); stream finalization seam after `END` (3157–3275); reusable helpers `apply_substitutions`, `convert_time_format`, `normalize_text`, `_format_transcription_text`, `_run_finalize_text`.
- Engine finalization crosses the model-worker boundary (`ParakeetV2Engine.finalize_text_with_outcome` / `cleanup_stream_chunk_with_outcome` via `model_worker_manager`), cleanup concurrency = 1.
- Models materialize under `models/onnx-asr-<model>--<quant>` unless `model_dir` override — precedent for per-slot model downloads.

---

## 4. Model-slot landscape (state of the art, Oct 2026)

> Universal caveat: **no Raspberry Pi measurements exist** for OptiSpell, NeuSpell, GECToR, Nemotron 3.5, or neural candidate-scoring. All Pi token-rate figures are generation/prefill proxies from heterogeneous community benchmarks, not slot workloads. Benchmark-first (D3) exists precisely because of this.

### Slot A — ASR (dictation)

| Candidate | Evidence | Pi relevance |
|---|---|---|
| **Parakeet-tdt-0.6b-v2/v3** (current) | v3: 25 European languages, CC BY 4.0; community Pi-5-class report RTF 0.21 / 1.76 GB RAM | Strong batch option; 2026 controlled study found substantial WER degradation in chunked/streaming mode — relevant to our chunked `/stream` |
| **Nemotron 3.5 ASR Streaming 0.6B** | 40 locales, chunks to 80 ms, GGUF (Q8_0) for NVIDIA NeMo-Speech.cpp, OpenMDW-1.1, FLEURS results | Best new streaming candidate; **no Pi/ARM measurement** |
| **Moonshine v2** | 34M/123M/245M, MIT, C++/ONNX CPU path; 50/148/258 ms post-utterance on Apple M3 | Edge-designed, tiny; M3 ≠ Pi |
| Whisper small.en / Distil-whisper / Canary-1B-Flash | 244M/166M/883M | Chunkable but not true-streaming Pi picks |

**Verdict:** keep Parakeet; benchmark Nemotron 3.5 + Moonshine v2 on the Pi before any swap. No proven Pi winner exists.

### Slot B — Word/spelling correction

| Candidate | Size | Evidence |
|---|---|---|
| **OptiSpell (T5-efficient-mini)** — *pick* | 31M params, ~59.55 MB FP32 | 2024 study's best resource/performance spelling checker; F0.5 = .897 (JFLEG spelling) / .934 (JFLEG-NE). Targets **non-word** errors. HF: `startc/optispell-t5-mini`; license unclear — verify |
| **NeuSpell (BERT)** — runner-up | ~110M (440 MB FP32 / ~110 MB INT8) | Contextual real-word errors; 2020 paper; older but broader error mix |
| ContextualSpellChecker | BERT-base + spaCy | OOV/non-word focus; unmaintained — not a default |
| ByT5-small | ~300M | Char-level; bigger than OptiSpell with no dedicated current checkpoint |
| SymSpell + frequency list | none (data) | Excellent **candidate generator**, not contextual |

**Hard limit:** text-only correctors cannot fix acoustically-valid-but-wrong words (ASR substitutions) — that gap belongs to Slot D or acoustic rescoring. "FoundationSpell" and "pyorc" (as a spellchecker) could not be verified — likely phantom names.

### Slot C — Grammar correction

| Candidate | Size | Evidence |
|---|---|---|
| **GECToR / GECToR-2024** — *pick* | 300–355M; INT8 ≈ 300–355 MB | Tagger (token-level edits, no autoregressive rewrite) → up to 10× faster than seq2seq; F0.5 65.3 CoNLL-14 / 72.4 BEA-19; 2024 study ("Pillars of GEC") found ~300M GECToR competitive with 7–20B systems; best-in-study single model 68/59/75 (CoNLL-14/BEA-dev/BEA-test). Plausibly sub-second on Pi with INT8/ONNX — unmeasured |
| Fine-tuned Qwen3-0.6B — runner-up | ~0.4 GB Q4 | Flexible rewrites; **no published GEC score**; ~1B Q4 ≈ 11 tok/s on Pi 5 → seconds per correction |
| Gramformer / T5 GEC | varies | No recent standardized comparison above GECToR; seq2seq may rewrite unaffected wording |

**Warning:** small instruct LLMs zero-shot have no comparable GEC scores and the literature consistently shows zero-shot LLM correction **overcorrects**. Benchmark metrics are not interchangeable (CoNLL/BEA = edit F0.5; JFLEG = GLEU fluency).

### Slot D — Vocabulary/dictionary

**Verdict: not a neural model.** SOTA for this slot is a versioned lexicon + scoring service: personal dictionary (synced from app), trie/FST lookup, SymSpell candidate generation, wordfreq priors (frozen ~2021, CC BY-SA data), alias/pronunciation maps for names, KenLM rescoring **where multiple hypotheses exist**.

Critical mechanics finding:

- **Parakeet TDT via `onnx-asr` exposes greedy 1-best only** — no N-best API, so a decoupled rescorer has nothing to rescore.
- NeMo word/phrase boosting (shallow fusion for CTC/RNN-T/TDT) requires decoder integration and is GPU-accelerated — not a CPU-Pi post-ASR stage.
- `pyctcdecode` is CTC-only. faster-whisper `hotwords`/`initial_prompt` are Whisper-decoder features (prompt limited to 224 tokens, silently truncated, unreliable). CB-Whisper's keyword-spotting front-end is Whisper-specific.
- Consequence: with Parakeet, the vocab slot operates as conservative post-ASR fuzzy/phonetic correction + substitutions. Acoustic biasing would require an ASR-engine change, not a vocab-model change.

### Slot E — Prediction (next-word / completion)

**Core architectural insight: score, don't generate.** The keyboard needs ranking of a fixed candidate list (10–20). One forward pass yields next-token logits → rank single-token candidates from that distribution; multi-token candidates share context KV + prefix trie. Not 10–20 generations.

| Candidate | Pi 5 evidence | Notes |
|---|---|---|
| **Qwen3-0.6B Q4 GGUF + llama.cpp** — *pick* | ~20 gen tok/s (anecdotal, 4 threads); ~600 MB | Apache-2.0; 100+ languages advertised → plausible Greek; no candidate-scoring benchmark exists |
| **Gemma 3 270M** — runner-up | 45 prompt-eval tok/s, 22 gen tok/s (quantization unstated); ~292 MB disk / 400 MB RAM | Fastest reported prefill; custom Gemma terms; Greek quality unknown |
| Gemma 3 1B | 11.5 gen tok/s; ~1.1–1.4 GB RAM | More capacity, slower |
| Llama 3.2 1B | 11.2 gen tok/s | Official supported-language list **omits Greek**; custom license |
| SmolLM2 1.7B | 8.2 gen tok/s; high RAM in one test | English-oriented |
| **KenLM** — *deadline-guaranteed fallback* | mmap, C++ scoring | Always answers; current 3.5 MB trigram is the baseline to beat |

Tooling: `llama-cpp-python` `eval()`/logits access for a custom scoring wrapper (no built-in "score these N candidates" API); llama.cpp server = OpenAI-compatible sidecar w/ continuous batching + speculative decoding; ONNX Runtime GenAI exposes prefill logits; ExecuTorch fast on phones but not a quick Pi path; MNN results anomalous. Serving: async HTTP POST for ranking; same model can serve a completion mode (optionally streamed) — scoring for the latency path, generation for completion.

**Greek:** no maintained ready-made Greek keyboard LM. Corpora to train KenLM: FineWeb2 `ell_Grek` (47.4M docs / 78.6 GB), Leipzig Greek Wikipedia 2021 (1.74M sentences), SUBTLEX-GR frequencies (23M words). Meltemi-7B = Greek quality reference/teacher, too big to serve. Qwen3/Gemma = multilingual test candidates, not proven Greek predictors.

**Unverifiable:** Google "Minuet" Gboard LM — could not be verified to exist publicly; do not cite. No 2024–2026 publication shows a reproducible <50 ms keyboard-LM inference on Pi-class ARM.

---

## 5. Cross-cutting findings (first-pass research)

- **Post-correction guidance:** keep raw transcript; conservative, constrained edits; separate "cleanup" from "polish". Specialized error-correction LMs (ECLM, 0.5B, 2024) learn pass-through on correct text; general-LLM correction results are mixed and can truncate/overcorrect; candidate-constrained correction reduces risk but needs hypotheses.
- **Pi latency reality:** ≤1.5B models ≈ 5–15 tok/s gen; 3B ≈ 2–5 tok/s; <360M >20 tok/s (SBC study 2025). AI HAT+ 2 measured *slower* than Pi 5 CPU for LLM tokens (Qwen2.5-1.5B: 11.73 CPU vs 6.74 HAT) — advertised TOPS ≠ useful proxy; benchmark the real workload.
- **Remote keyboard prediction feasibility:** keyboards historically target 50–150 ms; home-Pi RTT over VPN won't dependably meet <100 ms off-Wi-Fi. Pattern: async, non-blocking, timeout-tolerant enhancement + local fallback (we keep `UITextChecker` — free). Keyboard already has `RequestsOpenAccess=true` and dictation already depends on the server, so no new permission burden.
- **Prior art for hybrids:** SwiftKey (local-first + optional sync), Siri/Apple Dictation & Gboard (split on-device/server paths), Grammarly (keyboard + cloud language services). No widely-adopted open-source iOS keyboard serving remote prediction as primary path — we'd be pioneering; local-fallback is the defensible design.

---

## 6. Caveats register

1. Zero Pi measurements for: OptiSpell, NeuSpell, GECToR inference, Qwen3/Gemma candidate scoring, Nemotron 3.5, Moonshine v2.
2. Parakeet streaming-mode WER degradation (2026 controlled study) vs our chunked `/stream` — needs a streaming-quality benchmark, not just batch.
3. `onnx-asr` greedy-only decoding blocks N-best rescoring for the vocab slot.
4. Server local config ≠ Pi live config (gitignored); Pi state known only via dated project memory. `/health` doesn't exist (401 without auth).
5. Licenses to verify before shipping: OptiSpell weights (unclear), Gemma (custom terms), Llama (custom), wordfreq data (CC BY-SA), FineWeb2 crawled content rights, Parakeet v2 exact card.
6. Unverifiable names: "Minuet", "FoundationSpell" — treat as nonexistent.
7. Whisper `initial_prompt` ≤224 tokens, silently truncated — not a vocabulary mechanism.
8. Keyboard extension has no network access unless the user enables Full Access (we require it already for dictation).

---

## 7. Source index

**ASR / streaming:** parakeet-tdt-0.6b-v2 (huggingface.co/nvidia/parakeet-tdt-0.6b-v2) · v3 card · nemotron-3.5-asr-streaming-0.6b (huggingface.co/nvidia/…) + NeMo-Speech.cpp (github.com/NVIDIA/NeMo-Speech.cpp) · Moonshine v2 paper arxiv.org/html/2602.12241v1 + moonshine-ai/moonshine-v2 · whisperX (alignment, not correction) github.com/m-bain/whisperX

**Correction/grammar:** OptiSpell paper doi.org/10.13053/cys-28-4-5068 + weights huggingface.co/startc/optispell-t5-mini · NeuSpell arxiv.org/html/2010.11085v1 + github.com/neuspell/neuspell · GECToR aclanthology.org/2020.bea-1.16/ + github.com/grammarly/gector · Pillars of GEC arxiv.org/html/2404.14914v1 + github.com/grammarly/pillars-of-gec · minimal-edit GEC arxiv.org/html/2506.13148v1 · ECLM arxiv.org/html/2405.15216 · LLM ASR correction arxiv.org/html/2409.09554v2 · ByT5 arxiv.org/abs/2105.13626

**Vocabulary/biasing:** OpenAI prompting guide developers.openai.com/cookbook/examples/whisper_prompting_guide · faster-whisper github.com/SYSTRAN/faster-whisper · NeMo word boosting docs · onnx-asr github.com/istupakov/onnx-asr · pyctcdecode github.com/kensho-technologies/pyctcdecode · CB-Whisper aclanthology.org/2024.lrec-main.262/ · wordfreq github.com/rspeer/wordfreq + SUNSET.md · symspellpy github.com/mammothb/symspellpy · KenLM github.com/kpu/kenlm · WhisperLive github.com/collabora/WhisperLive · wyoming-faster-whisper github.com/OHF-Voice/wyoming-faster-whisper · whisper.cpp server

**Prediction:** Gboard CIFG RNN arxiv.org/abs/1811.03604 · Google FL posts research.google/blog/advances-in-private-training… + aclanthology.org/2023.acl-industry.60/ · llama-cpp-python API · llama.cpp server + speculative.md · onnxruntime.ai/docs/genai · ExecuTorch llama example · lm-scorer github.com/simonepri/lm-scorer · Predict4All github.com/mthebaud/predict4all

**Pi benchmarks:** stratosphereips.org/blog/2025/6/5/how-well-do-llms-perform-on-a-raspberry-pi-5 · stratospherelinuxips.readthedocs.io (rpi LLM performance) · kunalganglani.com/blog/gemma-3-raspberry-pi-5-benchmark · cnx-software.com/2026/01/20/raspberry-pi-ai-hat-2-review… · SBC LLM study arxiv.org/html/2511.07425v1

**Greek:** FineWeb2 huggingface.co/datasets/HuggingFaceFW/fineweb-2 (`ell_Grek`) · corpora.uni-leipzig.de ell_wikipedia_2021 · SUBTLEX-GR bcbl.eu/en/subtlex-gr · Meltemi-7B huggingface.co/ilsp/Meltemi-7B-v1

**Keyboard/latency/prior art:** Apple configuring open access developer.apple.com/documentation/uikit/configuring-open-access-for-keyboard-custom-keyboards · typing-latency study dl.acm.org/doi/fullHtml/10.1145/3626705.3627784 · SwiftKey/Microsoft privacy + Backup&Sync docs · Apple Siri/dictation privacy notice · Gboard voice-typing help · Grammarly iOS + privacy FAQ
