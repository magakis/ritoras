# Ritoras — Implementation Plan

**iOS Custom Keyboard Extension → self-hosted Whisper over Tailscale → paste transcript.**
Personal sideload. Linux-only developer. $0 budget. iOS-first.

---

## 0. Investigation summary (evidence base for this plan)

| Claim | Source | Verdict |
|---|---|---|
| Diction ships iOS source we could fork | GitHub tree API (`omachala/diction`, all branches/tags) | **FALSE** — repo is Go **gateway** + docs + assets only. No Swift/`.xcodeproj` anywhere. MIT covers the gateway, not an app. |
| OpenAI-compatible `/v1/audio/transcriptions` multipart contract | `gateway/core/proxy.go` uses `mime/multipart`; `models.go` references OpenAI-compatible `/v1/models` & "Faster Whisper" | **CONFIRMED** — Diction's own gateway speaks standard OpenAI transcription, so the user's existing server contract matches. |
| XcodeGen `type: app-extension` is correct for keyboard ext | Context7 `/yonaskolb/xcodegen` ProjectSpec product-type list | **CONFIRMED** |
| XcodeGen `info.path`/`info.properties` + `entitlements.path` + `dependencies: {embed:true}` | Context7 XcodeGen docs | **CONFIRMED** |
| macos-14 GitHub runner free & unlimited for public repos; xtool dead-end for extensions; 7-day free-Apple-ID limit; ATS vs CGNAT; 561145187 audio error | User-provided research (not re-researched) | **ACCEPTED** |

**Two elevated risks the research note under-weighted** (called out per-phase below):
- **App Groups likely won't provision under free-Apple-ID / SideStore signing.** App Group IDs require portal registration inside the provisioning profile; free Apple IDs have no portal access. Threatens "containing-app settings → keyboard" sharing. → Phase 4 spike + build-time-config fallback.
- **`ideviceinstaller` cannot mint the 7-day free signature.** SideStore/AltStore do that on-device. libimobiledevice is for USB **pairing only**. → Primary deploy path is CI → unsigned/ad-hoc `.ipa` → SideStore signs+installs+refreshes.

---

## 1. Recommendation: BUILD GREENFIELD (do NOT fork)

Diction is **closed-source on the iOS side.** The only forkable code is the Go gateway — and the user *already has* a Whisper server, so forking the gateway is pointless. Additionally, Diction uses a **custom encrypted WebSocket protocol through its own gateway**; Ritoras's design is simpler (plain HTTP multipart to the user's existing OpenAI-compatible endpoint over Tailscale). Mimicking Diction's protocol would add complexity for zero benefit.

**Use Diction as:**
- **UX reference** — screenshots in `docs/public/screenshot-keyboard-*.png` show the recording/idle states worth imitating.
- **Contract cross-check** — `gateway/core/proxy.go` confirms the multipart field names (`file`, `model`) the server expects.
- **Conceptual reference** for the audio-session config (research-provided; validate empirically — see Phase 6).

**Do NOT use Diction as** a code base to fork.

---

## 2. Repository structure

```
ritoras/
├── project.yml                      # XcodeGen spec (single source of truth for the .xcodeproj)
├── README.md
├── .gitignore                       # ignore DerivedData/, *.xcodeproj (generated), build/
├── docs/
│   ├── IMPLEMENTATION-PLAN.md       # this file
│   ├── SIDeload.md                  # iPhone setup + refresh runbook (Phase 3 output)
│   └── SERVER-CONTRACT.md           # Whisper request/response spec (Phase 7 output)
├── .github/workflows/
│   └── build.yml                    # macos-14: xcodegen → xcodebuild → package ipa → upload artifact
├── app/                             # Containing-app target sources  (target: Ritoras)
│   ├── Info.plist
│   ├── Ritoras.entitlements
│   ├── Sources/
│   │   ├── RitorasApp.swift         # @main SwiftUI App
│   │   ├── SettingsView.swift       # server URL/port/model/timeout/language
│   │   ├── OnboardingView.swift     # Full-Access + install instructions
│   │   └── AppSettings.swift        # App-Group UserDefaults wrapper (or build-time fallback)
│   └── Assets.xcassets/             # app icon
├── keyboard/                        # Keyboard-extension target sources (target: RitorasKeyboard)
│   ├── Info.plist                   # NSExtension dict, RequestsOpenAccess, NSMicrophoneUsageDescription
│   ├── RitorasKeyboard.entitlements
│   └── Sources/
│       ├── KeyboardViewController.swift   # UIInputViewController (principal class)
│       ├── KeyboardView.swift             # UIKit mic button + states
│       ├── AudioSession.swift             # AVAudioSession config (561145187 lives here)
│       ├── AudioRecorder.swift            # AVAudioRecorder wrapper → m4a/aac 16k mono
│       ├── WhisperClient.swift            # URLSession multipart POST
│       └── SharedConfig.swift             # reads server config (App Group OR build-time)
└── shared/
    └── Config.swift                 # Build-time config (bundleId prefix, default endpoint) — included in both targets
```

### Target & identifier table

| Target | XcodeGen `type` | Bundle ID | Product |
|---|---|---|---|
| `Ritoras` | `application` | `com.<you>.ritoras` | the container app (settings + onboarding) |
| `RitorasKeyboard` | `app-extension` ✅ verified | `com.<you>.ritoras.keyboard` | the keyboard (principal class `KeyboardViewController`) |
| App Group (stretch) | — | `group.com.<you>.ritoras` | settings sharing — **see Phase 4 risk** |

`<you>` = your reverse-DNS prefix (e.g. `michael` → `com.michael.ritoras`). Pick once, use everywhere.

---

## 3. The Whisper server contract (what Phase 7 implements)

**Request** — standard OpenAI `audio.transcriptions`:
```
POST {BASE_URL}/v1/audio/transcriptions
Content-Type: multipart/form-data; boundary=<b>
Authorization: Bearer {API_KEY}            ← omit if your server needs no auth

--<b>␤Content-Disposition: form-data; name="file"; filename="audio.m4a"␤Content-Type: audio/mp4␤␤<bytes>
--<b>␤Content-Disposition: form-data; name="model"␤␤{MODEL}
--<b>␤Content-Disposition: form-data; name="response_format"␤␤json
--<b>␤Content-Disposition: form-data; name="language"␤␤{LANGUAGE}   ← optional
--<b>--␤
```
**Response** (`response_format=json`): `{ "text": "the transcript" }`

**Settings the user configures** (in containing app, fallback to build-time):
- `baseUrl` — e.g. `https://ritoras.<tailnet>.ts.net:8000` (HTTPS over Tailscale avoids ATS pain)
- `model` — default `whisper-1` (make it free text; servers vary)
- `apiKey` — optional bearer token
- `timeoutSeconds` — default 10
- `language` — optional ISO code (e.g. `en`)

Cross-checked against Diction's `gateway/core/proxy.go` (uses `mime/multipart`) and `models.go` (OpenAI-compatible endpoints). ✅

---

## 4. Phase roadmap (dependency graph)

```
P0 ─▶ P1 ─▶ P2 ─▶ P3 (sideload runbook; then runs in parallel with features)
            │
            └─▶ ┌─ P4 (container app + App-Group spike)
                ├─ P5 (keyboard UI skeleton)  ─▶ P6 (audio recorder)
                └─ P7 (Whisper client)
                       │
                       └──────▶ P8 (integration) ─▶ P9 (build verification)
```

**Parallelizable (disjoint files, no data deps):**
- After **P1**: **P4 ∥ P5 ∥ P7** can all run in parallel.
- **P6** starts after **P5** (needs the keyboard host to test in), but P6's files are disjoint from P4/P7.
- **P3** (sideload) is independent of all feature phases once **P2** is done — run it whenever; you'll want it early to de-risk the install path on real hardware.
- **P8** is the merge point (needs P4+P5+P6+P7).
- **P9** gates the release; ideally also a real-device smoke test leveraging P3.

---

## Phase 0 — Environment & repo bootstrap

**Goal:** Have every account, secret, and CLI tool in place so Phase 1 can produce a build on day one.

**Files:** `README.md` (stub), `.gitignore`, `docs/IMPLEMENTATION-PLAN.md` (this), init git repo.

**Key steps:**
1. **Linux tooling** (all free, `apt`/`brew-linux`/`pipx`):
   - `xcodegen` — install via `brew install xcodegen` (Homebrew-on-Linux) **or** `mint install yonaskolb/xcodegen` **or** download the release binary. **Verified:** XcodeGen runs on Linux (it's a Swift CLI distributed as a static binary; the release tarball has a Linux build).
   - `libimobiledevice` + `usbmuxd` + `idevicepair` — for one-time USB pairing with SideStore. (`apt install libimobiledevice6 usbmuxd libimobiledevice-utils`.)
   - ` SideStore pairing helper` if needed (JitterBugPair / WireGuard for wireless refresh later).
   - `gh` CLI — to create the repo + push from Linux.
2. **Accounts / secrets:**
   - GitHub **public** repo `ritoras` (public is mandatory — free macos-14 runners are free/unlimited only for public repos).
   - Free **Apple ID** (no $99 needed for v1). Note the 7-day re-sign limit up front.
   - (Optional, for upgrade path) `$99/year Apple Developer Program` — not required; flagged where it removes friction.
3. **iPhone one-time prep** (document in `docs/SIDeload.md` later, but do now):
   - Settings → Privacy & Security → **Developer Mode = ON** (iOS 16+; requires wired reboot).
   - Install **SideStore** on the phone (from sidestore.io) — this is what will sign+refresh Ritoras later.
4. **`git init`**, push to GitHub, set repo visibility to **Public**.

**Dependencies:** none (first phase).

**Risks:**
- **R0.1 — xcodegen on Linux:** if the binary build is stale, fall back to `mint` or build from source via Swift toolchain. Verify with `xcodegen --version` before Phase 1.
- **R0.2 — 7-day re-sign fatigue:** SideStore's wireless auto-refresh is the mitigation. Accept for now; revisit $99/year if it becomes painful.

---

## Phase 1 — Walking skeleton: XcodeGen project + stub keyboard + CI build

**Goal:** Prove the **Linux → GitHub Actions macos-14 → successful `xcodebuild`** pipeline with the absolute minimum code: a container app that builds, and a keyboard extension whose principal class is a stub `UIInputViewController` that just logs. **No mic, no network, no signing yet.** If this builds green in CI, the hardest infrastructure unknown is retired.

**Files:**
- `project.yml` (XcodeGen spec — full skeleton below)
- `app/Info.plist`, `app/Sources/RitorasApp.swift` (minimal `@main App` showing "Ritoras")
- `keyboard/Info.plist` (NSExtension dict, `RequestsOpenAccess=true`, `NSMicrophoneUsageDescription` placeholder), `keyboard/Sources/KeyboardViewController.swift` (stub: `viewDidLoad` → `print("Ritoras loaded")`)
- `.github/workflows/build.yml`
- `.gitignore` (ignore `*.xcodeproj`, `DerivedData/`, `build/`)

**Key implementation details:**
- **XcodeGen `type: app-extension`** for the keyboard — **Verified Pattern:** Context7 ProjectSpec product-type list.
- **Extension embedding** — container target depends on keyboard with `embed: true` — **Verified Pattern:** XcodeGen `dependencies: [{ target: RitorasKeyboard, embed: true, codeSign: true }]`.
- **Info.plist handling** — hand-author each `Info.plist` inside the target's source folder; XcodeGen auto-detects via its `getInfoPlist(target.sources)` fallback — **Verified Pattern:** Context7 `PBXProjGenerator.getInfoPlists`.
- **Keyboard `Info.plist` must contain:**
  ```
  NSExtension:
    NSExtensionPointIdentifier: com.apple.keyboard-service
    NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).KeyboardViewController
    RequestsOpenAccess: true
  NSMicrophoneUsageDescription: "Ritoras needs the mic to transcribe your speech."   ← required even though unused in P1
  ```
- **CI workflow** (`runs-on: macos-14`, `if: github.repository_visibility == 'public'`):
  1. `brew install xcodegen`
  2. `xcodegen generate` → emits `Ritoras.xcodeproj`
  3. `xcodebuild -project Ritoras.xcodeproj -scheme Ritoras -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` (unsigned is fine for P1; signing lands in P2)
- **Build for `generic/platform=iOS`** (device, not simulator) — this is what we ultimately sideload.

**Verified Pattern sources:** Context7 `/yonaskolb/xcodegen` (product types, `info.path`/`entitlements`, target dependencies with `embed`).

**Dependencies:** Phase 0.

**Explorer investigation needed:** none (XcodeGen patterns verified above). Optionally skim any public `project.yml` that defines an iOS app + app-extension pair for a second confirmation, but the Context7 docs are authoritative.

**Verify (build gate):** `xcodegen generate && xcodebuild ... build` succeeds **in CI** (not just locally — local Linux can't run xcodebuild). The GitHub Actions run is green and the workflow logs show `** BUILD SUCCEEDED **`.

**Risks:**
- **R1.1 — wrong extension `type:`** → `app-extension`, not `application.messages`/`extensionkit-extension` (the latter is the xtool dead-end). Verified.
- **R1.2 — `INFOPLIST_FILE` not set** → keep Info.plist inside each target's sources dir so XcodeGen auto-detects; or set `settings.base.INFOPLIST_FILE` explicitly as a fallback.
- **R1.3 — signing blocks the build** → `CODE_SIGNING_ALLOWED=NO` for P1. P2 turns it back on.

---

## Phase 2 — CI signing → installable `.ipa` (decide signing model)

**Goal:** Turn P1's green-but-unsigned build into an **installable artifact**. Decide and implement the signing model. Produce a `.ipa` in the GitHub Actions **Artifacts** panel that can be sideloaded in P3.

**Decision — primary path = Model B (unsigned/ad-hoc `.ipa` + SideStore on-device signing):**
Rationale tied to the free path: free Apple IDs have **no portal access**, so CI cannot mint a long-lived cert, and `ideviceinstaller` alone cannot generate the 7-day signature iOS requires. **SideStore signs on-device** using the user's Apple ID at install/refresh time. So CI only needs to emit an **ad-hoc-signed (or unsigned) `.ipa`**.

**Files:**
- `.github/workflows/build.yml` (extend P1):
  1. `xcodebuild ... -exportArchive` with an `ExportOptions.plist`:
     ```
     method: development            (or 'ad-hoc')
     signingStyle: manual
     signingCertificate: "-"        (ad-hoc / Sign to Run Locally)
     ```
     OR build the `.app` then `zip` it into `Payload/` → `.ipa` manually (the classic sideload `.ipa`).
  2. `actions/upload-artifact@v4` with `name: Ritoras.ipa`, `path: build/Ritoras.ipa`.
- `ExportOptions.plist` (repo root)

**Key implementation details:**
- **Ad-hoc packaging** is the robust path when no cert is in CI: `xcodebuild build` → copy `Ritoras.app` into `Payload/` → `zip -r Ritoras.ipa Payload`. SideStore accepts and resigns this.
- **Upgrade path A (CI signs with zsign):** if the user later obtains a `.p12` + `.mobileprovision` (e.g. via a one-time Mac, or `apple-codesign`), store as GH **Encrypted secrets**, install `zsign` on the runner, and sign in CI. Mentioned; not required for v1.
- **Ultimate upgrade:** `$99/year` Apple Developer Program → 1-year cert, no weekly refresh, App Group provisioning available.

**Dependencies:** Phase 1.

**Explorer investigation:** none. Optionally confirm the latest SideStore `.ipa` acceptance (it accepts ad-hoc/unsigned ipas and resigns) — but this is well-established sideload behavior.

**Verify (build gate):** CI artifact `Ritoras.ipa` exists and is non-empty; `unzip -l Ritoras.ipa` shows `Payload/Ritoras.app/Ritoras` and `Ritoras.app/PlugIns/RitorasKeyboard.keyboardextension/...`.

**Risks:**
- **R2.1 — export fails demanding a real cert** → fall back to the manual `Payload/` zip; never block on signing in v1.
- **R2.2 — extension not embedded in app** → the `.ipa`'s `Ritoras.app/PlugIns/` must contain `RitorasKeyboard.keyboardextension`. If missing, the `embed: true` dependency in `project.yml` is wrong.

---

## Phase 3 — Sideload & iPhone onboarding runbook

**Goal:** A repeatable path from the CI `.ipa` to a working keyboard on the phone, with the weekly-refresh story solved. Output: `docs/SIDeload.md`.

**Files:** `docs/SIDeload.md` (the runbook). No code.

**Key content:**
1. **Download** the `Ritoras.ipa` artifact from GitHub Actions to your Linux box.
2. **First install** via SideStore:
   - Open SideStore on the phone → "Browse" → select the `.ipa` (transfer via iCloud Drive / a local webserver / SideStore's file import).
   - SideStore prompts for your **Apple ID** (use an app-specific password; 2FA app-store login flow) → it signs on-device → installs.
3. **iPhone trust chain (do once):** Settings → General → VPN & Device Management → tap your Apple ID → **Trust**.
4. **Keyboard enablement (do once):** Settings → General → Keyboard → Keyboards → Add New Keyboard → **Ritoras**. Then tap Ritoras in the list → toggle **Allow Full Access** (accept the scary warning).
5. **Pairing (one-time, for SideStore wireless refresh):** run `idevicepair pair` over USB from Linux (needs `libimobiledevice` + `usbmuxd`). After this, SideStore can refresh wirelessly.
6. **Weekly refresh:** SideStore auto-refreshes within a few days of expiry if the phone is unlocked and on Wi-Fi. Manual refresh = open SideStore → tap Ritoras → refresh. Document the 7-day limit honestly.

**Dependencies:** Phase 2 (needs an installable `.ipa`).

**Parallelizable with:** Phases 4–8 (run anytime after P2; do it early to de-risk real hardware).

**Verify:** keyboard appears in Settings → Keyboards list; switching to it in any text field shows the (stub) Ritoras keyboard. This is the **first real end-to-end proof** that the whole Linux→CI→phone pipeline works.

**Risks:**
- **R3.1 — Full Access toggles reset between reinstalls** → document re-enabling each refresh cycle.
- **R3.2 — SideStore pairing breaks across iOS updates** → re-run `idevicepair pair`.
- **R3.3 — 7-day expiry mid-use** → SideStore auto-refresh; consider $99/year if disruptive.

---

## Phase 4 — Containing app: Settings UI + **App-Group provisionability spike**  ⚠️

**Goal:** SwiftUI settings screen capturing the server config (`baseUrl`, `model`, `apiKey`, `timeoutSeconds`, `language`) + onboarding screen with Full-Access instructions. **Critically:** run an early spike to determine whether App-Group sharing works under SideStore/free-Apple-ID signing.

**Files:**
- `app/Sources/RitorasApp.swift`, `SettingsView.swift`, `OnboardingView.swift`, `AppSettings.swift`
- `app/Ritoras.entitlements` (include `com.apple.security.application-groups: [group.com.<you>.ritoras]` for the spike)
- `shared/Config.swift` (build-time defaults — the fallback)

**Key implementation details:**
- `AppSettings` wraps `UserDefaults(suiteName: "group.com.<you>.ritoras")` for the primary design.
- **THE SPIKE (do this FIRST in this phase, before building the UI):**
  1. Add the App-Group entitlement to both targets' `.entitlements`.
  2. Ship a trivial P2 build that writes a test value to the App Group from the container and reads it from the keyboard.
  3. Sideload via SideStore, enable Full Access, open the keyboard.
  4. **Outcomes:**
     - ✅ **Works** → keep the primary design (App-Group UserDefaults). Build the Settings UI to write it.
     - ❌ **Fails** (`"This app is not allowed to access group container…"`) → **fallback to build-time config:** hardcode `baseUrl`/`model`/etc. in `shared/Config.swift`; rebuild to change them. The Settings UI is still built (writes to plain `UserDefaults.standard` in the container) but the keyboard reads from `Config.swift`. Revisit App Group if/when the user buys a $99 account (which enables portal-registered App Groups).

**Dependencies:** Phase 1 (project exists). Parallel with P5/P7.

**Explorer investigation:** none external (App-Group provisioning under SideStore is community-empirical, not documented as a clean reference). Mark the spike outcome in `docs/SIDeload.md`.

**Verify:** spike outcome recorded; SettingsView renders; saving a value persists (verified via container, and via keyboard if App Group works).

**Risks (this phase's headline risks):**
- **R4.1 — App Group not provisionable on free/SideStore signing** ⚠️ — the entire cross-process settings design hinges on this. Spike first; fallback ready.
- **R4.2 — Shared Keychain alternative also needs provisioning** → same problem; don't bother trying Keychain sharing as a workaround.

---

## Phase 5 — Keyboard UI skeleton (UIInputViewController, mic button, Full-Access gating)

**Goal:** The visible keyboard: a `UIInputViewController` subclass with a single **mic button** and four UI states — `idle`, `recording`, `transcribing`, `error`. Wire `textDocumentProxy.insertText` with a **stub transcript** ("[stub]") so the insert path is testable before audio/network exist. Gate the mic on `hasFullAccess`.

**Files:**
- `keyboard/Sources/KeyboardViewController.swift` (principal class; state machine; `insertText` wiring)
- `keyboard/Sources/KeyboardView.swift` (UIKit view — **not** SwiftUI, for the memory cap)

**Key implementation details:**
- **UIKit, not SwiftUI** in the keyboard — saves ~5–10 MB inside the **48 MB Jetsam cap**. SwiftUI's first-render cost is real here.
- **State machine:** `idle → (tap mic, checks pass) → recording → (tap stop) → transcribing → (success) idle | (error) error → idle`. Keep it as an `enum` + simple switch; no global singletons.
- **Full-Access check:** `self.hasFullAccess`. If `false`, show a banner: *"Ritoras needs Full Access. Settings → General → Keyboard → Ritoras → Allow Full Access."* — **a keyboard extension cannot open URLs itself** (no `UIApplication` in-process), so only display instructions; the containing app's Settings screen can additionally call `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`.
- **`textDocumentProxy` nil guard:** when no text field has focus, `textDocumentProxy` may be nil — guard before `insertText`.
- **Lifecycle:** the OS may kill the keyboard at any time (memory pressure, dismissal). Treat every tap as the start of a **stateless transaction**; persist nothing critical in `self` across `viewDidLoad` re-entries.

**Dependencies:** Phase 1. Parallel with P4/P7.

**Explorer investigation:** none (patterns verified). Optional: glance at Diction's screenshots (`docs/public/screenshot-keyboard-*.png` in the Diction repo) for state-UX inspiration.

**Verify:** sideload (P3 path); tap mic in Notes → inserts "[stub]"; Full-Access-off state shows the banner.

**Risks:**
- **R5.1 — 48 MB cap** → UIKit only; keep view hierarchy tiny; no large images.
- **R5.2 — keyboard re-entry resets state** → the state machine must re-init cleanly on each `viewDidLoad`.
- **R5.3 — no URL opening from extension** → instruction banner only.

---

## Phase 6 — Audio recording module (the 561145187 zone)  ⚠️

**Goal:** Reliable record-then-upload capture: configure `AVAudioSession`, start/stop `AVAudioRecorder`, write an `.m4a` (AAC, 16 kHz, mono) to a temp URL. Request mic permission. Return the file URL to the controller.

**Files:**
- `keyboard/Sources/AudioSession.swift`
- `keyboard/Sources/AudioRecorder.swift`
- `keyboard/Info.plist` (already has `NSMicrophoneUsageDescription` from P1; verify it's present)

**Key implementation details — START from this known-working config (research-provided, validate empirically):**
```swift
// AVAudioSession
session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
session.setActive(true)
// AVAudioRecorder settings
AVFormatIDKey: kAudioFormatMPEG4AAC,
AVEncoderAudioQualityKey: .medium,
AVSampleRateKey: 16000,
AVNumberOfChannelsKey: 1
```
- **`mode: .default` — NOT `.spokenAudio`** (the latter is implicated in 561145187).
- **Permission:** `AVAudioApplication.requestRecordPermission` (iOS 17+) / `AVAudioSession.requestRecordPermission` (older). Gate before `setActive`.
- **Temp file:** `NSTemporaryDirectory().appendingPathComponent("ritoras-\(UUID().uuidString).m4a")`. Delete after upload.

**Dependencies:** Phase 5 (needs the keyboard host). Files are disjoint from P4/P7.

**Explorer investigation:** none external (Diction's iOS audio code is closed). Treat the config above as **ASSUMPTION — research-provided, not codebase-verified**. Budget 1–2 days of empirical tuning (the research note explicitly warns this).

**Verify:** sideload; grant mic when prompted; tap mic → logs/visual shows recording; tap stop → `.m4a` exists in temp and is non-trivial size; playback-convert to confirm it's valid AAC.

**Risks (headline):**
- **R6.1 — `OSStatus 561145187` (`AVAudioSessionErrorCodeCannotStartRecording`)** ⚠️ → the canonical keyboard-audio error. Mitigations: `.default` mode (not `.spokenAudio`); `setActive(true)` *before* `AVAudioRecorder.init`; `setActive(false)` with `notifyOthersOnDeactivation` on stop; handle re-entrancy when the keyboard is re-shown mid-session (deactivate first); never hold the session across keyboard dismissal.
- **R6.2 — permission string missing** → re-verify `NSMicrophoneUsageDescription` in `keyboard/Info.plist`; without it the permission dialog never appears and recording silently fails.
- **R6.3 — 48 MB cap while recording** → stream-to-file (AVAudioRecorder does this natively); never buffer whole clip in RAM.

---

## Phase 7 — Whisper HTTP client (URLSession multipart + ATS)  ⚠️

**Goal:** A `WhisperClient` that takes an audio file URL + config, builds the multipart body per §3, `POST`s to `{baseUrl}/v1/audio/transcriptions` with async/await `URLSession`, returns the transcript `String`. Handles timeouts.

**Files:**
- `keyboard/Sources/WhisperClient.swift`
- `shared/Config.swift` (default `baseUrl`/`model`/`timeout` — build-time fallback)
- `docs/SERVER-CONTRACT.md` (freeze the §3 spec here so the server-side and client-side agree)
- `keyboard/Info.plist` (ATS exception — see below)

**Key implementation details:**
- **Multipart body** — hand-build or use a tiny helper (avoid pulling Alamofire; keep deps zero inside the memory cap). Field names `file` + `model` (+ optional `response_format=json`, `language`). Cross-checked against Diction's `gateway/core/proxy.go` (`mime/multipart`). ✅
- **`URLSession` with async/await**, `timeoutIntervalForRequest = config.timeoutSeconds` (default 10).
- **ATS decision (pick one, document in `docs/SERVER-CONTRACT.md`):**
  - **Best:** serve HTTPS from the Whisper node via **Tailscale's Let's Encrypt** (`*.ts.net` hostname) → **no ATS exception needed**. Strongly recommended.
  - **Easiest (v1):** `NSAppTransportSecurity: { NSAllowsArbitraryLoads: true }` in `keyboard/Info.plist` → acceptable for a sideloaded personal app. Use this if the Tailscale cert isn't set up yet.
  - **Why this matters:** the **Tailscale 100.64.0.0/10 CGNAT range is NOT treated as "local" by ATS** (only RFC 1918 is). A bare `http://100.x.x.x:port` URL **will fail** without one of the above.

**Dependencies:** Phase 1 only. Fully parallel with P4/P5/P6 (disjoint files).

**Explorer investigation:** none external. Confirm your server's exact field expectations with a one-off `curl` (allowed for localhost/SearXNG only — for your Whisper server use a quick multipart test from Linux `curl` or a Swift snippet in a scratch iOS sim). Document in `docs/SERVER-CONTRACT.md`.

**Verify:** unit-test the multipart builder (headers/boundary/body shape) against a captured expected payload; integration-test against the real server with a sample `.m4a` (manual).

**Risks (headline):**
- **R7.1 — ATS blocks Tailscale 100.x** ⚠️ → ts.net HTTPS (best) or `NSAllowsArbitraryLoads` (v1).
- **R7.2 — multipart body malformed** → server returns 400/422 → unit test the boundary/CRLF layout exactly.
- **R7.3 — response shape differs** → some servers return plain text vs `{ "text": "…" }`. Make `response_format=json` explicit; parse defensively (fall back to raw body if JSON parse fails).

---

## Phase 8 — Integration: record → upload → insertText (+ timeout/clipboard fallback)

**Goal:** Wire P5+P6+P7+P4 into the full flow inside `KeyboardViewController`. The phase where Ritoras actually *works*.

**Flow (matches the user's architecture):**
```
idle → tap mic
  if !hasFullAccess: banner (P5)
  if no recordPermission: request (P6)
  configure AVAudioSession + start recorder (P6) → recording
recording → tap stop → stop recorder, get m4a URL (P6) → transcribing
  WhisperClient.transcribe(url, config) (P7)   ← reads config from P4 (App Group OR build-time)
    on success: textDocumentProxy.insertText(text + " ") → idle
    on timeout / error:
       show "Server unreachable" state
       fallback: copy transcript-if-partial to UIPasteboard; show "Copied to clipboard"
       → idle
```

**Files:** mostly `keyboard/Sources/KeyboardViewController.swift` (state-machine wiring) + `SharedConfig.swift` (resolve App-Group-vs-build-time).

**Key implementation details:**
- **Statelessness across kills:** if the OS kills the keyboard mid-upload, the next `viewDidLoad` must land in `idle` (no half-recorded state, no dangling session). Clean up the temp file in both success and error paths and in `deinit`.
- **`textDocumentProxy` guard** before every `insertText`; append a trailing space for usability.
- **Timeout UX:** the 10 s budget should show a spinner within ~500 ms; on timeout, clipboard fallback so the user isn't blocked.
- **Config resolution:** one `SharedConfig.load()` that reads App-Group UserDefaults if the P4 spike succeeded, else `Config.swift` build-time defaults. Single source of truth.

**Dependencies:** Phases 4, 5, 6, 7. This is the merge point.

**Explorer investigation:** none.

**Verify:** full manual smoke on device — open Notes, tap mic, speak, stop, see transcript inserted. Then: kill the Whisper server, tap mic, stop, see "Server unreachable" + clipboard fallback.

**Risks:**
- **R8.1 — keyboard killed mid-request** → stateless design; never assume `self` survives an `await`.
- **R8.2 — config not reaching keyboard** → if App-Group spike failed (P4), ensure build-time `Config.swift` is the fallback and is actually included in the keyboard target's `sources`.

---

## Phase 9 — Final build verification

**Goal:** The build-fixer runs a full clean build; "done" is defined unambiguously.

**Files:** none new (fix any drift).

**Definition of done — ALL must be true:**
- [ ] `xcodegen generate` produces a clean `Ritoras.xcodeproj` with no manual edits.
- [ ] GitHub Actions (macos-14, public repo) goes green: `** BUILD SUCCEEDED **`.
- [ ] Workflow uploads a `Ritoras.ipa` artifact; `unzip -l` shows the app **and** the embedded `RitorasKeyboard.keyboardextension` in `PlugIns/`.
- [ ] `.ipa` sideloads via SideStore (P3 path) on a real iPhone.
- [ ] After enabling Full Access, the keyboard appears in Notes/any text field.
- [ ] Tap mic → record → stop → **transcript from the user's Whisper server is inserted**.
- [ ] Whisper server down → graceful "Server unreachable" + clipboard fallback.
- [ ] `docs/SIDeload.md` + `docs/SERVER-CONTRACT.md` + `docs/IMPLEMENTATION-PLAN.md` are accurate and current.
- [ ] Weekly refresh via SideStore documented and tested once.

**Hand to build-fixer:** run the CI workflow from a clean checkout; expect `** BUILD SUCCEEDED **` and a non-empty `Ritoras.ipa` artifact. Any failure here is a Phase-1/2 regression.

---

## 5. Cross-phase risk register (the gotchas, collected)

| # | Gotcha | Phase(s) | Mitigation |
|---|---|---|---|
| G1 | **App Group not provisionable on free/SideStore** | P4, P8 | Spike first; build-time `Config.swift` fallback; $99/year unlocks it |
| G2 | **Free-Apple-ID signature needs SideStore (not ideviceinstaller)** | P2, P3 | CI emits ad-hoc/unsigned `.ipa`; SideStore signs on-device |
| G3 | **`OSStatus 561145187` audio error** | P6 | `.default` mode (not `.spokenAudio`); activate-before-init; deactivate-on-stop; handle re-entrancy |
| G4 | **ATS blocks Tailscale 100.64.0.0/10 (CGNAT)** | P7 | Tailscale `*.ts.net` LE HTTPS (best) or `NSAllowsArbitraryLoads` (v1) |
| G5 | **48 MB Jetsam cap** | P5, P6 | UIKit (not SwiftUI) in keyboard; stream-to-file; minimal UI; no in-process models |
| G6 | **OS kills keyboard mid-request** | P5, P8 | Stateless per-tap transaction; cleanup in success/error/deinit |
| G7 | **Full Access toggles reset on reinstall** | P3, P5 | Onboarding banner + `docs/SIDeload.md` re-enable steps |
| G8 | **Extension cannot open URLs (no UIApplication)** | P5 | Instruction banner only; container app opens Settings |
| G9 | **7-day re-sign fatigue** | P0, P3 | SideStore wireless auto-refresh; $99/year removes it |
| G10 | **Diction fork assumption (research note)** | — | **Fork impossible** — iOS source is closed. Greenfield only. |
| G11 | **xtool for extensions** | — | Dead end (issue #138, status Todo). Use XcodeGen. |

---

## 6. Success criteria (project-level)

- [ ] A signed/ad-hoc `.ipa` builds in GitHub Actions (macos-14) on every push, downloadable as an artifact.
- [ ] Sideload + weekly refresh works from Linux without a Mac, via SideStore.
- [ ] In any text field, tap mic → speak → transcript inserts from the user's self-hosted Whisper over Tailscale.
- [ ] Zero-cost: free Apple ID, public-repo CI, existing Whisper server + Tailscale.
- [ ] Code is comprehensible and owned by the user (greenfield, no opaque fork).
