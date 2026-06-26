@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

final class AudioCaptureManager {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var isCapturing = false
    private var chunkCount = 0

    // Align outbound packets to the doubao web client: 2048 samples @16kHz ≈ 128ms.
    private static let packetSampleCount = 2048
    private static let packetByteCount = packetSampleCount * 2
    private var pcmAccumulator = Data()

    var onAudioData: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    func startCapture() throws {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        applySelectedInputDevice(to: inputNode)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        AppLog.info("Audio input format sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            AppLog.error("Audio input unavailable sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
            throw NSError(domain: "Douvo.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            AppLog.error("Audio converter creation failed")
            throw NSError(domain: "Douvo.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }
        self.converter = converter
        chunkCount = 0
        pcmAccumulator.removeAll(keepingCapacity: true)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isCapturing = true
        AppLog.info("Audio engine started")
    }

    func stopCapture() {
        guard isCapturing else { return }
        AppLog.info("Audio capture stopping chunks=\(chunkCount)")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        isCapturing = false
        chunkCount = 0

        // Flush any remaining samples (< one packet) so the tail isn't lost.
        if !pcmAccumulator.isEmpty {
            let remainder = pcmAccumulator
            pcmAccumulator.removeAll(keepingCapacity: true)
            onAudioData?(remainder)
        }
    }

    private func applySelectedInputDevice(to inputNode: AVAudioInputNode) {
        guard let uid = AudioDeviceStore.selectedUID() else {
            AppLog.info("Audio input using system default device")
            return
        }
        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else {
            AppLog.info("Selected input device not available; falling back to system default uid=\(uid)")
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            AppLog.error("Audio input node audioUnit unavailable; cannot set device")
            return
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            AppLog.info("Audio input device set uid=\(uid) deviceID=\(deviceID)")
        } else {
            AppLog.error("Audio set input device failed status=\(status) uid=\(uid)")
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let onAudioData else { return }

        let ratio = 16_000.0 / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }

        var hasInput = true
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if hasInput {
                hasInput = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil, output.frameLength > 0 else {
            if let error {
                AppLog.error("Audio conversion failed error=\(error.localizedDescription)")
            }
            return
        }

        let floats = output.floatChannelData![0]
        let count = Int(output.frameLength)

        if let onLevel, count > 0 {
            var sumSquares: Float = 0
            for index in 0..<count {
                let sample = floats[index]
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(count))
            // Map RMS to a 0...1 level with a perceptual curve so quiet speech stays visible.
            let level = min(1, sqrtf(rms) * 2.6)
            onLevel(level)
        }

        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                let sample = floats[index]
                let scaled = sample < 0 ? sample * 32768.0 : sample * 32767.0
                int16[index] = Int16(max(-32768, min(32767, scaled)))
            }
        }
        pcmAccumulator.append(pcm)
        while pcmAccumulator.count >= Self.packetByteCount {
            let packet = pcmAccumulator.prefix(Self.packetByteCount)
            pcmAccumulator.removeFirst(Self.packetByteCount)
            chunkCount += 1
            if chunkCount == 1 || chunkCount % 50 == 0 {
                AppLog.info("Audio chunk ready count=\(chunkCount) bytes=\(packet.count)")
            }
            onAudioData(Data(packet))
        }
    }
}
