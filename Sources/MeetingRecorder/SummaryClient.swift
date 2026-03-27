import Foundation

final class SummaryClient: Sendable {
    private let log = Logger.shared
    private let endpoint: String
    private let model: String
    private let maxTranscriptChars = 80_000

    init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }

    func summarizeSession(sessionDir: URL) async -> Bool {
        let txtURL = sessionDir.appendingPathComponent("transcript.txt")
        guard let transcript = try? String(contentsOf: txtURL, encoding: .utf8),
              !transcript.isEmpty else {
            log.warn("No transcript.txt found for summary in \(sessionDir.lastPathComponent)")
            return false
        }

        // Skip very short transcripts (< 100 chars likely noise)
        guard transcript.count > 100 else {
            log.info("Transcript too short to summarize: \(sessionDir.lastPathComponent)")
            return false
        }

        let trimmed = transcript.count > maxTranscriptChars
            ? String(transcript.prefix(maxTranscriptChars)) + "\n[...truncated]"
            : transcript

        log.info("Generating summary for \(sessionDir.lastPathComponent)")

        guard let summary = await callOMLX(transcript: trimmed) else {
            log.error("Summary generation failed for \(sessionDir.lastPathComponent)")
            return false
        }

        let summaryURL = sessionDir.appendingPathComponent("summary.txt")
        do {
            try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
            log.info("Summary saved for \(sessionDir.lastPathComponent)")
            return true
        } catch {
            log.error("Failed to write summary: \(error.localizedDescription)")
            return false
        }
    }

    private func callOMLX(transcript: String) async -> String? {
        let url = "\(endpoint)/v1/chat/completions"

        let systemPrompt = """
        Sen Flalingo'da bir toplantı özeti asistanısın. Toplantılar Flalingo online İngilizce eğitim platformunun ekibi tarafından yapılıyor.

        Bağlam: Flalingo, Türkiye merkezli online İngilizce öğretim platformu. Ekipte yazılım geliştirme, ürün yönetimi, öğretmen operasyonları, müşteri deneyimi ve pazarlama ekipleri var.

        Verilen toplantı transkriptini analiz et ve Türkçe olarak özet çıkar.

        Özet formatı:
        ## Toplantı Özeti
        [2-3 cümle genel özet]

        ## Katılımcılar
        [Konuşmacılar - tespit edebildiğin kadar]

        ## Ana Konular
        - [Tartışılan ana konular]

        ## Kararlar
        - [Alınan kararlar - varsa]

        ## Aksiyon Öğeleri
        - [Yapılması gereken işler - varsa]

        Kısa ve öz tut. Maksimum 500 kelime. /no_think
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Bu toplantının transkripti:\n\n\(transcript)"]
            ]
        ]

        do {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                log.error("OMLX API error \(statusCode): \(responseBody.prefix(200))")
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            log.error("Unexpected OMLX API response format")
            return nil
        } catch {
            log.error("OMLX API request failed: \(error.localizedDescription)")
            return nil
        }
    }
}
