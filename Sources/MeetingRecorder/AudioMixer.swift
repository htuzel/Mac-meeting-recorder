@preconcurrency import AVFoundation
import Foundation

final class AudioMixer: Sendable {
    private let log = Logger.shared

    /// Mix mic.wav + system.wav → mixed.m4a using offline AVAudioEngine rendering
    func mixAndCompress(sessionDir: URL) -> URL? {
        let micURL = sessionDir.appendingPathComponent("mic.wav")
        let sysURL = sessionDir.appendingPathComponent("system.wav")
        let outputURL = sessionDir.appendingPathComponent("mixed.m4a")

        let fm = FileManager.default
        guard fm.fileExists(atPath: micURL.path), fm.fileExists(atPath: sysURL.path) else {
            log.error("Missing WAV files in \(sessionDir.path)")
            return nil
        }

        do {
            let micFile = try AVAudioFile(forReading: micURL)
            let sysFile = try AVAudioFile(forReading: sysURL)

            // Output format: 48kHz mono
            let outputSampleRate: Double = 48000
            guard let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: outputSampleRate,
                channels: 1
            ) else {
                log.error("Cannot create output format")
                return nil
            }

            let engine = AVAudioEngine()
            let micPlayer = AVAudioPlayerNode()
            let sysPlayer = AVAudioPlayerNode()

            engine.attach(micPlayer)
            engine.attach(sysPlayer)

            // Connect players to mixer — engine handles sample rate conversion
            engine.connect(micPlayer, to: engine.mainMixerNode, format: micFile.processingFormat)
            engine.connect(sysPlayer, to: engine.mainMixerNode, format: sysFile.processingFormat)

            // Set volumes: 0.7 each for soft headroom
            micPlayer.volume = 0.7
            sysPlayer.volume = 0.7

            // Determine total frames based on longest file
            let micFrames = AVAudioFrameCount(micFile.length)
            let sysFrames = AVAudioFrameCount(sysFile.length)

            // Read full buffers
            guard let micBuffer = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: micFrames) else {
                log.error("Cannot create mic buffer")
                return nil
            }
            try micFile.read(into: micBuffer)

            guard let sysBuffer = AVAudioPCMBuffer(pcmFormat: sysFile.processingFormat, frameCapacity: sysFrames) else {
                log.error("Cannot create sys buffer")
                return nil
            }
            try sysFile.read(into: sysBuffer)

            // Calculate total output frames
            let micOutputFrames = AVAudioFrameCount(Double(micFrames) * outputSampleRate / micFile.processingFormat.sampleRate)
            let sysOutputFrames = AVAudioFrameCount(Double(sysFrames) * outputSampleRate / sysFile.processingFormat.sampleRate)
            let totalOutputFrames = max(micOutputFrames, sysOutputFrames)

            // Enable offline rendering
            let maxFramesPerRender: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(
                .offline,
                format: outputFormat,
                maximumFrameCount: maxFramesPerRender
            )

            try engine.start()
            micPlayer.scheduleBuffer(micBuffer, completionHandler: nil)
            sysPlayer.scheduleBuffer(sysBuffer, completionHandler: nil)
            micPlayer.play()
            sysPlayer.play()

            // AAC output settings
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]

            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: aacSettings
            )

            guard let renderBuffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: maxFramesPerRender
            ) else {
                log.error("Cannot create render buffer")
                return nil
            }

            var framesRendered: AVAudioFrameCount = 0
            while framesRendered < totalOutputFrames {
                let status = try engine.renderOffline(maxFramesPerRender, to: renderBuffer)
                switch status {
                case .success:
                    try outputFile.write(from: renderBuffer)
                    framesRendered += renderBuffer.frameLength
                case .insufficientDataFromInputNode:
                    // One source finished, continue for the other
                    try outputFile.write(from: renderBuffer)
                    framesRendered += renderBuffer.frameLength
                case .cannotDoInCurrentContext:
                    log.warn("Render: cannot do in current context, retrying")
                    continue
                case .error:
                    log.error("Render error at frame \(framesRendered)")
                    engine.stop()
                    return nil
                @unknown default:
                    break
                }
            }

            engine.stop()
            log.info("Mixed audio saved: \(outputURL.path) (\(totalOutputFrames) frames)")
            return outputURL

        } catch {
            log.error("Audio mixing failed: \(error.localizedDescription)")
            return nil
        }
    }
}
