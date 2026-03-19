# Private Meeting Recorder

A macOS menu bar app that **automatically records your meetings** — no buttons, no setup per meeting. It listens for simultaneous microphone + system audio activity, starts recording, then transcribes everything when the meeting ends.

Built with Swift + ScreenCaptureKit. No virtual audio devices (BlackHole, Multi-Output Device) required.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## How It Works

```
Mic + System Audio active for 5s → Recording starts automatically
             ↓
        Mixed to M4A
             ↓
    Transcribed via Gladia API
             ↓
  transcript.txt + transcript.json saved
```

**Voice Activity Detection (VAD):** Recording only starts when *both* your microphone and system audio are active simultaneously — this avoids false positives from music, YouTube, or one-sided calls.

---

## Requirements

- **macOS 15 (Sequoia) or later** — required for `SCStream.captureMicrophone`
- **Xcode Command Line Tools** — `xcode-select --install`
- **Gladia API key** — free tier available at [app.gladia.io](https://app.gladia.io)

---

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/yourname/meeting-recorder
cd meeting-recorder
```

### 2. Configure

```bash
mkdir -p ~/.config/meeting-recorder
cp .env.example ~/.config/meeting-recorder/.env
```

Edit `~/.config/meeting-recorder/.env` and add your Gladia API key:

```
GLADIA_API_KEY=your_key_here
```

### 3. Install

```bash
chmod +x install.sh
./install.sh
```

This will:
- Build the Swift binary in release mode
- Create `~/Applications/MeetingRecorder.app`
- Install and start a LaunchAgent (auto-starts on login)
- Ad-hoc sign the app so macOS permissions persist

### 4. Grant Permissions

On first launch, macOS will ask for:
- **Screen Recording** — required by ScreenCaptureKit to capture system audio
- **Microphone** — to capture your voice

Grant both in System Settings → Privacy & Security.

---

## Usage

The app lives in your menu bar:

| Status | Meaning |
|--------|---------|
| `[idle]` | Monitoring audio, not recording |
| `REC` | Recording in progress |
| `...` | Cooldown — processing will start soon |

**Manual control:** Click the menu bar icon → Start/Stop Recording

**Recordings location:** `~/MeetingRecordings/YYYY-MM-DD/meeting_HHMMSS/`

Each session contains:
```
meeting_HHMMSS/
├── mixed.m4a        ← Audio (mic + system, mixed)
├── transcript.txt   ← [HH:MM:SS] Speaker N: text
├── transcript.json  ← Full Gladia API response
└── metadata.json    ← Duration, timestamps, RMS averages
```

---

## Configuration

All settings live in `~/.config/meeting-recorder/.env`. See [`.env.example`](.env.example) for all options.

Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `GLADIA_API_KEY` | — | Required |
| `VAD_ACTIVATION_SECONDS` | `5` | Seconds of dual-activity before recording starts |
| `VAD_SILENCE_TIMEOUT` | `45` | Seconds of silence before stopping |
| `VAD_COOLDOWN_SECONDS` | `15` | Cooldown before returning to idle |
| `RECORDINGS_DIR` | `~/MeetingRecordings` | Where to save recordings |

---

## Architecture

```
┌──────────────────────────────┐
│  NSStatusItem (Menu Bar)     │
│  [idle] / REC / ...          │
└──────────┬───────────────────┘
           │ Timer (0.5s)
    ┌──────▼──────┐
    │  Meeting    │
    │  Detector   │ ← mic_rms + sys_rms
    │  (VAD FSM)  │
    └──────┬──────┘
           │ state change
    ┌──────▼─────────────────────────┐
    │  AudioCapture (SCStream)       │
    │  ├─ .microphone → mic.wav      │
    │  └─ .audio → system.wav       │
    └──────┬─────────────────────────┘
           │ on stop
    ┌──────▼──────────────┐
    │   AudioMixer         │ mic.wav + system.wav → mixed.m4a
    │   GladiaClient       │ Upload → Transcribe → Poll → Save
    └──────────────────────┘
```

**Key design decisions:**
- **Single SCStream** (`captureMicrophone: true` + `capturesAudio: true`) — no BlackHole, no Multi-Output Device
- **Offline AVAudioEngine** for mixing — handles sample rate conversion automatically
- **.app bundle** — required for macOS TCC (microphone + screen recording permissions)
- **App Nap protection** — `beginActivity(.idleSystemSleepDisabled)` during recording
- **Auto-recovery** — restarts SCStream after sleep/wake or 2 minutes of zero RMS

---

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.flalingo.meeting-recorder
rm -rf ~/Applications/MeetingRecorder.app
rm ~/Library/LaunchAgents/com.flalingo.meeting-recorder.plist
```

---

## Customizing the Bundle ID

If you want to change the bundle identifier (e.g. `com.yourname.meeting-recorder`):

1. Edit `Resources/Info.plist` → `CFBundleIdentifier`
2. Edit `com.flalingo.meeting-recorder.plist` → rename the file and update `Label`
3. Run `./install.sh`
4. Re-grant Screen Recording permission (TCC resets on bundle ID change)

---

## Transcription

Powered by [Gladia](https://gladia.io) v2 API:
- Language: Turkish (`tr`) — change `language_config` in `GladiaClient.swift` for other languages
- Enhanced diarization: enabled (speaker separation)
- Speaker labels: `Speaker 0`, `Speaker 1`, etc.
- Free tier: 10 hours/month

---

## Claude Code / AI Development

This repo includes a Claude Code skill for working on the codebase:

```bash
cp -r .claude/skills/meeting-recorder-dev ~/.claude/skills/
```

Then in any Claude Code session, use `/meeting-recorder-dev` to load architecture rules, deploy instructions, and common pitfalls before making changes.

---

## License

MIT — see [LICENSE](LICENSE)
