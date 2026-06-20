import AVFoundation

/// Wraps AVAudioEngine for mic capture (24 kHz mono PCM16) and TTS playback.
/// All methods are safe to call from the main thread; the tap callback fires
/// on AVAudioEngine's internal audio thread and must not touch UI state directly.
final class AudioEngine {

    // 24 kHz mono PCM16 — the format OpenAI Realtime API expects/produces
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var onCapture: ((Data, Float) -> Void)?

    var isRunning: Bool { engine.isRunning }

    // MARK: - Lifecycle

    /// Start capture and playback. `onCapture` is called on the AVAudioEngine
    /// audio thread with each ~100 ms block of 24 kHz mono PCM16 bytes and the
    /// normalised RMS level (0…1) for waveform display.
    func start(onCapture: @escaping (Data, Float) -> Void) throws {
        self.onCapture = onCapture

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.targetFormat)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        if inputFormat.sampleRate != Self.targetFormat.sampleRate
            || inputFormat.channelCount != Self.targetFormat.channelCount
            || inputFormat.commonFormat != Self.targetFormat.commonFormat {
            converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        }

        // ~100 ms tap blocks in the hardware's native format; we convert in the callback
        let tapBlock = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        inputNode.installTap(onBus: 0, bufferSize: tapBlock, format: inputFormat) { [weak self] buf, _ in
            self?.processCapture(buf, inputFormat: inputFormat)
        }

        try engine.start()
        player.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        converter = nil
        onCapture = nil
    }

    // MARK: - Playback

    /// Enqueue a chunk of 24 kHz mono PCM16 audio for playback.
    func enqueueAudio(_ data: Data) {
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: frameCount),
              let dst = buf.int16ChannelData?[0] else { return }
        buf.frameLength = frameCount
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            dst.update(from: src, count: Int(frameCount))
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Interrupt current TTS playback (barge-in).
    func stopPlayback() {
        player.stop()
        player.play()
    }

    // MARK: - Private

    private func processCapture(_ buf: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        let outBuf: AVAudioPCMBuffer

        if let conv = converter {
            let ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 1)
            guard let converted = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: cap) else { return }
            var done = false
            let status = conv.convert(to: converted, error: nil) { _, ptr in
                guard !done else { ptr.pointee = .noDataNow; return nil }
                done = true
                ptr.pointee = .haveData
                return buf
            }
            guard status != .error else { return }
            outBuf = converted
        } else {
            outBuf = buf
        }

        guard let samples = outBuf.int16ChannelData else { return }
        let count = Int(outBuf.frameLength)
        guard count > 0 else { return }
        let data = Data(bytes: samples[0], count: count * 2)
        let level = rmsLevel(samples[0], count: count)
        onCapture?(data, level)
    }

    /// Normalised RMS matching Python's `_frame_level` (divides RMS by 8 000 on int16 scale).
    private func rmsLevel(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        var sum: Float = 0
        for i in 0..<count {
            let s = Float(samples[i])
            sum += s * s
        }
        let rms = sqrt(sum / Float(count))
        return min(1.0, rms / 8_000.0)
    }
}
