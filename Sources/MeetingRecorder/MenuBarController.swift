import AppKit
import UserNotifications

@MainActor
final class MenuBarController: NSObject {
    private let config: Config
    private let sessionManager: SessionManager
    private let audioCapture: AudioCapture
    private let detector: MeetingDetector
    private let mixer = AudioMixer()
    private let gladiaClient: GladiaClient
    private let summaryClient: SummaryClient
    private let log = Logger.shared

    private let statusItem: NSStatusItem
    private var vadTimer: Timer?
    private var activityToken: NSObjectProtocol?

    // Recording state
    private var currentSessionDir: URL?
    private var recordingStartTime: Date?
    private var previousState: DetectorState = .idle

    // Auto-recovery: count consecutive zero-RMS ticks
    private var zeroRMSTicks: Int = 0
    private let maxZeroRMSTicks = 240 // 240 * 0.5s = 2 minutes

    // Menu items
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!

    init(config: Config) {
        self.config = config
        self.sessionManager = SessionManager(config: config)
        self.audioCapture = AudioCapture(config: config)
        self.detector = MeetingDetector(config: config)
        self.gladiaClient = GladiaClient(apiKey: config.gladiaApiKey, language: config.transcriptionLanguage)
        self.summaryClient = SummaryClient(endpoint: config.summaryEndpoint, model: config.summaryModel)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        setupMenu()
        requestNotificationPermission()
        startMonitoringAndVAD()
        retryPendingUploads()
    }

    // MARK: - Menu Setup

    private func setupMenu() {
        statusItem.button?.title = "[idle]"

        let menu = NSMenu()

        startItem = NSMenuItem(title: "Start Recording", action: #selector(manualStart), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        stopItem = NSMenuItem(title: "Stop Recording", action: #selector(manualStop), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Recordings", action: #selector(openRecordings), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func manualStart() {
        detector.forceRecording()
        handleStateTransition(to: .recording)
    }

    @objc private func manualStop() {
        detector.forceStop()
        handleStateTransition(to: .idle)
    }

    @objc private func openRecordings() {
        NSWorkspace.shared.open(config.recordingsDir)
    }

    @objc private func quitApp() {
        if currentSessionDir != nil {
            manualStop()
        }
        // Give post-processing a moment to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Monitoring & VAD

    private func startMonitoringAndVAD() {
        Task {
            do {
                try await audioCapture.startMonitoring()
                log.info("Audio monitoring started, beginning VAD timer")
            } catch {
                log.error("Failed to start audio monitoring: \(error.localizedDescription)")
                sendNotification(title: "Meeting Recorder", body: "Failed to start audio monitoring. Check permissions.")
            }
        }

        vadTimer = Timer.scheduledTimer(withTimeInterval: config.vadCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.vadTick()
            }
        }
    }

    private func vadTick() {
        let micRMS = audioCapture.micRMS
        let sysRMS = audioCapture.sysRMS

        // Auto-recovery: detect dead stream
        if micRMS == 0 && sysRMS == 0 {
            zeroRMSTicks += 1
            if zeroRMSTicks >= maxZeroRMSTicks {
                zeroRMSTicks = 0
                log.warn("Zero RMS for \(maxZeroRMSTicks) ticks — restarting stream")
                Task {
                    await audioCapture.restart()
                }
            }
        } else {
            zeroRMSTicks = 0
        }

        let newState = detector.check(micRMS: micRMS, sysRMS: sysRMS)

        if newState != previousState {
            handleStateTransition(to: newState)
            previousState = newState
        }
    }

    // MARK: - State Transitions

    private func handleStateTransition(to newState: DetectorState) {
        switch newState {
        case .recording:
            guard currentSessionDir == nil else { return }
            let sessionDir = sessionManager.createSessionDir()
            currentSessionDir = sessionDir
            recordingStartTime = Date()
            audioCapture.startRecording(sessionDir: sessionDir)

            statusItem.button?.title = "REC"
            startItem.isEnabled = false
            stopItem.isEnabled = true

            // App Nap protection
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recording meeting"
            )

            sendNotification(title: "Meeting Recorder", body: "Recording started")
            log.info("→ RECORDING: \(sessionDir.lastPathComponent)")

        case .cooldown:
            statusItem.button?.title = "..."
            log.info("→ COOLDOWN")

        case .idle:
            guard let sessionDir = currentSessionDir else {
                statusItem.button?.title = "[idle]"
                return
            }

            let startTime = recordingStartTime ?? Date()
            audioCapture.stopRecording()

            // End App Nap protection
            activityToken = nil

            currentSessionDir = nil
            recordingStartTime = nil
            statusItem.button?.title = "[idle]"
            startItem.isEnabled = true
            stopItem.isEnabled = false

            log.info("→ IDLE: recording stopped")

            // Post-process in background
            let micAvg = audioCapture.micRMSAvg
            let sysAvg = audioCapture.sysRMSAvg
            Task {
                await postProcess(sessionDir: sessionDir, startTime: startTime, endTime: Date(), micRmsAvg: micAvg, sysRmsAvg: sysAvg)
            }
        }
    }

    // MARK: - Post Processing

    private func postProcess(sessionDir: URL, startTime: Date, endTime: Date, micRmsAvg: Double, sysRmsAvg: Double) async {
        sessionManager.saveMetadata(sessionDir: sessionDir, startTime: startTime, endTime: endTime, micRmsAvg: micRmsAvg, sysRmsAvg: sysRmsAvg)

        // Mix audio
        log.info("Mixing audio...")
        guard let _ = mixer.mixAndCompress(sessionDir: sessionDir) else {
            log.error("Audio mixing failed for \(sessionDir.lastPathComponent)")
            sendNotification(title: "Meeting Recorder", body: "Audio mixing failed")
            return
        }

        sessionManager.cleanupRawWav(sessionDir: sessionDir)
        sendNotification(title: "Meeting Recorder", body: "Audio mixed. Starting transcription...")

        // Transcribe
        let success = await gladiaClient.transcribeSession(sessionDir: sessionDir)
        if success {
            let summarized = await summaryClient.summarizeSession(sessionDir: sessionDir)
            let msg = summarized ? "Transcription & summary complete!" : "Transcription complete (summary skipped)."
            sendNotification(title: "Meeting Recorder", body: msg)
        } else {
            sessionManager.addPendingUpload(sessionDir: sessionDir)
            sendNotification(title: "Meeting Recorder", body: "Transcription failed. Will retry later.")
        }
    }

    // MARK: - Retry Pending

    private func retryPendingUploads() {
        Task {
            // Retry orphaned sessions
            let orphaned = sessionManager.findOrphanedSessions()
            for session in orphaned {
                log.info("Retrying orphaned session: \(session.lastPathComponent)")
                let success = await gladiaClient.transcribeSession(sessionDir: session)
                if success {
                    _ = await summaryClient.summarizeSession(sessionDir: session)
                } else {
                    sessionManager.addPendingUpload(sessionDir: session)
                }
            }

            // Retry pending uploads
            let pending = sessionManager.popPendingUploads()
            for session in pending {
                log.info("Retrying pending upload: \(session.lastPathComponent)")
                let success = await gladiaClient.transcribeSession(sessionDir: session)
                if success {
                    _ = await summaryClient.summarizeSession(sessionDir: session)
                } else {
                    sessionManager.addPendingUpload(sessionDir: session)
                }
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.shared.warn("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.shared.warn("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
}
