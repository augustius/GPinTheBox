import AVFoundation
import Speech
import Synchronization

// AVAudioEngine isn't Sendable; it is only touched inside the Mutex-guarded state.
public final class SpeechAnalyzerListener: AnswerListener, @unchecked Sendable {
    private struct Session { var engine: AVAudioEngine?; var analyzer: SpeechAnalyzer?; var input: AsyncStream<AnalyzerInput>.Continuation?; var stopped = false }
    private let locale: Locale
    private let session = Mutex(Session())

    public init(locale: Locale) { self.locale = locale }

    public func listen() -> AsyncThrowingStream<ListenEvent, Error> {
        session.withLock { $0 = Session() }
        let (stream, continuation) = AsyncThrowingStream<ListenEvent, Error>.makeStream()
        Task { [self] in
            do { try await run(continuation) } catch { continuation.finish(throwing: error); await stop() }
        }
        return stream
    }

    public func stop() async {
        let (engine, analyzer, input) = session.withLock { s in
            defer { s = Session(stopped: true) }
            return (s.engine, s.analyzer, s.input)
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    private func run(_ events: AsyncThrowingStream<ListenEvent, Error>.Continuation) async throws {
        SpeechSetup.activateAudioSession()
        let transcriber = SpeechSetup.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw SpeechUnavailableError() }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AVAudioEngine()
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: source, to: format) else { throw SpeechUnavailableError() }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in
            if let converted = Self.convert(buffer, with: converter) { input.yield(AnalyzerInput(buffer: converted)) }
        }
        let results = Task {
            var finalized = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal { finalized = Self.joinTranscript(finalized, text) }
                events.yield(.partial(result.isFinal ? finalized : Self.joinTranscript(finalized, text)))
            }
            return finalized
        }
        try await analyzer.start(inputSequence: inputs)
        let stopped = session.withLock { s in
            if !s.stopped { s.engine = engine; s.analyzer = analyzer; s.input = input }
            return s.stopped
        }
        if stopped {
            engine.inputNode.removeTap(onBus: 0); input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } else {
            engine.prepare()
            try engine.start()
        }
        events.yield(.final(try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)))
        events.finish()
    }

    static func joinTranscript(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first, !last.isWhitespace, !first.isWhitespace else { return head + tail }
        return head + " " + tail
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true; inputStatus.pointee = .haveData; return buffer
        }
        return status == .error ? nil : output
    }
}
