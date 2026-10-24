import SwiftUI
import KioskKit

struct WelcomeView: View {
    let kiosk: Kiosk
    let controller: KioskController
    @State private var showingSetup = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text("SteadyCare").font(.largeTitle.bold()).foregroundStyle(.white)
            Button { controller.start() } label: {
                Text("Tap to start.").font(.largeTitle.bold()).foregroundStyle(.white)
                    .frame(maxWidth: 480, minHeight: 120)
                    .background(Theme.voiceBlue.opacity(controller.submitter == nil ? 0.35 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(controller.submitter == nil)
            if controller.submitter == nil {
                Text("Clinic not found — ask reception").font(.title3).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if case .ready(_, isFallback: true) = kiosk.readiness {
                Text("Speech: English (US) — en-AU unavailable")
                    .font(.caption).foregroundStyle(Theme.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.composer, in: Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 2) { kiosk.restartBrowsing(); showingSetup = true }
        .sheet(isPresented: $showingSetup) { StaffSetupView(kiosk: kiosk) }
    }
}
