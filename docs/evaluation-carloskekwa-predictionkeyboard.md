# Evaluation: carloskekwa/Custom-Keyboard-Prediction (PredictionKeyboard)

**Date:** 2026-07-21
**Evaluator:** Code agent (Phase 2 gate check)

## Package Information

| Field | Value |
|---|---|
| Package URL | `https://github.com/carloskekwa/Custom-Keyboard-Prediction` |
| CocoaPods | `PredictionKeyboard` ([SPI link](https://cocoapods.org/pods/PredictionKeyboard)) |
| Latest version | 1.0.45 |
| Language | Objective-C (binary XCFramework) |
| Repo size | 320 KB |
| Last commit | 2026-06-23 (active) |
| Open issues | 0 |
| License | MIT |

## Package.swift (Dependencies)

```swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "PredictionKeyboard",
    platforms: [.iOS(.v12)],
    products: [
        .library(name: "PredictionKeyboard", targets: ["PredictionKeyboard"]),
    ],
    targets: [
        .binaryTarget(
            name: "PredictionKeyboard",
            url: "https://youtakeadvantage.s3.eu-central-1.amazonaws.com/PredictionKeyboard_spm.zip",
            checksum: "b3c82626fa0c15c17a92c384fafa927962ebccb78fc48070bbc2952035b7508b"
        ),
    ]
)
```

**Dependencies:** ZERO external `.package(url:...)` declarations. The framework ships as a pre-compiled binary XCFramework hosted on S3. Realm is baked inside the binary — it is NOT declared as an SPM dependency.

## Evaluation Criteria

### (a) Memory Cost — FAIL

| Detail | Value |
|---|---|
| Database download | ~600 MB (downloaded from S3 at first launch) |
| Database on disk | ~600 MB |
| Memory during active use | ~50 MB (per README) |
| Framework binary | ~3 MB |

The keyboard extension operates under a **48 MB Jetsam memory cap**. The existing baseline is ~30 MB without the KenLM model loaded. Adding ~50 MB of active memory usage from this framework is impossible within the budget, regardless of whether Realm is bundled or declared externally.

Additionally, the 600 MB on-disk database is downloaded from the developer's S3 bucket — this is not feasible for a keyboard extension that must work offline and cannot depend on a remote server.

**Result: REJECT**

### (b) Quality Bar — INCONCLUSIVE

The README claims ~85% accuracy and <10 ms query time, but:
- No published benchmarks, research papers, or third-party validation.
- No description of the training corpus, n-gram order, smoothing method, or vocabulary size.
- The 85% accuracy claim cannot be verified without integration.
- Binary-only distribution means no code inspection is possible.

**Result: INCONCLUSIVE (but irrelevant given memory failure)**

### (c) Stability — PASS

- Last commit was June 2026 (3 weeks ago) — actively maintained.
- 0 open issues.
- MIT license.
- Supports SPM and CocoaPods.
- Supports iOS 12.0+ and Swift 5.0+.

**Result: PASS**

### (d) Configurability — FAIL

The framework ships with its own pre-packaged 600 MB database. There is NO mechanism to:
- Use a custom trained model (e.g., our existing KenLM `trigram_en_v1.klm`).
- Specify custom vocabulary or corpus.
- Reduce database size or select a subset of n-grams.
- Configure n-gram order, smoothing, or pruning parameters.

The architecture requires the container app to download the developer's database from S3 and share it with the keyboard extension via an App Group container. This is fundamentally incompatible with our approach of shipping a lightweight 3.3 MB model bundled with the app.

**Result: FAIL**

## Decision

| Criterion | Result |
|---|---|
| (a) Memory cost | ❌ FAIL |
| (b) Quality bar | ❓ INCONCLUSIVE |
| (c) Stability | ✅ PASS |
| (d) Configurability | ❌ FAIL |

**DECISION: PROCEED WITH BRIDGING**

The PredictionKeyboard package is unsuitable for the Ritoras keyboard extension because:

1. **Memory:** Its 600 MB database and ~50 MB runtime footprint exceed the 48 MB Jetsam cap.
2. **Configurability:** It cannot use our existing KenLM-trained 3-gram model (3.3 MB).
3. **Binary-only distribution:** The pre-compiled XCFramework cannot be audited or customized.
4. **Server dependency:** Database download from S3 at first launch is impractical for an offline-capable keyboard.

The Swift↔C++ bridging approach (Steps 1–7) is the correct path forward. It allows us to use our own lightweight, pre-trained KenLM model without external dependencies or server downloads.
