import Foundation

/// Turns a session folder's `mixed.m4a` into `transcript.json` + `transcript.txt`.
protocol Transcriber: Sendable {
    func transcribeSession(sessionDir: URL) async -> Bool
}

extension GladiaClient: Transcriber {}

/// ElevenLabs when ELEVENLABS_API_KEY is set (Gladia's contract ended on
/// 24 Nov 2026), otherwise Gladia as before.
func makeTranscriber(config: Config) -> any Transcriber {
    if !config.elevenLabsApiKey.isEmpty {
        return ElevenLabsClient(
            apiKey: config.elevenLabsApiKey,
            language: config.transcriptionLanguage,
            model: config.elevenLabsModel
        )
    }
    return GladiaClient(apiKey: config.gladiaApiKey, language: config.transcriptionLanguage)
}
