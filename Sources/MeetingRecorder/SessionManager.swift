import Foundation

final class SessionManager: Sendable {
    private let config: Config
    private let log = Logger.shared

    init(config: Config) {
        self.config = config
        try? FileManager.default.createDirectory(at: config.recordingsDir, withIntermediateDirectories: true)
    }

    func createSessionDir() -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timeStr = timeFormatter.string(from: Date())

        let sessionDir = config.recordingsDir
            .appendingPathComponent(dateStr)
            .appendingPathComponent("meeting_\(timeStr)")

        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        log.info("Created session directory: \(sessionDir.path)")
        return sessionDir
    }

    func saveMetadata(
        sessionDir: URL, startTime: Date, endTime: Date,
        micRmsAvg: Double, sysRmsAvg: Double,
        micActiveSeconds: Double, sysActiveSeconds: Double, trigger: String
    ) {
        let metadata: [String: Any] = [
            "start_time": ISO8601DateFormatter().string(from: startTime),
            "end_time": ISO8601DateFormatter().string(from: endTime),
            "duration_seconds": endTime.timeIntervalSince(startTime),
            "mic_rms_avg": micRmsAvg,
            "sys_rms_avg": sysRmsAvg,
            "mic_active_seconds": micActiveSeconds,
            "sys_active_seconds": sysActiveSeconds,
            "trigger": trigger,   // "auto" | "manual"
            "version": "2.1-swift"
        ]

        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: metadataURL)
            log.info("Saved metadata to \(metadataURL.path)")
        }
    }

    // MARK: - Legacy pending uploads

    /// Older builds kept failed sessions in pending_uploads.json. The
    /// transcription queue now finds them by scanning disk, so just clear it.
    func clearLegacyPendingUploads() {
        let pendingFile = config.recordingsDir.appendingPathComponent("pending_uploads.json")
        guard let data = try? Data(contentsOf: pendingFile),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String],
              !entries.isEmpty else { return }
        try? Data("[]".utf8).write(to: pendingFile)
        log.info("Cleared \(entries.count) legacy pending uploads (backlog scan will pick them up)")
    }

    func cleanupRawWav(sessionDir: URL) {
        let fm = FileManager.default
        for name in ["mic.wav", "system.wav"] {
            let file = sessionDir.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
                log.debug("Cleaned up \(name)")
            }
        }
    }
}
