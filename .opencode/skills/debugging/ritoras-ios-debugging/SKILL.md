---
name: "Ritoras iOS Device Debugging"
description: "Use when debugging a Ritoras build on a physical iPhone from the opencode Linux container — covers device connection, live syslog streaming filtered to Ritoras (app + keyboard extension), crash report pulling, and status checking. Uses libimobiledevice (idevicesyslog, idevicecrashreport) and pymobiledevice3. Excludes LLDB/Swift breakpoint debugging (separate effort)."
confidence: 0.9
domain: "debugging"
source: "session-extraction"
version: 1.0.0
created: "2026-07-18"
last_confirmed: "2026-07-18"
metadata:
  opencode:
    tags: [ios, keyboard, debugging, logs, crashes, syslog, libimobiledevice, pymobiledevice3]
    related_skills: [ritoras-deploy-pipeline]
---

# Ritoras iOS Device Debugging

## When to Apply

Apply when debugging a Ritoras build running on a physical iPhone connected via USB to the opencode Linux container. This skill covers live syslog monitoring, crash report collection, and device/app status checks. It does NOT cover LLDB/Swift toolchain breakpoint debugging — that is a separate, larger effort.

If you need to **build and install** a new Ritoras build, use the [ritoras-deploy-pipeline](../automation/ritoras-deploy-pipeline/SKILL.md) skill instead.

## Prerequisites

- iPhone connected via USB to the host machine (USB passthrough to container via `/dev/bus/usb`)
- **Developer Mode** enabled on the iPhone: Settings → Privacy & Security → Developer Mode → ON (required on iOS 16+)
- Ritoras installed on the device (via the deploy pipeline or Xcode)
- Container running with `usbmuxd` active (`/var/run/usbmuxd` socket present)

## Quick Start

```bash
# Check everything is working
ritoras-debug

# Stream live logs filtered to Ritoras
ritoras-logs

# Pull crash reports (optionally specify output directory)
ritoras-crashes                    # saves to ./crashes/
ritoras-crashes /tmp/ritoras-crashes
```

## Available Commands

### Ritoras-Specific Helpers

| Command | Description |
|---------|-------------|
| `ritoras-debug` | Top-level status: iPhone connection, iOS version, Ritoras install status, command menu |
| `ritoras-logs` | Stream live device syslog, filtered to messages containing "Ritoras" (catches both main app and keyboard extension) |
| `ritoras-crashes [dir]` | Pull crash reports from device, filter for Ritoras-related crashes, save to `./crashes/` (or custom dir) |

### idev Helper (Device Detection)

| Command | Description |
|---------|-------------|
| `idev detect` | Detect first connected iPhone (restarts usbmuxd if needed) — prints UDID or empty |
| `idev refresh` | Force-restart usbmuxd, then detect |
| `idev status` | Show usbmuxd PID and detected device UDIDs |
| `idev run <cmd>` | Refresh-if-empty then run arbitrary command (e.g., `idev run idevicesyslog -x`) |

### Raw libimobiledevice Tools

| Command | Description |
|---------|-------------|
| `idevicesyslog -u <UDID> -m <filter>` | Stream raw syslog with optional match filter (`-m` substring, `-p` process name, `-e` exclude process) |
| `idevicecrashreport -e <dir>` | Pull and extract ALL crash reports from device |
| `ideviceinfo -k <key>` | Query device properties (ProductVersion, DeviceName, etc.) |
| `idevice_id -l` | List connected device UDIDs |

### pymobiledevice3

| Command | Description |
|---------|-------------|
| `pymobiledevice3 usbmux list` | List devices via usbmuxd |
| `pymobiledevice3 apps list` | List installed apps on device |
| `pymobiledevice3 crash pull <dir>` | Pull crash reports via pymobiledevice3 |
| `pymobiledevice3 syslog live` | Live syslog stream (alternative to idevicesyslog) |
| `pymobiledevice3 lockdown start-tunnel` | Start trusted tunnel for advanced debugging (see iOS 17+ section below) |

## Bundle Identifiers

From the Ritoras XcodeGen project (`project.yml`):

| Component | Bundle ID | Process Name (approx.) |
|-----------|-----------|----------------------|
| Main app | `com.ritoras.app` | `Ritoras` |
| Keyboard extension | `com.ritoras.app.keyboard` | `RitorasKeyboard` |

The `ritoras-logs` helper uses `-m Ritoras` as a substring match on log messages, which catches both processes.

## Debugging Patterns

### Keyboard Extension Not Appearing

1. Verify Ritoras is installed: `ritoras-debug` (shows install status)
2. Check Settings → General → Keyboard → Keyboards → Add New Keyboard → Ritoras
3. If it was just installed via deploy pipeline, the keyboard may need toggling off/on
4. Stream logs while adding the keyboard: `ritoras-logs` — look for any errors
5. Check if the build is a Release build (see note about NSLog/OSLog below)

### Crashes on Launch

1. Pull crash reports: `ritoras-crashes`
2. If no crashes appear, try unlocking the device and re-running
3. For keyboard extension crashes, the crash report will contain "RitorasKeyboard" in the process name
4. If the app crashes during startup but no crash report is generated, the build may not include debug symbols — ensure you're using a dev-signed build

### No Log Output Appearing

- **NSLog/OSLog/print output is only visible for dev-signed builds.** Release builds (including the unsigned `.ipa` built by the deploy pipeline) suppress `NSLog` and `print()` output in the syslog. You will NOT see debug output from a production/side-loaded build via `idevicesyslog`.
- For meaningful log debugging, the app must be signed with a development provisioning profile and installed via Xcode or a dev-signed CI build.
- The deploy pipeline produces an unsigned `.ipa` for SideStore signing. SideStore applies its own ad-hoc signing, which is NOT a development signature and will NOT produce visible NSLog output.

> **⚠️ Empirical probe — `os.Logger` vs `NSLog`/`print`:**  
> The claim above applies to `NSLog` and `print()` — these are definitively suppressed for release (non-dev-signed) binaries.  
> **`os.Logger` (`Logger` from `os` module) is different** — its visibility depends on the log level. Levels `.notice`, `.error`, and `.fault` may persist in the unified logging system even for release/ad-hoc-signed builds, while `.debug` and `.info` are typically suppressed. This has NOT yet been verified for SideStore-signed builds.
>
> **Phase 3a probe:** A one-shot `os.Logger.notice(...)` call was added to `FileLogger.swift` (subsystem `com.ritoras.app`, category `probe`, message prefix `"ritoras probe:"`). It fires exactly once per process lifetime, the first time a `.warn` or `.error` event is logged.
>
> **Test procedure:**
> 1. Deploy a build containing this probe via the deploy pipeline.
> 2. Trigger a warn/error event (e.g. stop the whisper server and attempt dictation, or trigger any keyboard/app error path).
> 3. Run `idevicesyslog -m ritoras | grep "ritoras probe:"`.
> 4. If the message appears, `os.Logger.notice` *is* visible for SideStore-signed release builds → **GO** for Phase 3b (full os.Logger mirror in FileLogger). If it does NOT appear → **NO-GO** (the existing claim extends to `os.Logger`; alternative approaches like custom syslog relay or wire protocol logging would be needed).
>
> **Result (pending device verification):** [GO / NO-GO — to be filled in after on-device test]

## iOS 17+ Trusted Tunnel (Future Work)

iOS 17+ requires a trusted tunnel for advanced debugging (debugserver, profiling, etc.):

```bash
# Start trusted tunnel
pymobiledevice3 lockdown start-tunnel

# This creates a tunnel endpoint; then debugserver can connect
# NOTE: This requires LLDB + debugserver, which are NOT currently
# set up in the container. This is flagged as future work.
```

This functionality requires:
- LLDB and the Swift toolchain installed in the container
- Developer Disk Image mounted on the device
- `debugserver` running on the device

None of these are currently configured. See the separate LLDB debugging effort for this.

## Network Debugging (Optional)

For HTTP/HTTPS traffic inspection, `mitmproxy` can be used:

```bash
# Not installed by default — install if needed:
sudo pip install --break-system-packages mitmproxy
```

Configure the iPhone's Wi-Fi proxy to point to the container's IP on port 8080, then install mitmproxy's CA certificate on the device. This is optional and not part of the standard debugging setup.

## Troubleshooting

### Device Not Detected

```bash
# 1. Check usbmuxd status
idev status

# 2. Force restart usbmuxd (handles the apple-mfi-fastcharge conflict
#    automatically via libusb reset, no flags needed)
idev refresh

# 3. If still not detected, check USB passthrough on the host:
#    (from HOST, not container)
#    lsusb | grep -i apple
#    ls -la /dev/bus/usb/???
```

### apple-mfi-fastcharge Driver Conflict

This is the **most common reason** `idev detect` returns empty. The Linux kernel driver `apple-mfi-fastcharge` (present in kernels 6.x+) claims the iPhone's USB device, blocking usbmuxd from claiming the multiplexor interface (interface 1).

**Automatic fix (container-side):**
`idev refresh` (and any `idev` command that restarts usbmuxd) now calls `prep_iphone_usb()`, which resets the Apple USB device via libusb, releasing the fastcharge driver. This works even from an **unprivileged container** with read-only sysfs.

```bash
idev refresh
# -> ✓ usbmuxd restarted
# -> 00008140-...
```

**Permanent kernel-level fix (HOST-side, not container):**
For a permanent fix that avoids the conflict entirely, blacklist the module on the **host machine** (not inside the container):

```bash
# On the HOST:
echo "blacklist apple-mfi-fastcharge" | sudo tee /etc/modprobe.d/no-apple-fastcharge.conf
sudo update-initramfs -u
# Then reboot
```

This removes the driver permanently at the kernel level. After rebooting, the container will no longer need the libusb reset workaround.

**Manual unbind (privileged container or host):**
If `idev refresh` does not resolve the issue, you can manually unbind the driver:

```bash
# Check what's bound
ls /sys/bus/usb/drivers/apple-mfi-fastcharge/

# Unbind (replace <id> with the identifier, e.g. 1-6:1.0)
echo "<id>" | sudo tee /sys/bus/usb/drivers/apple-mfi-fastcharge/unbind
```

### Crash Reports Won't Pull

```bash
# The device must be unlocked for crash reports to sync
# Try: unlock the iPhone, wait 10 seconds, re-run ritoras-crashes
idevicecrashreport -u <UDID> -e /tmp/all-crashes
```

### Permission Denied on /dev/bus/usb

This is a host-side issue. Verify the container was started with `--device /dev/bus/usb` or the equivalent bind mount. Contact the host administrator.

## Verification Checklist

- [ ] `ritoras-debug` shows "iPhone: CONNECTED" with correct device name and iOS version
- [ ] `ritoras-logs` streams log output when the device is active (use a dev-signed build for visible logs)
- [ ] `ritoras-crashes` completes without errors (may report "0 crashes" — that's fine)
- [ ] `pymobiledevice3 version` returns version number
- [ ] `idev status` shows running usbmuxd

## Evidence

- pymobiledevice3 9.36.0 installed and verified on opencode-js container (Python 3.12 slim-bookworm)
- Bundle identifiers discovered from `project.yml`: `com.ritoras.app` (main), `com.ritoras.app.keyboard` (keyboard)
- Helper scripts at `/usr/local/bin/ritoras-{debug,logs,crashes}` tested with graceful failure when no iPhone connected
- Dockerfile at `/home/michael/.config/opencode/sandbox/Dockerfile` updated with pymobiledevice3 pip install + script COPY commands
- Dockerfile at `/home/michael/bin/docker/debian-opencode/Dockerfile` updated identically (not a symlink)
