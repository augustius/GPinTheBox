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
        let submitter: Submitter? = switch ClinicSelection.choose(available: Array(services.keys), remembered: UserDefaults.standard.string(forKey: Self.clinicKey)) {
        case .connected(let name): Submitter(transport: NetworkTransport(endpoint: services[name]!))
        case .none, .needsPicker: nil
        }
        // Bonjour results blip; mid-session keep the last good clinic rather than dropping it.
        if controller.flow.phase == .welcome || controller.submitter == nil { controller.submitter = submitter }
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
        Group {
            if let controller = kiosk.controller {
                screen(controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ActivityTracker { [weak kiosk] in kiosk?.controller?.noteActivity() })
                    // Chat and review present their own alert, so it can show over their edit sheet instead.
                    .stillThereAlert(controller, enabled: controller.flow.currentIndex == nil && controller.flow.phase != .review)
                    .onChange(of: controller.flow.phase == .welcome) { kiosk.applyClinic() }
            } else {
                ProgressView("Getting ready…")
            }
        }
        .tint(Theme.voiceBlue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func screen(_ controller: KioskController) -> some View {
        switch controller.flow.phase {
        case .welcome:
            WelcomeView(kiosk: kiosk, controller: controller)
        case .asking:
            ChatView(controller: controller)
        case .cantProceed:
            VStack(spacing: 28) {
                if let line = controller.messages.last(where: { $0.role == .kiosk })?.text {
                    Text(line).font(.title3).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
                Text("Please see reception").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Button { controller.reset() } label: { Text("Start over").font(.title2.bold()).frame(maxWidth: 400) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(32).frame(maxWidth: 720)
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

extension View {
    func stillThereAlert(_ controller: KioskController, enabled: Bool = true) -> some View {
        alert("Are you still there?", isPresented: Binding(get: { enabled && controller.isAskingStillThere },
                                                         set: { if !$0 { controller.stillHere() } })) {
            Button("I'm still here") { controller.stillHere() }
        }
    }
}

/// Records activity for every touch in the window (sheets, list rows, scrolling) without taking touches from controls.
private struct ActivityTracker: UIViewRepresentable {
    let onTouch: @MainActor () -> Void
    func makeUIView(context: Context) -> TrackerView { TrackerView() }
    func updateUIView(_ view: TrackerView, context: Context) { view.recognizer.onTouch = onTouch }

    final class TrackerView: UIView {
        let recognizer = TouchRecognizer()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    final class TouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onTouch: @MainActor () -> Void = {}
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onTouch(); state = .failed }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
