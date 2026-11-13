import Foundation

struct Config: Sendable {
    let gladiaApiKey: String
    let summaryEnabled: Bool
    let summaryEndpoint: String
    let summaryModel: String
    let recordingsDir: URL
    let transcriptionLanguage: String   // ISO 639-1, e.g. "tr", "en", "de"

    // VAD levels: the *peak* buffer RMS seen during a tick must exceed these
    // for that tick to count as "active".
    let vadMicThreshold: Double
    let vadSystemThreshold: Double
    // Start: each side must be active for at least `vadActivationSeconds`
    // (cumulative) within the last `vadActivationWindow` seconds. The sides do
    // not have to be active at the same moment, so normal turn-taking counts.
    let vadActivationSeconds: Double
    let vadActivationWindow: Double
    // Stop: BOTH sides silent for `vadSilenceTimeout`, then `vadCooldownSeconds`
    // more before the session is closed. Any audio in between resumes the
    // same session.
    let vadSilenceTimeout: Double
    let vadCooldownSeconds: Double
    let vadCheckInterval: Double
    let sampleRate: Double

    // Transcription queue
    let minTranscribeSeconds: Double      // clips shorter than this are never uploaded
    let minActiveSeconds: Double          // auto sessions with less detected speech are skipped
    let transcribeMaxAttempts: Int
    let transcribeRetryBaseMinutes: Double
    let backlogScanMinutes: Double

    static func load() -> Config {
        let env = Self.parseEnvFile()

        let gladiaKey = env["GLADIA_API_KEY"] ?? ""
        if gladiaKey.isEmpty {
            print("WARNING: GLADIA_API_KEY not found in .env")
        }

        let recordingsDirPath = (env["RECORDINGS_DIR"] ?? "~/MeetingRecordings")
            .replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        let recordingsDir = URL(fileURLWithPath: recordingsDirPath)

        func double(_ key: String, _ fallback: Double) -> Double {
            Double(env[key] ?? "") ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            guard let raw = env[key]?.lowercased() else { return fallback }
            return ["1", "true", "yes", "on"].contains(raw)
        }

        return Config(
            gladiaApiKey: gladiaKey,
            summaryEnabled: bool("SUMMARY_ENABLED", false),
            summaryEndpoint: env["SUMMARY_ENDPOINT"] ?? "http://127.0.0.1:8000",
            summaryModel: env["SUMMARY_MODEL"] ?? "qwen3.5-122b-a10b-4bit",
            recordingsDir: recordingsDir,
            transcriptionLanguage: env["TRANSCRIPTION_LANGUAGE"] ?? "tr",
            vadMicThreshold: double("VAD_MIC_THRESHOLD", 0.006),
            vadSystemThreshold: double("VAD_SYSTEM_THRESHOLD", 0.004),
            vadActivationSeconds: double("VAD_ACTIVATION_SECONDS", 1.5),
            vadActivationWindow: double("VAD_ACTIVATION_WINDOW", 30.0),
            vadSilenceTimeout: double("VAD_SILENCE_TIMEOUT", 240.0),
            vadCooldownSeconds: double("VAD_COOLDOWN_SECONDS", 30.0),
            vadCheckInterval: double("VAD_CHECK_INTERVAL", 0.5),
            sampleRate: double("SAMPLE_RATE", 48000.0),
            minTranscribeSeconds: double("MIN_TRANSCRIBE_SECONDS", 20.0),
            minActiveSeconds: double("MIN_ACTIVE_SECONDS", 15.0),
            transcribeMaxAttempts: Int(env["TRANSCRIBE_MAX_ATTEMPTS"] ?? "") ?? 5,
            transcribeRetryBaseMinutes: double("TRANSCRIBE_RETRY_BASE_MINUTES", 10.0),
            backlogScanMinutes: double("BACKLOG_SCAN_MINUTES", 15.0)
        )
    }

    private static func parseEnvFile() -> [String: String] {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/meeting-recorder/.env"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("MeetingRecordings/.env")
        ]

        var result: [String: String] = [:]

        for path in candidates {
            guard let contents = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    // Strip surrounding quotes
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    result[key] = value
                }
            }
        }

        return result
    }
}
