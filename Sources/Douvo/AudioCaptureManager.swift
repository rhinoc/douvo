@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

private final class SingleBufferAudioInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}

struct AudioInputConditioner {
    private static let highPassCoefficient: Float = 0.995

    private var previousInput: Float = 0
    private var previousOutput: Float = 0

    mutating func reset() {
        previousInput = 0
        previousOutput = 0
    }

    mutating func process(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { buffer in
            process(buffer)
        }
    }

    mutating func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(samples.count)

        for rawSample in samples {
            let sample = rawSample.isFinite ? rawSample : 0
            let filtered = sample - previousInput + Self.highPassCoefficient * previousOutput
            previousInput = sample
            previousOutput = filtered
            output.append(max(-1, min(1, filtered)))
        }

        return output
    }
}

struct AudioLevelVisualizer {
    private static let minimumDecibels: Float = -60
    private static let maximumDecibels: Float = -18
    private static let minimumRMS: Float = 0.000_001

    static func level(fromRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }

        let decibels = 20 * log10f(max(rms, minimumRMS))
        let normalized = (decibels - minimumDecibels) / (maximumDecibels - minimumDecibels)
        let clamped = max(0, min(1, normalized))
        return pow(clamped, 0.68)
    }

    static func normalizedVoiceLevel(from level: Float, noiseFloor: Float) -> Float {
        let clampedLevel = max(0, min(1, level))
        let clampedNoiseFloor = max(0, min(0.95, noiseFloor))
        guard clampedLevel > clampedNoiseFloor else { return 0 }

        let normalized = (clampedLevel - clampedNoiseFloor) / (1 - clampedNoiseFloor)
        return max(0, min(1, normalized))
    }
}

final class AudioCaptureManager {
    enum CaptureMode {
        case webPCM
        case androidOpus
        case webPCMAndAndroidOpus
    }

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var captureMode: CaptureMode = .webPCM
    private var opusEncoder: OpusPacketEncoder?
    private var isCapturing = false
    private var chunkCount = 0
    private var levelSampleCount = 0
    private var levelMin: Float = .greatestFiniteMagnitude
    private var levelMax: Float = 0
    private var levelLast: Float = 0
    private var levelSummarySamples: [String] = []
    private var webPCMChunkCount = 0
    private var webPCMByteCount = 0
    private var webPCMSummarySamples: [String] = []
    private var androidOpusPacketCount = 0
    private var androidOpusByteCount = 0
    private var androidOpusSummarySamples: [String] = []

    // Align outbound packets to the doubao web client: 2048 samples @16kHz ≈ 128ms.
    private static let packetSampleCount = 2048
    private static let packetByteCount = packetSampleCount * 2
    private static let levelBufferSampleCount: AVAudioFrameCount = 512
    private static let tailSilencePacketCount = 2
    private static let opusFrameSampleCount = 320
    private static let androidOpusTailSilenceFrameCount = 25
    private static let maxSummarySamples = 12
    private var pcmAccumulator = Data()
    private var opusSampleAccumulator: [Float] = []
    private var debugAudioRecorder: RecentAudioRecorder?
    private var inputConditioner = AudioInputConditioner()

    var onAudioData: ((Data) -> Void)?
    var onWebPCMData: ((Data) -> Void)?
    var onAndroidOpusData: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    func startCapture(mode: CaptureMode = .webPCM) throws {
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
        captureMode = mode
        opusEncoder = mode.usesAndroidOpus ? try OpusPacketEncoder() : nil
        resetCaptureMetrics()
        pcmAccumulator.removeAll(keepingCapacity: true)
        opusSampleAccumulator.removeAll(keepingCapacity: true)
        inputConditioner.reset()
        debugAudioRecorder = RecentAudioRecorder.start()

        inputNode.installTap(onBus: 0, bufferSize: Self.levelBufferSampleCount, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            opusEncoder = nil
            _ = debugAudioRecorder?.finish()
            debugAudioRecorder = nil
            throw error
        }
        audioEngine = engine
        isCapturing = true
        AppLog.info("Audio engine started")
    }

    func stopCapture() -> URL? {
        guard isCapturing else { return nil }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        drainConverterTail()
        converter = nil
        isCapturing = false

        flushTailAudio()
        opusEncoder = nil
        let recordingURL = debugAudioRecorder?.finish()
        debugAudioRecorder = nil
        logCaptureSummary(recordingURL: recordingURL)
        resetCaptureMetrics()
        return recordingURL
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
        guard let converter, hasAudioConsumer else { return }

        let ratio = 16_000.0 / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }

        let inputProvider = SingleBufferAudioInputProvider(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            inputProvider.nextBuffer(outStatus)
        }

        guard status != .error, error == nil, output.frameLength > 0 else {
            if let error {
                AppLog.error("Audio conversion failed error=\(error.localizedDescription)")
            }
            return
        }

        processConvertedBuffer(output)
    }

    private func drainConverterTail() {
        guard let converter, hasAudioConsumer else { return }

        var drainedFrames = 0
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(Self.packetSampleCount)
            ) else {
                return
            }

            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }

            if let error {
                AppLog.error("Audio converter drain failed error=\(error.localizedDescription)")
                return
            }
            guard status != .error else { return }

            if output.frameLength > 0 {
                drainedFrames += Int(output.frameLength)
                processConvertedBuffer(output)
            }

            if status == .endOfStream || output.frameLength == 0 {
                break
            }
        }

        if drainedFrames > 0 {
            AppLog.info("Audio converter drained frames=\(drainedFrames)")
        }
    }

    private func processConvertedBuffer(_ output: AVAudioPCMBuffer) {
        let floats = output.floatChannelData![0]
        let count = Int(output.frameLength)
        let conditionedSamples = inputConditioner.process(UnsafeBufferPointer(start: floats, count: count))
        let pcm = pcm16Data(from: conditionedSamples)

        if let onLevel, count > 0 {
            var sumSquares: Float = 0
            for sample in conditionedSamples {
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(count))
            let level = AudioLevelVisualizer.level(fromRMS: rms)
            levelSampleCount += 1
            levelMin = min(levelMin, level)
            levelMax = max(levelMax, level)
            levelLast = level
            if Self.shouldSampleProgress(levelSampleCount) {
                Self.appendSummarySample("\(levelSampleCount):\(Self.format(level))", to: &levelSummarySamples)
            }
            onLevel(level)
        }

        switch captureMode {
        case .webPCM:
            pcmAccumulator.append(pcm)
            while pcmAccumulator.count >= Self.packetByteCount {
                let packet = pcmAccumulator.prefix(Self.packetByteCount)
                pcmAccumulator.removeFirst(Self.packetByteCount)
                chunkCount += 1
                recordWebPCMPacket(bytes: packet.count)
                emitWebPCMPacket(Data(packet))
            }
        case .androidOpus:
            debugAudioRecorder?.append(pcm)
            opusSampleAccumulator.append(contentsOf: conditionedSamples)
            emitAvailableOpusPackets()
        case .webPCMAndAndroidOpus:
            pcmAccumulator.append(pcm)
            while pcmAccumulator.count >= Self.packetByteCount {
                let packet = pcmAccumulator.prefix(Self.packetByteCount)
                pcmAccumulator.removeFirst(Self.packetByteCount)
                chunkCount += 1
                recordWebPCMPacket(bytes: packet.count)
                emitWebPCMPacket(Data(packet))
            }
            opusSampleAccumulator.append(contentsOf: conditionedSamples)
            emitAvailableOpusPackets()
        }
    }

    private func pcm16Data(from samples: [Float]) -> Data {
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let scaled = sample < 0 ? sample * 32768.0 : sample * 32767.0
                int16[index] = Int16(max(-32768, min(32767, scaled)))
            }
        }
        return pcm
    }

    private func flushTailAudio() {
        guard hasAudioConsumer else {
            pcmAccumulator.removeAll(keepingCapacity: true)
            opusSampleAccumulator.removeAll(keepingCapacity: true)
            return
        }

        switch captureMode {
        case .webPCM:
            flushWebTailAudio()
        case .androidOpus:
            flushAndroidOpusTailAudio()
        case .webPCMAndAndroidOpus:
            flushWebTailAudio()
            flushAndroidOpusTailAudio()
        }
    }

    private func flushWebTailAudio() {
        var flushedRemainderBytes = 0
        if !pcmAccumulator.isEmpty {
            flushedRemainderBytes = pcmAccumulator.count
            if pcmAccumulator.count < Self.packetByteCount {
                pcmAccumulator.append(Data(count: Self.packetByteCount - pcmAccumulator.count))
            }
            while !pcmAccumulator.isEmpty {
                let packet = pcmAccumulator.prefix(Self.packetByteCount)
                pcmAccumulator.removeFirst(min(Self.packetByteCount, pcmAccumulator.count))
                emitWebPCMPacket(Data(packet))
            }
        }

        let silencePacket = Data(count: Self.packetByteCount)
        for _ in 0..<Self.tailSilencePacketCount {
            emitWebPCMPacket(silencePacket)
        }
        AppLog.info("Audio tail flushed remainderBytes=\(flushedRemainderBytes) silencePackets=\(Self.tailSilencePacketCount)")
    }

    private func flushAndroidOpusTailAudio() {
        let remainderSampleCount = opusSampleAccumulator.count
        if opusSampleAccumulator.count < Self.opusFrameSampleCount {
            opusSampleAccumulator.append(contentsOf: repeatElement(0, count: Self.opusFrameSampleCount - opusSampleAccumulator.count))
        }
        opusSampleAccumulator.append(
            contentsOf: repeatElement(0, count: Self.opusFrameSampleCount * Self.androidOpusTailSilenceFrameCount)
        )
        emitAvailableOpusPackets()
        AppLog.info("Android Opus tail flushed remainderSamples=\(remainderSampleCount) silenceFrames=\(Self.androidOpusTailSilenceFrameCount)")
    }

    private func emitAvailableOpusPackets() {
        guard let opusEncoder else { return }
        while opusSampleAccumulator.count >= Self.opusFrameSampleCount {
            let samples = Array(opusSampleAccumulator.prefix(Self.opusFrameSampleCount))
            opusSampleAccumulator.removeFirst(Self.opusFrameSampleCount)
            do {
                let packet = try opusEncoder.encode(samples)
                chunkCount += 1
                recordAndroidOpusPacket(bytes: packet.count)
                emitAndroidOpusPacket(packet)
            } catch {
                AppLog.error("Android Opus encode failed error=\(error.localizedDescription)")
            }
        }
    }

    private func recordWebPCMPacket(bytes: Int) {
        webPCMChunkCount += 1
        webPCMByteCount += bytes
        if Self.shouldSampleProgress(webPCMChunkCount) {
            Self.appendSummarySample("\(webPCMChunkCount):\(bytes)", to: &webPCMSummarySamples)
        }
    }

    private func recordAndroidOpusPacket(bytes: Int) {
        androidOpusPacketCount += 1
        androidOpusByteCount += bytes
        if Self.shouldSampleProgress(androidOpusPacketCount) {
            Self.appendSummarySample("\(androidOpusPacketCount):\(bytes)", to: &androidOpusSummarySamples)
        }
    }

    private func logCaptureSummary(recordingURL: URL?) {
        let levelRange = levelSampleCount > 0
            ? "\(Self.format(levelMin))...\(Self.format(levelMax)) last=\(Self.format(levelLast))"
            : "none"
        AppLog.info(
            "Audio capture summary mode=\(captureMode.logName) totalPackets=\(chunkCount) levelSamples=\(levelSampleCount) levelRange=\(levelRange) levelSamplesPreview=\(Self.formatSamples(levelSummarySamples)) webPackets=\(webPCMChunkCount) webBytes=\(webPCMByteCount) webPacketSamples=\(Self.formatSamples(webPCMSummarySamples)) androidPackets=\(androidOpusPacketCount) androidBytes=\(androidOpusByteCount) androidPacketSamples=\(Self.formatSamples(androidOpusSummarySamples)) recordingSaved=\(recordingURL != nil)"
        )
    }

    private func resetCaptureMetrics() {
        chunkCount = 0
        levelSampleCount = 0
        levelMin = .greatestFiniteMagnitude
        levelMax = 0
        levelLast = 0
        levelSummarySamples.removeAll(keepingCapacity: true)
        webPCMChunkCount = 0
        webPCMByteCount = 0
        webPCMSummarySamples.removeAll(keepingCapacity: true)
        androidOpusPacketCount = 0
        androidOpusByteCount = 0
        androidOpusSummarySamples.removeAll(keepingCapacity: true)
    }

    private static func shouldSampleProgress(_ count: Int) -> Bool {
        count == 1 || count % 50 == 0
    }

    private static func appendSummarySample(_ sample: String, to samples: inout [String]) {
        if samples.count < Self.maxSummarySamples {
            samples.append(sample)
        } else {
            samples[Self.maxSummarySamples - 1] = "...\(sample)"
        }
    }

    private static func formatSamples(_ samples: [String]) -> String {
        "[\(samples.joined(separator: ","))]"
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.3f", Double(value))
    }

    private func emitWebPCMPacket(_ data: Data) {
        debugAudioRecorder?.append(data)
        onWebPCMData?(data)
        onAudioData?(data)
    }

    private func emitAndroidOpusPacket(_ data: Data) {
        onAndroidOpusData?(data)
        onAudioData?(data)
    }

    private var hasAudioConsumer: Bool {
        onAudioData != nil || onWebPCMData != nil || onAndroidOpusData != nil
    }
}

private extension AudioCaptureManager.CaptureMode {
    var logName: String {
        switch self {
        case .webPCM:
            "web_pcm"
        case .androidOpus:
            "android_opus"
        case .webPCMAndAndroidOpus:
            "web_pcm_and_android_opus"
        }
    }

    var usesAndroidOpus: Bool {
        switch self {
        case .webPCM:
            false
        case .androidOpus, .webPCMAndAndroidOpus:
            true
        }
    }
}

private final class OpusPacketEncoder {
    private final class SingleBufferInputProvider: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var didProvideInput = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func nextBuffer(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
    }

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init() throws {
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 320,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &outputDescription),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "Douvo.Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create Opus encoder"])
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func encode(_ samples: [Float]) throws -> Data {
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "Douvo.Audio", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create Opus input buffer"])
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            input.floatChannelData![0][index] = samples[index]
        }

        let output = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: max(1, converter.maximumOutputPacketSize)
        )
        let provider = SingleBufferInputProvider(buffer: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            provider.nextBuffer(outStatus)
        }

        if let error {
            throw error
        }
        guard status != .error, output.byteLength > 0 else {
            throw NSError(domain: "Douvo.Audio", code: 5, userInfo: [NSLocalizedDescriptionKey: "Opus encoder produced no packet"])
        }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}
