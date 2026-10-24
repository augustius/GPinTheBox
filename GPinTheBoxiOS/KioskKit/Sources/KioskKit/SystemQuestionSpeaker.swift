import AVFoundation
import Synchronization

// AVSpeechSynthesizer isn't Sendable; it is only messaged via its thread-safe API and mutable state lives in a Mutex.
public final class SystemQuestionSpeaker: NSObject, QuestionSpeaker, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let pending = Mutex<[ObjectIdentifier: CheckedContinuation<Void, Never>]>([:])

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        SpeechSetup.activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-AU")
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.withLock { $0[ObjectIdentifier(utterance)] = continuation }
                synthesizer.speak(utterance)
            }
        } onCancel: { synthesizer.stopSpeaking(at: .immediate) }
    }

    public func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
        pending.withLock { p in defer { p = [:] }; return Array(p.values) }.forEach { $0.resume() }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish(utterance) }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(utterance) }

    private func finish(_ utterance: AVSpeechUtterance) {
        pending.withLock { $0.removeValue(forKey: ObjectIdentifier(utterance)) }?.resume()
    }
}
