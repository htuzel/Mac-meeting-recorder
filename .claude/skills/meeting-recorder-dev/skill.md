---
name: meeting-recorder-dev
description: MeetingRecorder Swift projesinde geliştirme yaparken kullan. Mimari kurallar, deploy süreci, TCC izin yönetimi ve kritik kısıtlamalar. Kod değişikliği, debug veya deploy öncesi mutlaka oku.
---

# Meeting Recorder — Geliştirici Rehberi

## Proje Yeri
```
~/Documents/Flalingo/Projects/MeetingRecordings/
```

## Mimari Özet

```
AudioCapture (SCStream)
  ├─ mic output → mic.wav
  └─ sys output → system.wav
       ↓ stopRecording()
AudioMixer (Offline AVAudioEngine)
  └─ mic.wav + system.wav → mixed.m4a
       ↓
GladiaClient (URLSession async/await)
  └─ upload → transcribe → poll → transcript.txt + transcript.json
```

**Thread modeli:**
- `@MainActor`: MenuBarController, MeetingDetector, Timer
- `DispatchQueue("audio.writer")`: WAV dosya yazma — callback'ten asla doğrudan I/O yapma
- `os_unfair_lock`: RMS değerleri (micRMS, sysRMS) — Actor değil, overhead yok
- SCStream callback'leri: kendi serial queue'larında çalışır

---

## Kritik Kurallar

### 1. TCC İzinleri — EN ÖNEMLİ
**`codesign --force` ASLA çalıştırma** — her force re-sign, Microphone ve Screen Recording TCC iznini sıfırlar, kullanıcı tekrar izin vermek zorunda kalır.

```bash
# YANLIŞ — izinleri sıfırlar:
codesign --force --deep --sign - ~/Applications/MeetingRecorder.app

# DOĞRU — sadece imzasız ise imzalar:
if ! codesign -v ~/Applications/MeetingRecorder.app 2>/dev/null; then
    codesign --deep --sign - ~/Applications/MeetingRecorder.app
fi
```

`install.sh` zaten bu kontrolü yapıyor. Binary güncellerken sadece binary'yi kopyala, yeniden imzalama.

### 2. Deploy Süreci
```bash
# Build
swift build -c release

# Binary güncelle (imzalamadan)
cp .build/release/MeetingRecorder ~/Applications/MeetingRecorder.app/Contents/MacOS/MeetingRecorder

# Restart
launchctl bootout gui/$(id -u)/com.flalingo.meeting-recorder 2>/dev/null
sleep 1
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.flalingo.meeting-recorder.plist
```

### 3. Gladia API
- Header: `x-gladia-key: <key>` (Bearer değil)
- Endpoint: `/v2/transcription` (`/v2/pre-recorded` değil)
- Language: `language_config: { languages: ["tr"] }` (`language: "turkish"` değil)
- Enhanced diarization: `diarization_config: { enhanced: true }`
- Response path: `result → transcription → utterances[]`

### 4. SCStream
- `captureMicrophone: true` macOS 15+ gerektirir
- Hem Microphone hem Screen Recording TCC izni gerekir
- Video frame'leri minimize et: `width: 2, height: 2, minimumFrameInterval: CMTime(value:1,timescale:1)`
- `didStopWithError` delegate'ini implement et — stream ölürse 3s bekle, restart

### 5. Config
`.env` parse önceliği: `~/.config/meeting-recorder/.env` → `~/MeetingRecordings/.env`

Desteklenen değişkenler:
```
GLADIA_API_KEY, TRANSCRIPTION_LANGUAGE, RECORDINGS_DIR, SAMPLE_RATE
VAD_MIC_THRESHOLD, VAD_SYSTEM_THRESHOLD, VAD_ACTIVATION_SECONDS
VAD_SILENCE_TIMEOUT, VAD_COOLDOWN_SECONDS, VAD_CHECK_INTERVAL
```

---

## Dosya Yapısı

```
Sources/MeetingRecorder/
├── main.swift             # Lock file (flock), NSApp setup
├── Config.swift           # .env parser
├── Logger.swift           # ~/MeetingRecordings/logs/app.log, rotating 10MB
├── SessionManager.swift   # Session dirs, metadata, pending_uploads.json
├── AudioCapture.swift     # SCStream: mic + system, RMS, WAV yazma
├── MeetingDetector.swift  # VAD FSM: idle → recording → cooldown → idle
├── AudioMixer.swift       # Offline AVAudioEngine → M4A/AAC 128kbps
├── GladiaClient.swift     # Upload + transcribe + poll, retry 3x exp backoff
└── MenuBarController.swift # NSStatusItem, Timer, App Nap, orchestration
Resources/
├── Info.plist             # com.flalingo.meeting-recorder, LSUIElement=true
└── icon.icns
```

---

## Servisler

```bash
# Durum kontrol
launchctl list com.flalingo.meeting-recorder
launchctl list com.flalingo.gather-listener

# Log takip
tail -f ~/MeetingRecordings/logs/app.log

# Restart
launchctl bootout gui/$(id -u)/com.flalingo.meeting-recorder
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.flalingo.meeting-recorder.plist
```

---

## Yaygın Hatalar

| Hata | Sebep | Çözüm |
|------|-------|-------|
| `declined TCCs for application` | Screen Recording izni yok | System Settings → Privacy → Screen Recording → izin ver |
| `No display found for SCStream` | Ekran kapalı/uyku | Wake notification handler devreye girer, otomatik restart |
| Gladia 401 | Header yanlış | `x-gladia-key` kullan, `Authorization: Bearer` değil |
| Gladia 400 | language_config format | `{"languages": ["tr"]}` kullan |
| 0 utterances | Response path yanlış | `result.transcription.utterances` yolunu kullan |
| TCC sürekli soruluyor | `codesign --force` çalıştırıldı | Yukarıdaki kural #1'e bak |
