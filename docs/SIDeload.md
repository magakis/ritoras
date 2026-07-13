# Ritoras — Sideload & iPhone Onboarding Runbook

**Signed on-device by SideStore using your free Apple ID.**  
CI produces an unsigned `.ipa`; SideStore mints the 7-day signature when you install it.

---

## Prerequisites (one-time)

### 1. iPhone requirements

- **iOS 17+** — the app targets iOS 17.0 APIs.
- **Developer Mode = ON** — Settings → Privacy & Security → **Developer Mode** → toggle on.  
  ⚠️ On iOS 16+, this requires a wired reboot the first time. On iOS 17+ it can be enabled without a reboot.

### 2. Install SideStore

SideStore installs and re-signs sideloaded apps on-device without a Mac.

- Go to [**sidestore.io**](https://sidestore.io) on your iPhone and follow their install guide.
- The first-time setup requires a computer (Windows/Mac/Linux) to install the SideStore utility app and a WireGuard VPN profile. After that, SideStore works wirelessly.
- **Linux users:** Use the SideStore pairing helper (`JitterBugPair` or `SideStoreLoader`) over USB via `libimobiledevice` (`idevicepair pair`).

### 3. Apple ID

- Any **free Apple ID** works. No Developer Program ($99/year) required for v1.
- If you have **two-factor authentication** (2FA) enabled, generate an **app-specific password**:
  1. Go to [appleid.apple.com](https://appleid.apple.com) → Sign In → **App-Specific Passwords**.
  2. Generate one for "SideStore" and save it somewhere safe.

---

## Install Ritoras (per build)

### 1. Download the `.ipa` from CI

1. Navigate to your repository's **Actions** tab on GitHub.
2. Click the latest successful workflow run.
3. Scroll to **Artifacts** at the bottom.
4. Download **`Ritoras.ipa`**.

Transfer the `.ipa` to your iPhone:
- **iCloud Drive:** upload from your computer, then open Files → iCloud Drive on the phone.
- **Local web server:** `python3 -m http.server 8080` in the download directory, then visit `http://<your-ip>:8080` on the phone.
- **AirDrop:** works if you have a Mac in the loop.

### 2. Install via SideStore

1. Open **SideStore** on your iPhone.
2. Tap the **+** (plus) button or **Browse** / **Install App**.
3. Navigate to the `.ipa` file and select it.
4. Enter your **Apple ID** email and **app-specific password** when prompted.
   - SideStore signs the app on-device using your Apple ID — this is the 7-day signature.
5. Wait for the install to complete. The app appears on your home screen with a "Ritoras" icon.

---

## Trust the developer profile (first time after each install)

This is required every time you install a new `.ipa` (including re-installs):

1. Open **Settings** → **General** → **VPN & Device Management**.
2. Under **Developer App**, tap your **Apple ID**.
3. Tap **Trust `[your email]`**.
4. Confirm **Trust** in the dialog.

If you skip this step, the keyboard will not appear in the keyboard list.

---

## Enable the keyboard

### Add Ritoras to the keyboard list

1. Open **Settings** → **General** → **Keyboard** → **Keyboards**.
2. Tap **Add New Keyboard**.
3. Under **THIRD-PARTY KEYBOARDS**, select **Ritoras**.

### Grant Full Access (required)

Ritoras needs **Allow Full Access** to use the microphone and make network requests.

1. In the **Keyboards** list, tap **Ritoras**.
2. Toggle **Allow Full Access** to ON.
3. Read and accept the warning dialog.

> **Why Full Access is required:** iOS restricts third-party keyboards by default. Without Full Access, the keyboard cannot access the microphone (`AVAudioSession`) or perform network requests (`URLSession`). This is a personal project — your audio data goes only to your own Whisper server over Tailscale.

⚠️ **Full Access resets every time you reinstall.** After refreshing or reinstalling the `.ipa`, come back here and toggle it back on.

---

## Using the keyboard

1. Open any app with a text field — **Notes**, **Messages**, **Safari**, etc.
2. Tap on the text field to bring up the system keyboard.
3. Switch to the Ritoras keyboard:
   - Tap the **globe icon** (🌐) on the bottom-left of the system keyboard.
   - Or long-press the globe icon and select **Ritoras**.
   - (Some keyboards use the emoji key instead of a globe.)
4. The Ritoras keyboard appears. *(Stub in the initial build — later phases add the mic button, recording, and transcription.)*

---

## The 7-day refresh

**This is the most important operational detail. Read it carefully.**

### Why 7 days?

Free Apple ID certificates expire **7 days** after signing. After expiry, the keyboard stops functioning until refreshed. This is an Apple-imposed limit — it applies to **all** sideloaded apps, not just Ritoras.

### Automatic refresh (recommended)

SideStore can refresh apps wirelessly when:

- The phone is **unlocked** and connected to **Wi-Fi**.
- SideStore's **WireGuard VPN** profile is enabled (it is, if you followed the SideStore setup).
- SideStore can reach Apple's validation servers.

SideStore typically auto-refreshes within a day or two of expiry. **It does not refresh when the phone is locked.**

### Manual refresh

1. Open **SideStore** on your iPhone.
2. Tap **Ritoras** in the app list.
3. Tap **Refresh**.
4. Enter your Apple ID password or app-specific password if prompted.

### Fallback: reinstall

If refresh fails (common after long periods of inactivity or network changes):

1. Download the latest `Ritoras.ipa` from CI (see Install section above).
2. Open SideStore → tap **+** → select the `.ipa` → install fresh.

### The permanent fix

The **$99/year Apple Developer Program** removes this limitation — certificates last 1 year, no weekly refresh. Consider it if:

- You use Ritoras daily and the 7-day cycle becomes annoying.
- You want App Group entitlements to work (free Apple IDs can't register App Groups in provisioning profiles).
- You want to share Ritoras with others without asking them to sideload.

---

## Troubleshooting

### Keyboard not appearing in the keyboard list

- **Developer Profile not trusted:** Go to Settings → General → VPN & Device Management → tap your Apple ID → **Trust**.
- **Developer Mode is off:** Settings → Privacy & Security → **Developer Mode** → toggle on.
- **Profile expired:** The 7-day signature has lapsed. Reinstall or refresh via SideStore.

### "Allow Full Access" keeps turning off

Full Access resets after every reinstall or refresh. After installing/refreshing:

1. Settings → General → Keyboard → Keyboards → **Ritoras**.
2. Toggle **Allow Full Access** back on.

### SideStore won't refresh

- **WireGuard VPN is off:** SideStore needs its VPN profile active for refresh. Check in Settings → General → VPN & Device Management → ensure **SideStore** (WireGuard) is connected.
- **No network:** Refresh requires internet access to reach Apple's servers. Try over **Wi-Fi**, not cellular.
- **Phone was locked for too long:** SideStore only refreshes when the phone is unlocked. Leave the phone unlocked on Wi-Fi for ~10 minutes.
- **Apple ID password changed:** Update credentials in SideStore → Settings → Apple ID.

### App crashes on launch

- **Signature expired:** The 7-day certificate has lapsed. Reinstall or refresh via SideStore.
- **Corrupt install:** Delete the app, download a fresh `.ipa` from CI, and reinstall.

### `.ipa` downloads as a `.zip` from GitHub

GitHub sometimes wraps artifacts in a `.zip` container. If you download `Ritoras.ipa` but get `Ritoras.ipa.zip`:

- On iPhone in Files app: tap to extract, then select the inner `.ipa`.
- In SideStore: navigate to the extracted `.ipa` inside the unzipped folder.

### Keyboard extension missing from `.ipa`

The CI verification step (`Verify .ipa contains keyboard extension`) should catch this and fail the build. If you somehow get a bad `.ipa`:

1. Download the `.app` artifact alongside the `.ipa` for debugging.
2. On a Mac, run `unzip -l Ritoras.ipa` and check for `PlugIns/RitorasKeyboard.keyboardextension/`.
3. If missing, the `embed: true` dependency in `project.yml` is not propagating the extension. Rebuild and re-check.

---

## Appendix: CI workflow summary

The GitHub Actions workflow (`.github/workflows/build.yml`) does the following on every push/PR:

| Step | What it does |
|------|-------------|
| `Install XcodeGen` | Installs the Xcode project generator |
| `Generate Xcode project` | Runs `xcodegen generate` → `Ritoras.xcodeproj` |
| `Build (unsigned)` | `xcodebuild` with `CODE_SIGNING_ALLOWED=NO` |
| `Package .ipa` | Copies `Ritoras.app` into `Payload/` → `zip -r Ritoras.ipa` |
| `Verify .ipa` | Checks `unzip -l` for `PlugIns/RitorasKeyboard` — **fails the build if missing** |
| Upload artifacts | `.ipa` (sideloadable) + `.app` (debugging) available in the run's **Artifacts** |

**No signing secrets are needed in CI.** The `.ipa` is unsigned/ad-hoc. SideStore signs it on-device at install time.
