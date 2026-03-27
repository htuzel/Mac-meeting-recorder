import Foundation

struct Config: Sendable {
    let gladiaApiKey: String
    let summaryEndpoint: String
    let summaryModel: String
    let recordingsDir: URL
    let transcriptionLanguage: String   // ISO 639-1, e.g. "tr", "en", "de"
    let vadMicThreshold: Double
    let vadSystemThreshold: Double
    let vadActivationSeconds: Double
    let vadSilenceTimeout: Double
    let vadCooldownSeconds: Double
    let vadCheckInterval: Double
    let sampleRate: Double

    static func load() -> Config {
        let env = Self.parseEnvFile()

        let gladiaKey = env["GLADIA_API_KEY"] ?? ""
        if gladiaKey.isEmpty {
            print("WARNING: GLADIA_API_KEY not found in .env")
        }

        let recordingsDirPath = (env["RECORDINGS_DIR"] ?? "~/MeetingRecordings")
            .replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        let recordingsDir = URL(fileURLWithPath: recordingsDirPath)

        return Config(
            gladiaApiKey: gladiaKey,
            summaryEndpoint: env["SUMMARY_ENDPOINT"] ?? "http://127.0.0.1:8000",
            summaryModel: env["SUMMARY_MODEL"] ?? "qwen3.5-122b-a10b-4bit",
            recordingsDir: recordingsDir,
            transcriptionLanguage: env["TRANSCRIPTION_LANGUAGE"] ?? "tr",
            vadMicThreshold: Double(env["VAD_MIC_THRESHOLD"] ?? "") ?? 0.01,
            vadSystemThreshold: Double(env["VAD_SYSTEM_THRESHOLD"] ?? "") ?? 0.005,
            vadActivationSeconds: Double(env["VAD_ACTIVATION_SECONDS"] ?? "") ?? 5.0,
            vadSilenceTimeout: Double(env["VAD_SILENCE_TIMEOUT"] ?? "") ?? 90.0,
            vadCooldownSeconds: Double(env["VAD_COOLDOWN_SECONDS"] ?? "") ?? 30.0,
            vadCheckInterval: Double(env["VAD_CHECK_INTERVAL"] ?? "") ?? 0.5,
            sampleRate: Double(env["SAMPLE_RATE"] ?? "") ?? 48000.0
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
