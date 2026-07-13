# Ritoras

**Ritoras** is an open-source custom iOS keyboard extension that records audio and sends it to a self-hosted Whisper transcription server over Tailscale. Designed for personal sideloading — no Mac required, no paid Apple Developer account needed.

Ritoras is built entirely greenfield (no forks of closed-source iOS keyboard apps).

## Architecture

| Layer | Tech |
|---|---|
| Keyboard extension | UIKit `UIInputViewController` (Jetsam-safe, ~48 MB cap) |
| Container app | SwiftUI (settings & onboarding) |
| Audio capture | `AVAudioRecorder` → 16 kHz mono AAC `.m4a` |
| API client | `URLSession` multipart POST to OpenAI-compatible `/v1/audio/transcriptions` |
| Build system | XcodeGen → GitHub Actions (macos-14, free & unlimited for public repos) |
| Signing / sideload | Ad-hoc `.ipa` in CI → SideStore on-device signing |
| Network | Tailscale HTTPS (or plain HTTP with ATS exception) |

## Implementation Plan

See [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md) for the full phase roadmap, risk register, and design decisions.

## Prerequisites

- An iPhone running iOS 17+
- A self-hosted OpenAI-compatible Whisper server (e.g., faster-whisper, whisper.cpp, or Diction's gateway)
- Tailscale (or alternative) for network connectivity to your Whisper server
- A free Apple ID (for SideStore on-device signing)
- SideStore installed on the iPhone

## License

MIT
