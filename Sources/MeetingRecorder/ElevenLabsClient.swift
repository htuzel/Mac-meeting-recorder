import Foundation

/// ElevenLabs Scribe speech-to-text. Gladia's contract ended on 24 Nov 2026.
///
/// One synchronous request: the transcript comes back in the response, so
/// there is no upload or polling step. Output files keep Gladia's layout:
/// `transcript.txt` lines are `[hh:mm:ss] Speaker N: text` (what
/// SummaryClient reads), and `transcript.json` carries the utterances under
/// `result.transcription.utterances` plus Scribe's raw response under `raw`.
final class ElevenLabsClient: Transcriber {
    private let apiKey: String
    private let language: String
    private let model: String
    private let log = Logger.shared
    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private let maxRetries = 3
    /// A new utterance starts when the speaker changes or after this pause (seconds).
    private let pauseSplit: Double = 1.5

    init(apiKey: String, language: String = "tr", model: String = "scribe_v3") {
        self.apiKey = apiKey
        self.language = language
        self.model = model
    }

    // MARK: - Public API

    func transcribeSession(sessionDir: URL) async -> Bool {
        let mixedFile = sessionDir.appendingPathComponent("mixed.m4a")
        guard FileManager.default.fileExists(atPath: mixedFile.path) else {
            log.error("No mixed.m4a found in \(sessionDir.path)")
            return false
        }

        log.info("Starting transcription (ElevenLabs \(model)) for \(sessionDir.lastPathComponent)")

        guard let result = await transcribe(fileURL: mixedFile) else {
            log.error("Transcription failed")
            return false
        }

        saveTranscript(sessionDir: sessionDir, result: result)
        log.info("Transcription complete for \(sessionDir.lastPathComponent)")
        return true
    }

    // MARK: - Request

    private func transcribe(fileURL: URL) async -> [String: Any]? {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            log.error("Cannot read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", model)
        field("diarize", "true")
        field("timestamps_granularity", "word")
        field("tag_audio_events", "false")
        if !language.isEmpty {
            field("language_code", language)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        for attempt in 1...maxRetries {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            // The transcript is produced while the connection waits; long
            // meetings need a generous idle timeout.
            request.timeoutInterval = 1800

            do {
                let (data, response) = try await URLSession.shared.upload(for: request, from: body)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return json
                }
                let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                log.warn("Transcription attempt \(attempt) failed with status \(status): \(detail)")
                // A 4xx other than 429 will not change on retry (the queue retries later anyway).
                if status != 429 && status < 500 {
                    return nil
                }
            } catch {
                log.warn("Transcription attempt \(attempt) error: \(error.localizedDescription)")
            }
            if attempt < maxRetries {
                try? await Task.sleep(for: .seconds(5 * pow(2.0, Double(attempt))))
            }
        }
        return nil
    }

    // MARK: - Save Transcript

    private func saveTranscript(sessionDir: URL, result: [String: Any]) {
        let words = ((result["words"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "word" }

        // Speakers numbered in order of first appearance, like Gladia's.
        var speakerIndex: [String: Int] = [:]
        var utterances: [[String: Any]] = []
        var curSpeaker = -1
        var curStart = 0.0
        var curEnd = 0.0
        var curTexts: [String] = []

        func flush() {
            guard !curTexts.isEmpty else { return }
            utterances.append([
                "start": curStart,
                "end": curEnd,
                "speaker": curSpeaker,
                "text": curTexts.joined(separator: " "),
            ])
            curTexts = []
        }

        for word in words {
            guard let start = word["start"] as? Double,
                  let end = word["end"] as? Double,
                  let text = (word["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty else { continue }
            let rawSpeaker = word["speaker_id"] as? String ?? "speaker_0"
            let speaker: Int
            if let known = speakerIndex[rawSpeaker] {
                speaker = known
            } else {
                speaker = speakerIndex.count
                speakerIndex[rawSpeaker] = speaker
            }
            if speaker != curSpeaker || start - curEnd >= pauseSplit {
                flush()
                curSpeaker = speaker
                curStart = start
            }
            curTexts.append(text)
            curEnd = end
        }
        flush()

        let jsonURL = sessionDir.appendingPathComponent("transcript.json")
        let document: [String: Any] = [
            "provider": "elevenlabs",
            "model": model,
            "result": [
                "transcription": [
                    "full_transcript": result["text"] as? String ?? "",
                    "utterances": utterances,
                ],
            ],
            "raw": result,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: .prettyPrinted) {
            try? data.write(to: jsonURL)
        }

        let lines = utterances.map { utterance -> String in
            let startTime = utterance["start"] as? Double ?? 0
            let speaker = utterance["speaker"] as? Int ?? 0
            let text = utterance["text"] as? String ?? ""
            let hours = Int(startTime) / 3600
            let minutes = (Int(startTime) % 3600) / 60
            let seconds = Int(startTime) % 60
            return String(format: "[%02d:%02d:%02d] Speaker %d: %@", hours, minutes, seconds, speaker, text)
        }
        let txtURL = sessionDir.appendingPathComponent("transcript.txt")
        try? lines.joined(separator: "\n").write(to: txtURL, atomically: true, encoding: .utf8)

        log.info("Transcript saved: \(utterances.count) utterances, \(speakerIndex.count) speakers")
    }
}
