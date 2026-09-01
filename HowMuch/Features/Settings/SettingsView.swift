import CoreData
import SwiftUI

struct SettingsView: View {
    #if os(macOS)
    @State private var selectedMacTab: MacSettingsTab = .general
    #endif

    var body: some View {
        #if os(macOS)
        TabView(selection: $selectedMacTab) {
            Tab(
                String(localized: "General", comment: "Settings tab"),
                systemImage: "gearshape",
                value: .general
            ) {
                SettingsGeneralPane()
            }
            Tab(
                String(localized: "iCloud", comment: "Settings tab"),
                systemImage: "icloud",
                value: .iCloud
            ) {
                SettingsiCloudPane()
            }
            #if DEBUG
            Tab(
                String(localized: "Developer", comment: "Settings tab"),
                systemImage: "hammer",
                value: .developer
            ) {
                SettingsDeveloperPane()
            }
            #endif
        }
        .accessibilityIdentifier("settings.screen")
        .frame(minWidth: 520, minHeight: 360)
        #else
        Form {
            SettingsiCloudSection()
            SettingsArchiveSection()
            SettingsPersonalLedgersSection()
            SettingsAboutSection()
            #if DEBUG
            SettingsDeveloperSection()
            #endif
        }
        .accessibilityIdentifier("settings.screen")
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Settings", comment: "Screen title"))
        #endif
    }
}

#if os(macOS)
private enum MacSettingsTab: Hashable {
    case general
    case iCloud
    #if DEBUG
    case developer
    #endif
}
#endif

struct SettingsGeneralPane: View {
    var body: some View {
        Form {
            SettingsAboutSection()
            SettingsArchiveSection()
            SettingsPersonalLedgersSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding(.top, 8)
        .accessibilityIdentifier("settings.general")
    }
}

struct SettingsiCloudPane: View {
    var body: some View {
        Form {
            SettingsiCloudSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding(.top, 8)
    }
}

#if DEBUG
struct SettingsDeveloperPane: View {
    var body: some View {
        Form {
            SettingsDeveloperSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding(.top, 8)
    }
}
#endif

private struct SettingsArchiveSection: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(AppState.self) private var appState
    @State private var includesReceipts = true
    @State private var archiveDocument: HowMuchArchiveDocument?
    @State private var presentsExporter = false
    @State private var presentsImporter = false
    @State private var importPreview: HowMuchImportPreview?
    @State private var importSelection = LatestSelectionToken()
    @State private var importProcessingTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle(
                String(localized: "Include Receipts", comment: "Archive export option"),
                isOn: $includesReceipts
            )
            Button {
                prepareExport()
            } label: {
                Label(String(localized: "Export Archive…", comment: "Archive action"), systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("archive.export")
            .disabled(isWorking)

            Button {
                presentsImporter = true
            } label: {
                Label(String(localized: "Import Archive…", comment: "Archive action"), systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("archive.import")
            .disabled(isWorking)

            if isWorking {
                HStack {
                    ProgressView()
                    Text(String(localized: "Preparing archive…", comment: "Archive progress"))
                        .foregroundStyle(.secondary)
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .hmWrappingText()
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .hmWrappingText()
            }
        } header: {
            Text(String(localized: "Archive", comment: "Settings section"))
        } footer: {
            Text(String(localized: "Archives are portable local copies. Import always writes to your private data store and never restores sharing.", comment: "Archive explanation"))
                .hmWrappingFooter()
        }
        .fileExporter(
            isPresented: $presentsExporter,
            document: archiveDocument,
            contentType: .howMuchArchive,
            defaultFilename: "HowMuch-\(Date.now.formatted(.iso8601.year().month().day()))"
        ) { result in
            archiveDocument = nil
            switch result {
            case .success:
                statusMessage = String(localized: "Archive exported successfully.", comment: "Archive success")
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $presentsImporter, allowedContentTypes: [.howMuchArchive]) { result in
            switch result {
            case .success(let url):
                prepareImport(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $importPreview) { preview in
            ArchiveImportPreviewView(preview: preview) { mode in
                performImport(preview.archive, mode: mode)
            }
        }
        .onChange(of: appState.archiveOpenEventGeneration, initial: true) { _, _ in
            consumeExternalArchiveEvent()
        }
        .onChange(of: persistence.isDataAvailable) { _, available in
            if available {
                consumeExternalArchiveEvent()
            }
        }
        .onDisappear {
            cancelImportPreparation()
        }
    }

    private func prepareExport() {
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let snapshot = try persistence.makeArchiveSnapshot(includeReceipts: includesReceipts)
                let package = try await Task.detached(priority: .userInitiated) {
                    try HowMuchArchiveCodec.encode(snapshot)
                }.value
                _ = try await HowMuchArchiveCodec.validate(package)
                archiveDocument = HowMuchArchiveDocument(package: package)
                presentsExporter = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func prepareImport(from url: URL) {
        startImportPreparation {
            try await Task.detached(priority: .userInitiated) {
                try HowMuchArchiveDocument.loadPackage(from: url)
            }.value
        }
    }

    private func prepareImport(from package: HowMuchEncodedArchive) {
        startImportPreparation {
            package
        }
    }

    private func startImportPreparation(
        _ loadPackage: @escaping () async throws -> HowMuchEncodedArchive
    ) {
        importProcessingTask?.cancel()
        let token = importSelection.begin()
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        importProcessingTask = Task {
            do {
                let package = try await loadPackage()
                let validated = try await HowMuchArchiveCodec.validate(package)
                try Task.checkCancellation()
                guard importSelection.isCurrent(token) else { return }
                importPreview = try persistence.previewImport(validated)
            } catch {
                guard importSelection.isCurrent(token), !(error is CancellationError) else { return }
                errorMessage = error.localizedDescription
            }
            guard importSelection.isCurrent(token) else { return }
            isWorking = false
            importProcessingTask = nil
        }
    }

    private func consumeExternalArchiveEvent() {
        guard persistence.isDataAvailable else { return }
        if appState.isOpeningArchive {
            cancelImportPreparation()
            importPreview = nil
            isWorking = true
            statusMessage = nil
            errorMessage = nil
            return
        }
        if let failure = appState.takeArchiveOpenFailure() {
            isWorking = false
            statusMessage = nil
            errorMessage = failure.message
            return
        }
        if let pending = appState.takePendingOpenedArchive() {
            prepareImport(from: pending.package)
        }
    }

    private func cancelImportPreparation() {
        importSelection.invalidate()
        importProcessingTask?.cancel()
        importProcessingTask = nil
        isWorking = false
    }

    private func performImport(_ archive: HowMuchValidatedArchive, mode: ArchiveImportMode) {
        importPreview = nil
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await persistence.importArchive(archive, mode: mode)
                statusMessage = String(localized: "Archive imported successfully.", comment: "Archive success")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ArchiveImportPreviewView: View {
    let preview: HowMuchImportPreview
    let importAction: (ArchiveImportMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ArchiveImportMode = .merge

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Archive Contents", comment: "Archive section")) {
                    Text(preview.summary)
                        .hmWrappingText()
                }
                Section {
                    Picker(String(localized: "Import Mode", comment: "Archive field"), selection: $mode) {
                        ForEach(ArchiveImportMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .hmWrappingText()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Import Preview", comment: "Archive title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Import", comment: "Button")) {
                        importAction(mode)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var modeExplanation: String {
        switch mode {
        case .merge:
            String(localized: "Creates missing UUIDs and leaves existing records unchanged.", comment: "Archive mode explanation")
        case .copies:
            String(localized: "Creates a separate copy of every record with new UUIDs.", comment: "Archive mode explanation")
        case .replace:
            String(localized: "Creates missing records and overwrites matching attributes and receipts. Records absent from the archive are never deleted.", comment: "Archive mode explanation")
        }
    }
}

private struct SettingsAboutSection: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        Section {
            HMSettingsValueRow(
                title: "HowMuch",
                value: version
            )
        } header: {
            Text(String(localized: "About", comment: "Section"))
        } footer: {
            Text(String(localized: "Spend tracking for individuals and families, using your Apple Account."))
                .hmWrappingFooter()
        }
    }
}

private struct SettingsPersonalLedgersSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)],
        predicate: NSPredicate(format: "kind == %d", LedgerKind.personal.rawValue)
    )
    private var personalLedgers: FetchedResults<Ledger>

    var body: some View {
        Section {
            ForEach(personalLedgers, id: \.objectID) { ledger in
                #if os(macOS)
                Button {
                    HowMuchPresenter.ledgerSettings(for: ledger, appState: appState, openWindow: openWindow)
                } label: {
                    HStack {
                        Label(ledger.wrappedName, systemImage: ledger.ledgerKind.symbolName)
                        Spacer(minLength: 12)
                        Text(ledger.wrappedReportingCurrency)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(ledger.managedObjectContext == nil)
                #else
                NavigationLink {
                    LedgerDetailView(ledger: ledger)
                } label: {
                    Label(ledger.wrappedName, systemImage: ledger.ledgerKind.symbolName)
                }
                #endif
            }

            Button {
                HowMuchPresenter.newPersonal(appState: appState, openWindow: openWindow)
            } label: {
                Label(String(localized: "New Personal Ledger", comment: "Settings action"), systemImage: "plus")
            }
        } header: {
            Text(String(localized: "Personal Ledgers", comment: "Section"))
        } footer: {
            Text(String(localized: "Personal ledgers stay private and sync across your own devices with iCloud."))
                .hmWrappingFooter()
        }
    }
}

private struct SettingsiCloudSection: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor

    private var showsStatusBanner: Bool {
        accountMonitor.shouldShowBanner
            || (!persistence.cloudKitEnabled && !accountMonitor.isDetermining)
            || persistence.loadState == .failed
            || persistence.diagnostic != nil
            || persistence.shareError != nil
    }

    private var loadStatus: String {
        switch persistence.loadState {
        case .waitingForAccount:
            String(localized: "Locked", comment: "Store status")
        case .loading:
            String(localized: "Loading…", comment: "Store status")
        case .loaded:
            String(localized: "Loaded", comment: "Store status")
        case .failed:
            String(localized: "Failed", comment: "Store status")
        }
    }

    private var syncStatus: String {
        if persistence.isLocalOnly {
            return String(localized: "Off — Local Only", comment: "Sync status")
        }
        return switch persistence.syncActivity {
        case .unavailable:
            String(localized: "Unavailable", comment: "Sync status")
        case .idle:
            String(localized: "Ready", comment: "Sync status")
        case .importing:
            String(localized: "Importing…", comment: "Sync status")
        case .exporting:
            String(localized: "Exporting…", comment: "Sync status")
        case .settingUp:
            String(localized: "Setting Up…", comment: "Sync status")
        case .failed:
            String(localized: "Error", comment: "Sync status")
        }
    }

    var body: some View {
        Section {
            if showsStatusBanner {
                iCloudStatusBanner()
            }
            HMSettingsValueRow(
                title: String(localized: "Account", comment: "Field"),
                value: accountMonitor.statusDescription
            )
            HMSettingsValueRow(
                title: String(localized: "iCloud Sync", comment: "Field"),
                value: syncStatus
            )
            HMSettingsValueRow(
                title: String(localized: "Data Store", comment: "Field"),
                value: loadStatus
            )
            if let lastSyncDate = persistence.lastSyncDate {
                HMSettingsValueRow(
                    title: String(localized: "Last Sync", comment: "Field"),
                    value: lastSyncDate.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let lastImportDate = persistence.lastImportDate {
                HMSettingsValueRow(
                    title: String(localized: "Last Import", comment: "Field"),
                    value: lastImportDate.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let lastExportDate = persistence.lastExportDate {
                HMSettingsValueRow(
                    title: String(localized: "Last Export", comment: "Field"),
                    value: lastExportDate.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let lastEvent = persistence.lastCloudEventDescription {
                HMSettingsValueRow(
                    title: String(localized: "Last Event", comment: "Field"),
                    value: lastEvent
                )
            }
        } header: {
            Text(String(localized: "iCloud", comment: "Section"))
        } footer: {
            if !showsStatusBanner {
                Text(persistence.iCloudSyncDetail)
                    .hmWrappingFooter()
            }
        }
        .onAppear {
            accountMonitor.refresh()
        }
    }
}

#if DEBUG
private struct SettingsDeveloperSection: View {
    @EnvironmentObject private var persistence: PersistenceController
    @State private var schemaMessage: String?

    var body: some View {
        Section {
            Button("Initialize CloudKit Schema") {
                guard persistence.cloudKitEnabled else {
                    schemaMessage = String(localized: "CloudKit is off, so the schema cannot be initialized.", comment: "Debug")
                    return
                }
                do {
                    try persistence.initializeCloudKitSchema()
                    schemaMessage = String(localized: "CloudKit schema initialized.", comment: "Debug")
                } catch {
                    schemaMessage = error.localizedDescription
                }
            }
            .disabled(!persistence.cloudKitEnabled)

            if let schemaMessage {
                Text(schemaMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .hmWrappingText()
            }
            if let loadError = persistence.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .hmWrappingText()
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Schema initialization needs a CloudKit-signed build.")
                .hmWrappingFooter()
        }
    }
}
#endif

#if DEBUG
#Preview("Settings") {
    HowMuchPreview.wrap(SettingsView())
        #if os(macOS)
        .frame(width: 560, height: 420)
        #endif
}

#if os(macOS)
#Preview("Settings iCloud") {
    HowMuchPreview.wrap(SettingsiCloudPane())
        .frame(width: 560, height: 420)
}
#endif
#endif
