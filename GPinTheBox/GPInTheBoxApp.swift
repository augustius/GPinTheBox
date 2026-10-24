import SwiftUI
import SwiftData
import Records
import Intake
import Assistant
import UserNotifications

@main struct GPInTheBoxApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            if let container = model.container {
                AppEntryView(model: model).modelContainer(container).frame(minWidth: 1000, minHeight: 700).task { await model.start() }
            } else {
                ContentUnavailableView("Records could not open", systemImage: "externaldrive.badge.exclamationmark", description: Text(model.startupError ?? "Unknown storage error"))
            }
        }.defaultSize(width: 1200, height: 820)
        Settings {
            if model.container != nil { QuestionnaireEditor(model: model).frame(width: 700, height: 600) }
        }
    }
}
@MainActor @Observable final class AppModel {
    let container: ModelContainer?
    let store: RecordStore?
    var startupError: String?
    var serverURL: String?
    var serverError: String?
    var availability: ModelAvailability = .available
    var selectedVisitID: UUID?
    var recordingVisitID: UUID?
    var microphoneIsRecording = false
    var arrivalRevision = 0
    var embedder: ContextualEmbedder?
    private var started = false
    private var serverTask: Task<Void, Never>?
    init() {
        do { let container = try GPInTheBoxSchema.makeContainer(); self.container = container; store = RecordStore(modelContainer: container) }
        catch { container = nil; store = nil; startupError = error.localizedDescription }
    }
    func start() async {
        guard !started, let store else { return }; started = true
        do { try await store.seedDefaultQuestionnaireIfEmpty() }
        catch { serverError = error.localizedDescription; return }
        refreshAvailability()
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
        serverURL = LocalAddress.primaryIPv4().map { "http://\($0):8080" }
        serverTask = Task { [weak self] in
            do {
                try await IntakeServer(store: store, onSubmission: { [weak self] receipt in
                    await self?.received(receipt)
                }).run()
            } catch is CancellationError {} catch { self?.serverError = "Intake server couldn't start: \(error.localizedDescription)" }
        }
    }
    func refreshAvailability() { availability = FoundationModelsAssistant().availability() }
    func prepareEmbedder() async -> ContextualEmbedder? {
        if let embedder { return embedder }
        let value = await ContextualEmbedder.make(); embedder = value; return value
    }
    private func received(_ receipt: SubmissionReceipt) async {
        arrivalRevision += 1
        let content = UNMutableNotificationContent()
        content.title = "\(receipt.isNewPatient ? "New patient" : "Returning patient"): \(receipt.patientName)"
        content.body = "Intake form received."; content.sound = nil
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: receipt.visitID.uuidString, content: content, trigger: nil))
    }
}
struct AppEntryView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var showingGP = false
    var body: some View {
        Group {
            if showingGP {
                ClinicView(model: model, goHome: {
                    model.selectedVisitID = nil
                    showingGP = false
                })
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    Label("GPInTheBox", systemImage: "cross.case.fill").font(.largeTitle.bold()).foregroundStyle(.teal)
                    Text("Welcome. Choose your pathway.").font(.title2)
                    Text("Patients complete their intake. GPs manage visits and access patient records.").foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 24) {
                        pathway(title: "Patient", icon: "person.crop.rectangle", detail: "Tell your GP why you are visiting. Complete your details and intake questions, then submit your answers to the clinic queue.", button: "Open patient form") {
                            openURL(URL(string: "http://127.0.0.1:8080/intake")!)
                        }
                        pathway(title: "GP workspace", icon: "stethoscope", detail: "View the visit queue, open the patient database, review history, and record the consultation.", button: "Open GP workspace") {
                            showingGP = true
                        }
                    }
                    if let error = model.serverError {
                        Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                    } else if let url = model.serverURL {
                        Text("Patient phone access: \(url)").font(.callout.monospaced()).textSelection(.enabled)
                    }
                    Text("Synthetic-data demo · Records and consultation tools stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                }.padding(48).frame(maxWidth: 1050).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.teal.opacity(0.04))
            }
        }
        .onOpenURL { url in
            if url.scheme == "gpinthebox", url.host == "workspace" { showingGP = true }
        }
    }
    private func pathway(title: String, icon: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.teal)
            Text(title).font(.title.bold())
            Text(detail).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                .disabled(title == "Patient" && (model.serverURL == nil || model.serverError != nil))
        }.padding(28).frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.teal.opacity(0.2)))
    }
}
struct ClinicView: View {
    @Bindable var model: AppModel
    var goHome: () -> Void = {}
    @Environment(\.scenePhase) private var phase
    @State private var showingPatientDatabase = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label("GPInTheBox", systemImage: "cross.case.fill").font(.title2.bold()).foregroundStyle(.teal).padding(.horizontal)
                Text("TODAY’S CLINIC").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    QueueSidebar(model: model, date: context.date)
                        .id(Calendar.current.startOfDay(for: context.date))
                }
                Text("Synthetic-data demo · Local only").font(.caption).foregroundStyle(.secondary).padding()
            }.padding(.top, 20).navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            VStack(spacing: 0) {
                if case .unavailable(let reason) = model.availability {
                    Label(AssistantError.unavailable(reason).userMessage, systemImage: "exclamationmark.triangle").padding().frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12))
                }
                SelectedPatient(model: model)
            }
        }
        .sheet(isPresented: $showingPatientDatabase) { PatientDatabaseView(model: model) }
        .toolbar {
            ToolbarItem { Button("Home", systemImage: "house", action: goHome).disabled(model.recordingVisitID != nil).help("Return to pathway selection; stop recording first") }
            ToolbarItem { Button("Patient database", systemImage: "person.text.rectangle") { showingPatientDatabase = true } }
            ToolbarItem(placement: .automatic) {
                if let error = model.serverError { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red) }
                else if let url = model.serverURL {
                    HStack { Text("Clinic landing: \(url)").font(.callout.monospaced()); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy clinic landing URL") }
                } else { Text("Waiting for a LAN address").foregroundStyle(.secondary) }
            }
            ToolbarItem { SettingsLink { Image(systemName: "slider.horizontal.3") }.help("Edit questionnaire") }
        }
        .onChange(of: phase) { _, value in if value == .active { model.refreshAvailability() } }
    }
}
struct QueueSidebar: View {
    @Bindable var model: AppModel
    @Query private var visits: [Visit]
    init(model: AppModel, date: Date) {
        self.model = model
        _visits = Query(filter: Visit.arrivedOnSameDay(as: date, calendar: .current), sort: \Visit.arrivedAt)
    }
    var body: some View {
        List(selection: $model.selectedVisitID) {
            ForEach(visits) { visit in
                VStack(alignment: .leading, spacing: 7) {
                    Text(visit.patient?.fullName ?? "Patient").font(.headline)
                    HStack {
                        Text(visit.arrivedAt, style: .time).foregroundStyle(.secondary)
                        Spacer()
                        Text(visit.status == .waiting ? "Waiting" : visit.status == .inConsult ? "In consult" : "Done")
                            .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(visit.status == .done ? Color.gray.opacity(0.15) : Color.teal.opacity(0.14), in: Capsule())
                    }
                }.padding(.vertical, 7).tag(visit.id)
            }
        }.overlay { if visits.isEmpty { ContentUnavailableView("No arrivals yet", systemImage: "person.crop.rectangle.stack", description: Text("Submit a synthetic intake form to get started.")) } }
    }
}
struct SelectedPatient: View {
    @Bindable var model: AppModel
    @Query private var visits: [Visit]
    var body: some View {
        if let visit = visits.first(where: { $0.id == model.selectedVisitID }) {
            PatientDetailView(visit: visit, model: model).id(visit.id)
        } else {
            ContentUnavailableView("Select a patient", systemImage: "person.text.rectangle", description: Text("Intake, notes, and cited on-device assistance in one place."))
        }
    }
}
private enum VisitSection: String, CaseIterable, Identifiable {
    case intake = "Intake", recording = "Recording", notes = "GP Notes", history = "History", assistant = "Assistant"
    var id: String { rawValue }
}

struct PatientDetailView: View {
    @Bindable var visit: Visit
    @Query(sort: \Visit.arrivedAt) private var allVisits: [Visit]
    @Query(sort: \Consultation.startedAt) private var allConsultations: [Consultation]
    let model: AppModel
    @Environment(\.modelContext) private var context
    @State private var error: String?
    @State private var correcting = false
    @State private var section: VisitSection = .intake
    @State private var recoveredHistory: PatientSnapshot?
    @State private var historyError: String?
    @State private var loadingHistory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let patient = visit.patient {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(patient.fullName).font(.largeTitle.bold())
                            Text("Born \(patient.dateOfBirth) · \(visit.arrivedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Correct identity") { correcting = true }
                        Button("Finish visit") { visit.finish(); save() }
                            .buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(visit.status == .done || model.recordingVisitID == visit.id)
                    }
                    Text("GP workspace · Patient intake first, consultation tools in their own sections.")
                        .font(.caption).foregroundStyle(.secondary)
                    historyLookupStatus
                    Picker("Visit section", selection: $section) {
                        ForEach(VisitSection.allCases) { item in Text(item.rawValue).tag(item) }
                    }.pickerStyle(.segmented)
                    if model.recordingVisitID == visit.id {
                        HStack {
                            Label(model.microphoneIsRecording ? "Recording in progress" : "Preparing microphone…", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Open recording controls") { section = .recording }
                        }.padding(10).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }.padding(24)
                Divider()
                // Keep each section mounted so notes, drafts and recording survive section
                // navigation. Removing the entire visit still triggers recording cleanup.
                ZStack(alignment: .topLeading) {
                    sectionPane(.intake) { intakeSection }
                    sectionPane(.recording) { ConsultationPanel(visit: visit, model: model) }
                    sectionPane(.notes) { notesSection(patient: patient) }
                    sectionPane(.history) { historySection(patient: patient) }
                    sectionPane(.assistant) { AssistantPanel(patient: currentSnapshot(for: patient), visitID: visit.id, model: model) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
        .onAppear { visit.open(); save() }
        .task(id: visit.patient?.revision) { await recoverHistory() }
        .sheet(isPresented: $correcting) { if let patient = visit.patient { IdentityEditor(patient: patient, model: model) } }
    }

    private var historyLookupStatus: some View {
        GroupBox {
            HStack(spacing: 12) {
                if loadingHistory {
                    ProgressView().controlSize(.small)
                    Text("Searching patient records…")
                } else if let historyError {
                    Label(historyError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Retry lookup") { Task { await recoverHistory() } }
                } else if let recoveredHistory {
                    let count = recoveredHistory.visits.count
                    VStack(alignment: .leading, spacing: 4) {
                        Label(count == 0 ? "No previous history found" : "Patient history recovered",
                              systemImage: count == 0 ? "person.crop.circle.badge.plus" : "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(count == 0
                             ? "The local patient record has no visits before this intake."
                             : "Matched by Medicare / insurance ID and date of birth · \(count) previous visit\(count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if count > 0 { Button("Review history") { section = .history } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    @MainActor private func recoverHistory() async {
        loadingHistory = true
        historyError = nil
        recoveredHistory = nil
        defer { loadingHistory = false }
        guard let patient = visit.patient, let store = model.store else {
            historyError = "Patient records are unavailable."
            return
        }
        do {
            recoveredHistory = try await store.history(patientID: patient.id, beforeVisitID: visit.id)
        } catch {
            historyError = "History lookup failed: \(error.localizedDescription)"
        }
    }

    private func sectionPane<Content: View>(_ value: VisitSection, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .opacity(section == value ? 1 : 0)
        .allowsHitTesting(section == value)
        .disabled(section != value)
        .accessibilityHidden(section != value)
        .zIndex(section == value ? 1 : 0)
    }

    private var intakeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Patient intake").font(.title2.bold())
            Text("Answers submitted by the patient before the consultation. The patient’s browser only has access to the intake form.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(visit.answers, id: \.questionID) { answer in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(answer.prompt).font(.subheadline.weight(.semibold))
                            Text(answer.value.isEmpty ? "Not provided" : answer.value)
                                .foregroundStyle(answer.value.isEmpty ? .secondary : .primary).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Button("Continue to recording") { section = .recording }.buttonStyle(.borderedProminent).tint(.teal)
        }
    }

    private func notesSection(patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GP notes").font(.title2.bold())
            Text("Write clinical notes for this visit. Changes are saved automatically.").foregroundStyle(.secondary)
            GroupBox {
                TextEditor(text: Binding(get: { visit.gpNote }, set: { value in
                    visit.gpNote = value; visit.noteUpdatedAt = .now; patient.revision = UUID(); save()
                })).font(.body).frame(minHeight: 280).padding(8).accessibilityLabel("GP visit note")
            }
        }
    }

    private func historySection(patient: Patient) -> some View {
        let past = allVisits.filter { $0.patient?.id == patient.id && $0.id != visit.id && $0.arrivedAt <= visit.arrivedAt }.sorted { $0.arrivedAt > $1.arrivedAt }
        return VStack(alignment: .leading, spacing: 16) {
            Text("Patient history").font(.title2.bold())
            Text("Previous intake, GP notes, transcripts, and approved consultation summaries.").foregroundStyle(.secondary)
            if past.isEmpty {
                ContentUnavailableView("No previous visits", systemImage: "clock", description: Text("Completed visit records will be available here at the next consultation."))
            } else {
                ForEach(past) { previous in
                    GroupBox {
                        DisclosureGroup(previous.arrivedAt.formatted(date: .abbreviated, time: .shortened)) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(previous.answers, id: \.questionID) { answer in Text("\(answer.prompt)\n\(answer.value.isEmpty ? "Not provided" : answer.value)") }
                                Text("GP note: \(previous.gpNote.isEmpty ? "None" : previous.gpNote)").fontWeight(.medium)
                                ForEach(allConsultations.filter { $0.visitID == previous.id && $0.patientID == patient.id && $0.archivedAt == nil }) { consultation in
                                    if let approved = consultation.approvedSnapshot() {
                                        Text("GP-reviewed consultation summary").font(.headline)
                                        Text(approved.text)
                                        Text("Approved \(approved.approvedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if consultation.wasInterrupted { Text("Partial recording: the transcript may not cover the whole consultation.").font(.caption).foregroundStyle(.orange) }
                                    if !consultation.transcript.isEmpty {
                                        DisclosureGroup("Consultation transcript · \(consultation.startedAt.formatted(date: .omitted, time: .shortened))") { Text(consultation.conversationText).padding(.top, 6) }
                                    }
                                }
                            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                        }.padding(10)
                    }
                }
            }
        }
    }
    private func currentSnapshot(for patient: Patient) -> PatientSnapshot {
        // A background intake save can refresh Visit queries before SwiftData refreshes
        // an already-loaded inverse relationship. Build history from the live query.
        let history = allVisits.filter { $0.patient?.id == patient.id }.sorted {
            $0.arrivedAt == $1.arrivedAt ? $0.id.uuidString < $1.id.uuidString : $0.arrivedAt < $1.arrivedAt
        }.map { VisitSnapshot(id: $0.id, arrivedAt: $0.arrivedAt, answers: $0.answers, gpNote: $0.gpNote, noteUpdatedAt: $0.noteUpdatedAt, consultationSummaries: consultationSummaries(for: $0.id)) }
        return PatientSnapshot(id: patient.id, fullName: patient.fullName, dateOfBirth: patient.dateOfBirth, revision: patient.revision, visits: history)
    }
    private func consultationSummaries(for visitID: UUID) -> [ConsultationSummarySnapshot] {
        allConsultations.filter { $0.visitID == visitID && $0.patientID == visit.patient?.id }.compactMap { $0.approvedSnapshot() }
    }
    private func save() { do { try context.save(); error = nil } catch { self.error = "Could not save: \(error.localizedDescription)" } }
}
struct IdentityEditor: View {
    let patient: Patient; let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""; @State private var medicare = ""; @State private var dob = ""; @State private var error: String?; @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Correct patient identity").font(.title2.bold())
            Text("Corrections apply to this patient’s existing visits. Records are never merged automatically.").foregroundStyle(.secondary)
            TextField("Full name", text: $name); TextField("Medicare / insurance ID", text: $medicare); TextField("Date of birth (yyyy-MM-dd)", text: $dob)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save correction") {
                saving = true
                Task {
                    do {
                        try RecordMutations.correctIdentity(context: context, patientID: patient.id, fullName: name, medicareID: medicare, dateOfBirth: dob)
                        dismiss()
                    } catch { self.error = error.localizedDescription }; saving = false
                }
            }.buttonStyle(.borderedProminent).disabled(saving) }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 480)
        .onAppear { name = patient.fullName; medicare = patient.medicareID; dob = patient.dateOfBirth }
    }
}
