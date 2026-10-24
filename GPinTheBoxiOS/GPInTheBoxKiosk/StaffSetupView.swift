import SwiftUI
import KioskKit

struct StaffSetupView: View {
    let kiosk: Kiosk
    @AppStorage(Kiosk.clinicKey) private var clinicName = ""
    @Environment(\.dismiss) private var dismiss
    @State private var downloading = false
    @State private var downloadError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Clinic") {
                    Picker("Clinic Mac", selection: $clinicName) {
                        Text("Automatic").tag("")
                        ForEach(kiosk.browser.services.keys.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if kiosk.browser.services.isEmpty { Text("Searching for clinic Macs…").foregroundStyle(.secondary) }
                }
                Section("Speech") {
                    Text(readinessText)
                    Button("Download speech assets") {
                        downloading = true; downloadError = nil
                        Task {
                            do { try await SpeechSetup.downloadAssets(); await kiosk.refreshSpeech() }
                            catch { downloadError = "Download failed: \(error.localizedDescription)" }
                            downloading = false
                        }
                    }
                    .disabled(downloading)
                    if downloading { ProgressView() }
                    if let downloadError { Text(downloadError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Staff setup")
            .toolbar { Button("Done") { dismiss() } }
        }
        .onChange(of: clinicName) { kiosk.applyClinic() }
    }

    private var readinessText: String {
        switch kiosk.readiness {
        case .ready(let id, let isFallback): "Ready (\(id))" + (isFallback ? " — en-AU unavailable" : "")
        case .needsDownload: "Speech assets not installed — typing mode until downloaded."
        case .unavailable(let reason): reason + " Typing mode."
        case nil: "Checking…"
        }
    }
}
