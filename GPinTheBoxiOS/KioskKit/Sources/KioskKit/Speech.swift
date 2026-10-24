import AVFoundation
import Speech

public enum ListenEvent: Equatable, Sendable { case partial(String), final(String) }

public protocol AnswerListener: Sendable {
    func listen() -> AsyncThrowingStream<ListenEvent, Error>
    func stop() async
}

public protocol QuestionSpeaker: Sendable {
    func speak(_ text: String) async
    func stop() async
}

public enum SpeechReadiness: Equatable, Sendable { case ready(localeID: String, isFallback: Bool), needsDownload, unavailable(String) }

struct SpeechUnavailableError: Error {}

public enum SpeechSetup {
    public static func readiness() async -> SpeechReadiness {
        guard await AVAudioApplication.requestRecordPermission() else { return .unavailable("Microphone access is turned off.") }
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { return .unavailable("Speech recognition access is turned off.") }
        guard let (locale, isFallback) = await locale() else { return .unavailable("On-device English transcription is not available.") }
        guard await AssetInventory.status(forModules: [transcriber(locale)]) == .installed else { return .needsDownload }
        return .ready(localeID: locale.identifier, isFallback: isFallback)
    }

    public static func downloadAssets() async throws {
        guard let (locale, _) = await locale() else { throw SpeechUnavailableError() }
        try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)])?.downloadAndInstall()
    }

    public static func locale() async -> (Locale, isFallback: Bool)? {
        if let au = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_AU")) { return (au, false) }
        if let us = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) { return (us, true) }
        return nil
    }

    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    static func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers])
        try? session.setActive(true)
        #endif
    }
}
