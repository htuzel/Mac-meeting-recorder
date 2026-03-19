import Foundation

final class GladiaClient: Sendable {
    private let apiKey: String
    private let language: String
    private let log = Logger.shared
    private let baseURL = "https://api.gladia.io"
    private let maxRetries = 3

    init(apiKey: String, language: String = "tr") {
        self.apiKey = apiKey
        self.language = language
    }

    // MARK: - Public API

    func transcribeSession(sessionDir: URL) async -> Bool {
        let mixedFile = sessionDir.appendingPathComponent("mixed.m4a")
        guard FileManager.default.fileExists(atPath: mixedFile.path) else {
            log.error("No mixed.m4a found in \(sessionDir.path)")
            return false
        }

        log.info("Starting transcription for \(sessionDir.lastPathComponent)")

        // Step 1: Upload
        guard let audioURL = await uploadAudio(fileURL: mixedFile) else {
            log.error("Upload failed")
            return false
        }

        // Step 2: Start transcription
        guard let (_, resultURL) = await startTranscription(audioURL: audioURL) else {
            log.error("Transcription start failed")
            return false
        }

        // Step 3: Poll for result
        guard let result = await pollResult(resultURL: resultURL) else {
            log.error("Polling failed or timed out")
            return false
        }

        // Step 4: Save transcript
        saveTranscript(sessionDir: sessionDir, result: result)
        log.info("Transcription complete for \(sessionDir.lastPathComponent)")
        return true
    }

    // MARK: - Upload

    private func uploadAudio(fileURL: URL) async -> String? {
        let endpoint = "\(baseURL)/v2/upload"

        for attempt in 1...maxRetries {
            do {
                let boundary = UUID().uuidString
                var request = URLRequest(url: URL(string: endpoint)!)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 300

                let fileData = try Data(contentsOf: fileURL)
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
                body.append(fileData)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                request.httpBody = body

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    log.warn("Upload attempt \(attempt) failed with status \(statusCode)")
                    if attempt < maxRetries {
                        try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                    }
                    continue
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let audioURL = json["audio_url"] as? String {
                    log.info("Upload successful: \(audioURL)")
                    return audioURL
                }
            } catch {
                log.warn("Upload attempt \(attempt) error: \(error.localizedDescription)")
                if attempt < maxRetries {
                    try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                }
            }
        }
        return nil
    }

    // MARK: - Start Transcription

    private func startTranscription(audioURL: String) async -> (jobId: String, resultURL: String)? {
        let endpoint = "\(baseURL)/v2/transcription"

        let body: [String: Any] = [
            "audio_url": audioURL,
            "diarization": true,
            "diarization_config": [
                "enhanced": true
            ],
            "language_config": [
                "languages": [language]
            ],
            "sentences": true
        ]

        for attempt in 1...maxRetries {
            do {
                var request = URLRequest(url: URL(string: endpoint)!)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 60
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...201).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    log.warn("Transcription start attempt \(attempt) failed with status \(statusCode)")
                    if attempt < maxRetries {
                        try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                    }
                    continue
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let jobId = json["id"] as? String,
                   let resultURL = json["result_url"] as? String {
                    log.info("Transcription started: job=\(jobId)")
                    return (jobId, resultURL)
                }
            } catch {
                log.warn("Transcription start attempt \(attempt) error: \(error.localizedDescription)")
                if attempt < maxRetries {
                    try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                }
            }
        }
        return nil
    }

    // MARK: - Poll Result

    private func pollResult(resultURL: String) async -> [String: Any]? {
        let maxPollTime: TimeInterval = 3600 // 60 minutes
        let pollInterval: TimeInterval = 10
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxPollTime {
            do {
                var request = URLRequest(url: URL(string: resultURL)!)
                request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
                request.timeoutInterval = 30

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    try await Task.sleep(for: .seconds(pollInterval))
                    continue
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    switch status {
                    case "done":
                        log.info("Transcription done")
                        return json
                    case "error":
                        log.error("Transcription failed on server side")
                        return nil
                    default:
                        log.debug("Transcription status: \(status)")
                    }
                }
            } catch {
                log.warn("Poll error: \(error.localizedDescription)")
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }

        log.error("Transcription polling timed out after \(Int(maxPollTime))s")
        return nil
    }

    // MARK: - Save Transcript

    private func saveTranscript(sessionDir: URL, result: [String: Any]) {
        // Save raw JSON
        let jsonURL = sessionDir.appendingPathComponent("transcript.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
            try? data.write(to: jsonURL)
        }

        // Save readable TXT
        let txtURL = sessionDir.appendingPathComponent("transcript.txt")
        var lines: [String] = []

        // Path: result → transcription → utterances
        let resultData = result["result"] as? [String: Any] ?? result
        let transcription = resultData["transcription"] as? [String: Any] ?? resultData
        let utterances = (transcription["utterances"] as? [[String: Any]])
            ?? (transcription["sentences"] as? [[String: Any]])
            ?? (resultData["utterances"] as? [[String: Any]])
            ?? []

        for utterance in utterances {
            let startTime = utterance["start"] as? Double ?? 0
            let speaker = utterance["speaker"] as? Int ?? utterance["channel"] as? Int ?? 0
            let text = utterance["text"] as? String ?? ""

            let hours = Int(startTime) / 3600
            let minutes = (Int(startTime) % 3600) / 60
            let seconds = Int(startTime) % 60
            let timestamp = String(format: "[%02d:%02d:%02d]", hours, minutes, seconds)

            lines.append("\(timestamp) Speaker \(speaker): \(text)")
        }

        let txtContent = lines.joined(separator: "\n")
        try? txtContent.write(to: txtURL, atomically: true, encoding: .utf8)

        log.info("Transcript saved: \(utterances.count) utterances")
    }
}
