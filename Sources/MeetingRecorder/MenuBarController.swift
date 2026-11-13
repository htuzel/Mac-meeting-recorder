import AppKit
import UserNotifications

@MainActor
final class MenuBarController: NSObject {
    private let config: Config
    private let sessionManager: SessionManager
    private let audioCapture: AudioCapture
    private let detector: MeetingDetector
    private let mixer = AudioMixer()
    private var transcriptionQueue: TranscriptionQueue!
    private let log = Logger.shared

    private let statusItem: NSStatusItem
    private var vadTimer: Timer?
    private var backlogTimer: Timer?
    private var activityToken: NSObjectProtocol?

    // Recording state
    private var currentSessionDir: URL?
    private var recordingStartTime: Date?
    private var currentTrigger = "auto"
    private var previousState: DetectorState = .idle

    // Pause (e.g. a private call). Quit no longer stops the recorder because
    // launchd relaunches it, so this is the way to opt out temporarily.
    private var pausedUntil: Date?

    // Auto-recovery: count consecutive zero-RMS ticks
    private var zeroRMSTicks: Int = 0
    private let maxZeroRMSTicks = 240 // 240 * 0.5s = 2 minutes

    // Menu items
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var pauseItem: NSMenuItem!

    init(config: Config) {
        self.config = config
        self.sessionManager = SessionManager(config: config)
        self.audioCapture = AudioCapture(config: config)
        self.detector = MeetingDetector(config: config)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        let gladia = GladiaClient(apiKey: config.gladiaApiKey, language: config.transcriptionLanguage)
        let summary = config.summaryEnabled
            ? SummaryClient(endpoint: config.summaryEndpoint, model: config.summaryModel)
            : nil
        log.info("Summaries \(config.summaryEnabled ? "enabled" : "disabled") (SUMMARY_ENABLED)")
        self.transcriptionQueue = TranscriptionQueue(
            config: config, gladia: gladia, summary: summary,
            notify: { [weak self] message in
                Task { @MainActor in self?.sendNotification(title: "Meeting Recorder", body: message) }
            }
        )

        setupMenu()
        requestNotificationPermission()
        startMonitoringAndVAD()
        startBacklogProcessing()
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

        pauseItem = NSMenuItem(title: "Pause Auto-Recording for 1 Hour", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Recordings", action: #selector(openRecordings), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // launchd (KeepAlive) relaunches the app after it exits, so "Quit"
        // effectively restarts it. Use Pause to stop recording temporarily.
        let quitItem = NSMenuItem(title: "Restart Recorder", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func manualStart() {
        pausedUntil = nil
        updatePauseUI()
        detector.forceRecording()
        currentTrigger = "manual"
        handleStateTransition(to: .recording)
        previousState = .recording
    }

    @objc private func manualStop() {
        detector.forceStop()
        handleStateTransition(to: .idle)
        previousState = .idle
    }

    @objc private func togglePause() {
        if isPaused {
            pausedUntil = nil
            detector.reset()
            log.info("Auto-recording resumed")
        } else {
            if currentSessionDir != nil { manualStop() }
            pausedUntil = Date().addingTimeInterval(3600)
            log.info("Auto-recording paused for 1 hour")
        }
        updatePauseUI()
    }

    private var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return Date() < until
    }

    private func updatePauseUI() {
        if isPaused {
            pauseItem.title = "Resume Auto-Recording"
            if currentSessionDir == nil { statusItem.button?.title = "[paused]" }
        } else {
            pauseItem.title = "Pause Auto-Recording for 1 Hour"
            if currentSessionDir == nil { statusItem.button?.title = "[idle]" }
        }
    }

    @objc private func openRecordings() {
        NSWorkspace.shared.open(config.recordingsDir)
    }

    @objc private func quitApp() {
        if currentSessionDir != nil {
            manualStop()
        }
        // Give post-processing a moment to start; unfinished transcriptions
        // are picked up again by the backlog scan on the next launch.
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
        let peaks = audioCapture.consumePeaks()

        // Auto-recovery: no buffers at all on either side = dead stream
        if peaks.mic == 0 && peaks.sys == 0 {
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

        if pausedUntil != nil {
            if isPaused { return }
            pausedUntil = nil
            detector.reset()
            updatePauseUI()
            log.info("Pause expired — auto-recording resumed")
        }

        let newState = detector.check(micLevel: peaks.mic, sysLevel: peaks.sys)

        if newState != previousState {
            if previousState == .idle && newState == .recording {
                currentTrigger = "auto"
            }
            handleStateTransition(to: newState)
            previousState = newState
        }
    }

    // MARK: - State Transitions

    private func handleStateTransition(to newState: DetectorState) {
        switch newState {
        case .recording:
            if currentSessionDir != nil {
                statusItem.button?.title = "REC"   // resumed from cooldown
                return
            }
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
            log.info("→ RECORDING: \(sessionDir.lastPathComponent) (\(currentTrigger))")

        case .cooldown:
            statusItem.button?.title = "..."
            log.info("→ COOLDOWN")

        case .idle:
            guard let sessionDir = currentSessionDir else {
                updatePauseUI()
                return
            }

            let startTime = recordingStartTime ?? Date()
            audioCapture.stopRecording()

            // End App Nap protection
            if let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
            }
            activityToken = nil

            currentSessionDir = nil
            recordingStartTime = nil
            startItem.isEnabled = true
            stopItem.isEnabled = false
            updatePauseUI()

            log.info("→ IDLE: recording stopped")

            // Post-process in background
            let micAvg = audioCapture.micRMSAvg
            let sysAvg = audioCapture.sysRMSAvg
            let micActive = detector.micActiveSeconds
            let sysActive = detector.sysActiveSeconds
            let trigger = currentTrigger
            Task {
                await postProcess(
                    sessionDir: sessionDir, startTime: startTime, endTime: Date(),
                    micRmsAvg: micAvg, sysRmsAvg: sysAvg,
                    micActiveSeconds: micActive, sysActiveSeconds: sysActive, trigger: trigger
                )
            }
        }
    }

    // MARK: - Post Processing

    private func postProcess(
        sessionDir: URL, startTime: Date, endTime: Date,
        micRmsAvg: Double, sysRmsAvg: Double,
        micActiveSeconds: Double, sysActiveSeconds: Double, trigger: String
    ) async {
        sessionManager.saveMetadata(
            sessionDir: sessionDir, startTime: startTime, endTime: endTime,
            micRmsAvg: micRmsAvg, sysRmsAvg: sysRmsAvg,
            micActiveSeconds: micActiveSeconds, sysActiveSeconds: sysActiveSeconds, trigger: trigger
        )

        // Mix audio
        log.info("Mixing audio...")
        guard let _ = mixer.mixAndCompress(sessionDir: sessionDir) else {
            log.error("Audio mixing failed for \(sessionDir.lastPathComponent)")
            sendNotification(title: "Meeting Recorder", body: "Audio mixing failed")
            return
        }

        sessionManager.cleanupRawWav(sessionDir: sessionDir)

        // Transcription (and retries) happen in the serial queue
        await transcriptionQueue.enqueue(sessionDir)
    }

    // MARK: - Backlog

    private func startBacklogProcessing() {
        sessionManager.clearLegacyPendingUploads()
        runBacklogScan()

        backlogTimer = Timer.scheduledTimer(withTimeInterval: config.backlogScanMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runBacklogScan()
            }
        }
    }

    private func runBacklogScan() {
        let excluding = currentSessionDir?.standardizedFileURL.path
        Task {
            await transcriptionQueue.scanBacklog(excludingPath: excluding)
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
