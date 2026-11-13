@preconcurrency import AVFoundation
import Foundation

/// Per-session transcription bookkeeping, stored as
/// `<session>/transcription_status.json`. The brain only looks at
/// transcript.json / transcript.txt, so this file never changes what it ingests.
struct TranscriptionStatus: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case inProgress = "in_progress"
        case failed
        case failedPermanent = "failed_permanent"
        case done
        case skippedShort = "skipped_short"
        case skippedLowActivity = "skipped_low_activity"
        case skippedSilent = "skipped_silent"

        var isTerminal: Bool {
            switch self {
            case .inProgress, .failed: return false
            default: return true
            }
        }
    }

    var state: State
    var attempts: Int
    var lastAttempt: Date?
    var note: String?
    var updatedAt: Date
}

/// Serial transcription queue. Every session — fresh recordings and backlog
/// found on disk — goes through here, one upload at a time, so a session can
/// never be transcribed twice concurrently and failures are retried with
/// backoff instead of being forgotten when the app exits.
actor TranscriptionQueue {
    static let statusFileName = "transcription_status.json"

    private let config: Config
    private let gladia: GladiaClient
    private let summary: SummaryClient?
    private let notify: @Sendable (String) -> Void
    private let log = Logger.shared

    private var queue: [URL] = []
    private var queuedPaths: Set<String> = []
    private var isProcessing = false

    init(config: Config, gladia: GladiaClient, summary: SummaryClient?, notify: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.gladia = gladia
        self.summary = summary
        self.notify = notify
    }

    // MARK: - Public

    func enqueue(_ sessionDir: URL) {
        let key = sessionDir.standardizedFileURL.path
        guard !queuedPaths.contains(key) else { return }
        queuedPaths.insert(key)
        queue.append(sessionDir)
        log.info("Queued for transcription: \(sessionDir.lastPathComponent) (queue: \(queue.count))")
        startIfNeeded()
    }

    /// Finds sessions on disk that have audio but no transcript and are due
    /// for an (re)attempt. `excludingPath` is the session currently recording.
    func scanBacklog(excludingPath: String?) {
        let fm = FileManager.default
        let now = Date()
        var found = 0

        for session in Self.sessionDirs(in: config.recordingsDir) {
            let path = session.standardizedFileURL.path
            if path == excludingPath || queuedPaths.contains(path) { continue }

            let mixed = session.appendingPathComponent("mixed.m4a")
            guard fm.fileExists(atPath: mixed.path),
                  !fm.fileExists(atPath: session.appendingPathComponent("transcript.json").path) else { continue }

            // Leave files alone while they may still be written
            if let modified = (try? fm.attributesOfItem(atPath: mixed.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) < 120 { continue }

            if let status = Self.loadStatus(session) {
                if status.state.isTerminal { continue }
                if status.attempts >= config.transcribeMaxAttempts { continue }
                if let last = status.lastAttempt, status.attempts > 0 {
                    let backoff = config.transcribeRetryBaseMinutes * 60 * pow(2.0, Double(status.attempts - 1))
                    if now.timeIntervalSince(last) < backoff { continue }
                }
            }

            found += 1
            enqueue(session)
        }

        if found > 0 {
            log.info("Backlog scan: \(found) session(s) queued for transcription")
        }
    }

    // MARK: - Processing

    private func startIfNeeded() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let session = queue.removeFirst()
            await process(session)
            queuedPaths.remove(session.standardizedFileURL.path)
        }
        isProcessing = false
    }

    private func process(_ session: URL) async {
        let name = session.lastPathComponent
        let fm = FileManager.default

        if fm.fileExists(atPath: session.appendingPathComponent("transcript.json").path) {
            return
        }
        var status = Self.loadStatus(session)
            ?? TranscriptionStatus(state: .failed, attempts: 0, lastAttempt: nil, note: nil, updatedAt: Date())
        if status.state.isTerminal { return }

        let metadata = Self.loadMetadata(session)

        // 1. Too short to be a meeting
        let duration = (metadata["duration_seconds"] as? Double) ?? Self.audioDuration(session)
        if let duration, duration < config.minTranscribeSeconds {
            save(&status, session, state: .skippedShort, note: String(format: "%.0fs < %.0fs", duration, config.minTranscribeSeconds))
            log.info("Skipping \(name): too short (\(Int(duration))s)")
            return
        }

        // 2. Dead stream: nothing was captured on either side
        if let mic = metadata["mic_rms_avg"] as? Double, let sys = metadata["sys_rms_avg"] as? Double,
           mic == 0, sys == 0 {
            save(&status, session, state: .skippedSilent, note: "mic and system RMS were 0")
            log.info("Skipping \(name): no audio captured")
            return
        }

        // 3. Auto-started session with almost no speech (false trigger).
        //    Only sessions recorded by this version carry these fields;
        //    manual recordings are always transcribed.
        if (metadata["trigger"] as? String) == "auto",
           let micActive = metadata["mic_active_seconds"] as? Double,
           let sysActive = metadata["sys_active_seconds"] as? Double,
           micActive + sysActive < config.minActiveSeconds {
            save(&status, session, state: .skippedLowActivity,
                 note: String(format: "%.1fs speech detected < %.0fs", micActive + sysActive, config.minActiveSeconds))
            log.info("Skipping \(name): low activity (\(String(format: "%.1f", micActive + sysActive))s)")
            return
        }

        // Count the attempt before starting, so a file that crashes the app
        // still runs out of attempts.
        status.attempts += 1
        status.lastAttempt = Date()
        save(&status, session, state: .inProgress, note: nil)
        log.info("Transcribing \(name) (attempt \(status.attempts)/\(config.transcribeMaxAttempts))")

        let ok = await gladia.transcribeSession(sessionDir: session)
        if ok {
            save(&status, session, state: .done, note: nil)
            notify("Transcript ready: \(name)")
            if let summary {
                _ = await summary.summarizeSession(sessionDir: session)
            }
        } else if status.attempts >= config.transcribeMaxAttempts {
            save(&status, session, state: .failedPermanent, note: "gave up after \(status.attempts) attempts (see app.log)")
            log.error("Transcription permanently failed for \(name)")
            notify("Transcription failed permanently: \(name)")
        } else {
            save(&status, session, state: .failed, note: "attempt \(status.attempts) failed (see app.log)")
            log.warn("Transcription failed for \(name); will retry with backoff")
        }
    }

    private func save(_ status: inout TranscriptionStatus, _ session: URL, state: TranscriptionStatus.State, note: String?) {
        status.state = state
        status.note = note
        status.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(status) {
            try? data.write(to: session.appendingPathComponent(Self.statusFileName), options: .atomic)
        }
    }

    // MARK: - Helpers

    static func loadStatus(_ session: URL) -> TranscriptionStatus? {
        let url = session.appendingPathComponent(statusFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranscriptionStatus.self, from: data)
    }

    static func loadMetadata(_ session: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: session.appendingPathComponent("metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    static func audioDuration(_ session: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: session.appendingPathComponent("mixed.m4a")) else { return nil }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : nil
    }

    /// All `<recordings>/YYYY-MM-DD/meeting_*` directories, oldest first.
    static func sessionDirs(in recordingsDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let dateDirs = try? fm.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        var result: [URL] = []
        for dateDir in dateDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = dateDir.lastPathComponent
            guard dateDir.hasDirectoryPath, name.count == 10, name.contains("-") else { continue }
            guard let sessions = try? fm.contentsOfDirectory(
                at: dateDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }
            result.append(contentsOf: sessions
                .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("meeting_") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return result
    }
}
