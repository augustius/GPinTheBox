import SwiftUI
import KioskKit

@main struct KioskApp: App {
    @State private var kiosk = Kiosk()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(kiosk: kiosk)
                .task { await kiosk.launch() }
                .onChange(of: kiosk.browser.services) { kiosk.applyClinic() }
                .onChange(of: scenePhase) { if scenePhase == .active { kiosk.restartBrowsing(onlyIfEmpty: true) } }
        }
    }
}

@MainActor @Observable final class Kiosk {
    static let clinicKey = "kiosk.clinicServiceName"
    let browser = ClinicBrowser()
    private(set) var readiness: SpeechReadiness?
    private(set) var controller: KioskController?
    private(set) var hasListener = false
    @ObservationIgnored private var launched = false

    func launch() async {
        guard !launched else { return }
        launched = true
        UIApplication.shared.isIdleTimerDisabled = true
        browser.start()
        await refreshSpeech()
    }

    /// Builds the controller, rebuilding it only when speech has newly become ready (e.g. after staff download assets).
    func refreshSpeech() async {
        let readiness = await SpeechSetup.readiness()
        self.readiness = readiness
        var listener: SpeechAnalyzerListener?
        if case .ready(let id, _) = readiness { listener = SpeechAnalyzerListener(locale: Locale(identifier: id)) }
        guard controller == nil || (listener != nil && !hasListener) else { return }
        controller?.reset()
        controller = KioskController(speaker: SystemQuestionSpeaker(), listener: listener,
                                     tidier: AnswerTidier(model: FoundationModelsAnswerModel()))
        hasListener = listener != nil
        applyClinic()
    }

    func applyClinic() {
        guard let controller else { return }
        let services = browser.services
        switch ClinicSelection.choose(available: Array(services.keys), remembered: UserDefaults.standard.string(forKey: Self.clinicKey)) {
        case .connected(let name): controller.submitter = Submitter(transport: NetworkTransport(endpoint: services[name]!))
        case .none, .needsPicker: controller.submitter = nil
        }
    }

    /// The browser never restarts by itself after failing (e.g. Local Network access granted late), so restart it on demand.
    func restartBrowsing(onlyIfEmpty: Bool = false) {
        guard !onlyIfEmpty || browser.services.isEmpty else { return }
        browser.stop(); browser.start()
    }
}

struct RootView: View {
    let kiosk: Kiosk

    var body: some View {
        if let controller = kiosk.controller {
            screen(controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { controller.noteActivity() })
                .alert("Are you still there?", isPresented: Binding(get: { controller.isAskingStillThere }, set: { if !$0 { controller.stillHere() } })) {
                    Button("I'm still here") { controller.stillHere() }
                }
        } else {
            ProgressView("Getting ready…")
        }
    }

    @ViewBuilder private func screen(_ controller: KioskController) -> some View {
        switch controller.flow.phase {
        case .welcome:
            WelcomeView(kiosk: kiosk, controller: controller)
        case .asking(let i), .confirmingCandidate(let i):
            QuestionView(controller: controller, index: i, canUseVoice: kiosk.hasListener).id(i)
        case .review:
            ReviewView(controller: controller)
        case .sending:
            ProgressView("Sending to the clinic…").controlSize(.large)
        case .sendFailed(let message):
            VStack(spacing: 24) {
                Text(message).font(.title2).multilineTextAlignment(.center)
                Button("Try again") { controller.send() }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding()
        case .done:
            Text("Thanks, please take a seat.").font(.largeTitle.bold()).multilineTextAlignment(.center).padding()
        }
    }
}
