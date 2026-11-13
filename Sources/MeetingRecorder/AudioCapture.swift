@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

final class AudioCapture: NSObject, @unchecked Sendable {
    private let config: Config
    private let log = Logger.shared

    private var stream: SCStream?
    private var isMonitoring = false
    private var isRecording = false

    // RMS values protected by os_unfair_lock
    private var _micRMS: Double = 0.0
    private var _sysRMS: Double = 0.0
    // Peak buffer RMS since the last consumePeaks() call (one VAD tick).
    // Sampling only the latest ~10ms buffer every 0.5s missed most speech.
    private var _micPeak: Double = 0.0
    private var _sysPeak: Double = 0.0
    private var rmsLock = os_unfair_lock()

    // Prevents overlapping restarts (wake + device change + stream error)
    private var restartInProgress = false
    private var restartLock = os_unfair_lock()
    private var deviceChangeGeneration = 0

    // RMS accumulators for metadata
    private var micRMSSum: Double = 0.0
    private var sysRMSSum: Double = 0.0
    private var micRMSCount: Int = 0
    private var sysRMSCount: Int = 0

    // WAV writers on serial queue
    private let writerQueue = DispatchQueue(label: "com.flalingo.meeting-recorder.audio.writer")
    private var micWriter: AVAudioFile?
    private var sysWriter: AVAudioFile?

    // Separate queues for stream output handlers
    private let micQueue = DispatchQueue(label: "com.flalingo.meeting-recorder.audio.mic")
    private let sysQueue = DispatchQueue(label: "com.flalingo.meeting-recorder.audio.sys")

    var micRMS: Double {
        os_unfair_lock_lock(&rmsLock)
        defer { os_unfair_lock_unlock(&rmsLock) }
        return _micRMS
    }

    var sysRMS: Double {
        os_unfair_lock_lock(&rmsLock)
        defer { os_unfair_lock_unlock(&rmsLock) }
        return _sysRMS
    }

    /// Returns the peak RMS of each side since the previous call and resets it.
    func consumePeaks() -> (mic: Double, sys: Double) {
        os_unfair_lock_lock(&rmsLock)
        defer { os_unfair_lock_unlock(&rmsLock) }
        let peaks = (mic: _micPeak, sys: _sysPeak)
        _micPeak = 0
        _sysPeak = 0
        return peaks
    }

    var micRMSAvg: Double {
        os_unfair_lock_lock(&rmsLock)
        defer { os_unfair_lock_unlock(&rmsLock) }
        return micRMSCount > 0 ? micRMSSum / Double(micRMSCount) : 0
    }

    var sysRMSAvg: Double {
        os_unfair_lock_lock(&rmsLock)
        defer { os_unfair_lock_unlock(&rmsLock) }
        return sysRMSCount > 0 ? sysRMSSum / Double(sysRMSCount) : 0
    }

    init(config: Config) {
        self.config = config
        super.init()

        // Listen for wake notifications to restart stream
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        installDefaultInputListener()
    }

    // MARK: - Input device changes

    /// When the default microphone changes (AirPods/headset connect or
    /// disconnect), the running SCStream can keep listening to the old device
    /// and go deaf. Restart the stream shortly after the change settles.
    private func installDefaultInputListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDefaultInputChange()
        }
        if status != noErr {
            log.warn("Could not watch default input device changes (status \(status))")
        }
    }

    private func handleDefaultInputChange() {
        os_unfair_lock_lock(&restartLock)
        deviceChangeGeneration += 1
        let generation = deviceChangeGeneration
        os_unfair_lock_unlock(&restartLock)

        log.info("Default input device changed — restarting stream in 2s")
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Coalesce bursts of change notifications into one restart
            guard self.currentDeviceGeneration() == generation else { return }
            await self.restart()
        }
    }

    private func currentDeviceGeneration() -> Int {
        os_unfair_lock_lock(&restartLock)
        defer { os_unfair_lock_unlock(&restartLock) }
        return deviceChangeGeneration
    }

    // MARK: - Monitoring (RMS only, no recording)

    func startMonitoring() async throws {
        guard !isMonitoring else { return }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            log.error("No display found for SCStream")
            return
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.captureMicrophone = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = Int(config.sampleRate)
        streamConfig.channelCount = 1
        // Minimize video overhead — we only need audio
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQueue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)

        try await newStream.startCapture()
        self.stream = newStream
        self.isMonitoring = true
        log.info("Audio monitoring started (SCStream)")
    }

    func stopMonitoring() async {
        guard isMonitoring, let stream = stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            log.error("Error stopping stream: \(error.localizedDescription)")
        }
        self.stream = nil
        self.isMonitoring = false
        log.info("Audio monitoring stopped")
    }

    // MARK: - Recording (WAV writing)

    func startRecording(sessionDir: URL) {
        writerQueue.sync {
            let micFormat = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 1)!
            let sysFormat = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 1)!

            do {
                let micURL = sessionDir.appendingPathComponent("mic.wav")
                let sysURL = sessionDir.appendingPathComponent("system.wav")
                micWriter = try AVAudioFile(forWriting: micURL, settings: micFormat.settings)
                sysWriter = try AVAudioFile(forWriting: sysURL, settings: sysFormat.settings)

                // Reset RMS accumulators and flip the recording flag together
                os_unfair_lock_lock(&rmsLock)
                micRMSSum = 0; sysRMSSum = 0
                micRMSCount = 0; sysRMSCount = 0
                isRecording = true
                os_unfair_lock_unlock(&rmsLock)

                log.info("Recording started → \(sessionDir.path)")
            } catch {
                log.error("Failed to create WAV writers: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        writerQueue.sync {
            os_unfair_lock_lock(&rmsLock)
            isRecording = false
            os_unfair_lock_unlock(&rmsLock)
            micWriter = nil
            sysWriter = nil
            log.info("Recording stopped")
        }
    }

    // MARK: - Restart

    func restart() async {
        guard beginRestart() else {
            log.debug("Restart already in progress — skipping")
            return
        }
        defer { endRestart() }

        log.warn("Restarting audio capture stream")
        await stopMonitoring()
        try? await Task.sleep(for: .seconds(1))
        do {
            try await startMonitoring()
        } catch {
            log.error("Failed to restart monitoring: \(error.localizedDescription)")
        }
    }

    private func beginRestart() -> Bool {
        os_unfair_lock_lock(&restartLock)
        defer { os_unfair_lock_unlock(&restartLock) }
        if restartInProgress { return false }
        restartInProgress = true
        return true
    }

    private func endRestart() {
        os_unfair_lock_lock(&restartLock)
        restartInProgress = false
        os_unfair_lock_unlock(&restartLock)
    }

    @objc private func handleWake() {
        log.info("System woke from sleep — scheduling stream restart")
        Task {
            try? await Task.sleep(for: .seconds(2))
            await restart()
        }
    }

    // MARK: - RMS Calculation

    private func calculateRMS(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return 0 }

        let length = dataBuffer.dataLength
        var data = Data(count: length)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }

        // Determine format from the sample buffer
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 0
        }

        let bytesPerSample = Int(asbd.pointee.mBitsPerChannel / 8)
        guard bytesPerSample > 0 else { return 0 }
        let sampleCount = length / bytesPerSample

        guard sampleCount > 0 else { return 0 }

        var sumSquares: Double = 0

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 samples
            data.withUnsafeBytes { ptr in
                let floats = ptr.bindMemory(to: Float32.self)
                for i in 0..<min(sampleCount, floats.count) {
                    let sample = Double(floats[i])
                    sumSquares += sample * sample
                }
            }
        } else if asbd.pointee.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            // Int16 samples
            data.withUnsafeBytes { ptr in
                let samples = ptr.bindMemory(to: Int16.self)
                for i in 0..<min(sampleCount, samples.count) {
                    let sample = Double(samples[i]) / 32768.0
                    sumSquares += sample * sample
                }
            }
        }

        return sqrt(sumSquares / Double(sampleCount))
    }
}

// MARK: - SCStreamOutput

extension AudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .microphone:
            let rms = calculateRMS(from: sampleBuffer)
            os_unfair_lock_lock(&rmsLock)
            _micRMS = rms
            _micPeak = max(_micPeak, rms)
            micRMSSum += rms
            micRMSCount += 1
            let recording = isRecording
            os_unfair_lock_unlock(&rmsLock)

            if recording {
                writeMicBuffer(sampleBuffer)
            }

        case .audio:
            let rms = calculateRMS(from: sampleBuffer)
            os_unfair_lock_lock(&rmsLock)
            _sysRMS = rms
            _sysPeak = max(_sysPeak, rms)
            sysRMSSum += rms
            sysRMSCount += 1
            let recording = isRecording
            os_unfair_lock_unlock(&rmsLock)

            if recording {
                writeSysBuffer(sampleBuffer)
            }

        case .screen:
            break // Ignore video frames

        @unknown default:
            break
        }
    }

    private func writeMicBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        writerQueue.async { [weak self] in
            guard let self = self, let writer = self.micWriter else { return }
            do {
                try writer.write(from: pcmBuffer)
            } catch {
                self.log.error("Failed to write mic buffer: \(error.localizedDescription)")
            }
        }
    }

    private func writeSysBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        writerQueue.async { [weak self] in
            guard let self = self, let writer = self.sysWriter else { return }
            do {
                try writer.write(from: pcmBuffer)
            } catch {
                self.log.error("Failed to write sys buffer: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension AudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("SCStream stopped with error: \(error.localizedDescription)")
        isMonitoring = false

        Task {
            try? await Task.sleep(for: .seconds(3))
            await restart()
        }
    }
}

// MARK: - CMSampleBuffer Extension

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let dataBuffer = dataBuffer else { return nil }

        let dataLength = dataBuffer.dataLength
        let destPtr: UnsafeMutableRawPointer
        if let floatData = pcmBuffer.floatChannelData {
            destPtr = UnsafeMutableRawPointer(floatData[0])
        } else if let int16Data = pcmBuffer.int16ChannelData {
            destPtr = UnsafeMutableRawPointer(int16Data[0])
        } else {
            return nil
        }

        let copyLength = min(dataLength, Int(pcmBuffer.frameCapacity) * Int(asbd.pointee.mBytesPerFrame))
        CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: copyLength, destination: destPtr)

        return pcmBuffer
    }
}
