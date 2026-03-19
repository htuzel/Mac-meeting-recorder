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

    func saveMetadata(sessionDir: URL, startTime: Date, endTime: Date, micRmsAvg: Double, sysRmsAvg: Double) {
        let metadata: [String: Any] = [
            "start_time": ISO8601DateFormatter().string(from: startTime),
            "end_time": ISO8601DateFormatter().string(from: endTime),
            "duration_seconds": endTime.timeIntervalSince(startTime),
            "mic_rms_avg": micRmsAvg,
            "sys_rms_avg": sysRmsAvg,
            "version": "2.0-swift"
        ]

        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: metadataURL)
            log.info("Saved metadata to \(metadataURL.path)")
        }
    }

    // MARK: - Pending Uploads

    private var pendingFile: URL {
        config.recordingsDir.appendingPathComponent("pending_uploads.json")
    }

    func addPendingUpload(sessionDir: URL) {
        var pending = loadPending()
        let entry = sessionDir.path
        if !pending.contains(entry) {
            pending.append(entry)
            savePending(pending)
            log.info("Added pending upload: \(entry)")
        }
    }

    func popPendingUploads() -> [URL] {
        let pending = loadPending()
        if !pending.isEmpty {
            savePending([])
            log.info("Popped \(pending.count) pending uploads")
        }
        return pending.map { URL(fileURLWithPath: $0) }
    }

    func findOrphanedSessions() -> [URL] {
        let fm = FileManager.default
        var orphaned: [URL] = []

        guard let dateDirs = try? fm.contentsOfDirectory(
            at: config.recordingsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        for dateDir in dateDirs {
            guard dateDir.hasDirectoryPath else { continue }
            let dirName = dateDir.lastPathComponent
            // Skip non-date directories like "logs"
            guard dirName.count == 10, dirName.contains("-") else { continue }

            guard let sessions = try? fm.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for session in sessions {
                guard session.hasDirectoryPath,
                      session.lastPathComponent.hasPrefix("meeting_") else { continue }

                let mixedFile = session.appendingPathComponent("mixed.m4a")
                let transcriptFile = session.appendingPathComponent("transcript.json")

                // Has mixed audio but no transcript = orphaned
                if fm.fileExists(atPath: mixedFile.path) &&
                   !fm.fileExists(atPath: transcriptFile.path) {
                    orphaned.append(session)
                }
            }
        }

        if !orphaned.isEmpty {
            log.info("Found \(orphaned.count) orphaned sessions")
        }
        return orphaned
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

    // MARK: - Private

    private func loadPending() -> [String] {
        guard let data = try? Data(contentsOf: pendingFile),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return array
    }

    private func savePending(_ entries: [String]) {
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted) {
            try? data.write(to: pendingFile)
        }
    }
}
