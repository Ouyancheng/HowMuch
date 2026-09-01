import CloudKit
import CoreData
import SwiftUI

struct FamilySharingView: View {
    @ObservedObject var ledger: Ledger
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var share: CKShare?
    @State private var isPreparing = false
    @State private var isStopping = false
    @State private var showingStopConfirmation = false
    @State private var stopRetry: StopSharingRetry?
    @State private var systemStopPending = false
    @State private var showingShareSheet = false
    @State private var errorMessage: String?
    @State private var participants: [ShareParticipantInfo] = []

    private var sharingActionAvailable: Bool {
        persistence.cloudKitEnabled && accountMonitor.isAvailable && !isPreparing && !isStopping
    }

    private var stoppingActionAvailable: Bool {
        sharingActionAvailable && persistence.canSafelyStopSharing
    }

    private var ledgerAccess: LedgerAccess {
        persistence.access(for: ledger)
    }

    private var isOwner: Bool {
        ledgerAccess.canManageSharing
    }

    private var isParticipant: Bool {
        ledgerAccess.canLeaveSharing
    }

    private var sharingRole: SharingMembershipRole {
        isParticipant ? .participant : .owner
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Ledger", comment: "Field"), value: ledger.wrappedName)
                LabeledContent(String(localized: "iCloud", comment: "Field"), value: iCloudStatusValue)
            } footer: {
                Text(sharingFooter)
                    .hmWrappingFooter()
            }

            if !sharingActionAvailable && !isPreparing {
                Section {
                    iCloudStatusBanner()
                }
            }

            Section(String(localized: "Participants", comment: "Section")) {
                if participants.isEmpty {
                    Text(String(localized: "No one else is on this ledger yet."))
                        .foregroundStyle(.secondary)
                        .hmWrappingText()
                } else {
                    ForEach(participants) { participant in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(participant.name)
                                if participant.isCurrentUser {
                                    Text(String(localized: "You", comment: "Current sharing participant"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(participant.role) · \(participant.permission)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                if isOwner {
                    Button {
                        Task { await shareLedger() }
                    } label: {
                        if isPreparing {
                            ProgressView()
                        } else {
                            Label(
                                share == nil
                                    ? String(localized: "Share Ledger", comment: "Button")
                                    : String(localized: "Manage Sharing", comment: "Button"),
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                    .disabled(!sharingActionAvailable)
                    #if os(macOS)
                    .background {
                        MacCloudShareTrigger(
                            share: share,
                            container: persistence.cloudKitEnabled ? persistence.cloudKitContainer() : nil,
                            isPresented: $showingShareSheet
                        )
                    }
                    #endif
                }

                if share != nil && (isOwner || isParticipant) {
                    Button(role: .destructive) {
                        showingStopConfirmation = true
                    } label: {
                        Text(sharingRole == .participant
                             ? String(localized: "Leave Family", comment: "Button")
                             : String(localized: "Stop Sharing", comment: "Button"))
                    }
                    .disabled(!stoppingActionAvailable)
                }
            } footer: {
                if share != nil && !persistence.canSafelyStopSharing {
                    Text(
                        String(
                            localized: "Wait for iCloud setup or import to finish before stopping or leaving. The complete source must be available first.",
                            comment: "Stop sharing waiting explanation"
                        )
                    )
                    .hmWrappingFooter()
                } else if isOwner && !sharingActionAvailable {
                    Text(shareBlockedReason)
                        .hmWrappingFooter()
                } else if ledgerAccess == .unknown {
                    Text(LedgerAccess.readOnlyExplanation)
                        .hmWrappingFooter()
                }
            }

            if isStopping {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(sharingRole == .owner
                             ? String(localized: "Saving a private copy, then stopping sharing…", comment: "Sharing progress")
                             : String(localized: "Removing the shared ledger from this device…", comment: "Sharing progress"))
                            .hmWrappingText()
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    if stopRetry != nil || systemStopPending {
                        Button {
                            Task {
                                if systemStopPending, let share {
                                    await completeSystemStop(using: share)
                                } else {
                                    await stop()
                                }
                            }
                        } label: {
                            Label(String(localized: "Retry", comment: "Button"), systemImage: "arrow.clockwise")
                        }
                        .disabled(isStopping)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Family Sharing", comment: "Screen title"))
        .onAppear(perform: reload)
        .confirmationDialog(
            stopConfirmationTitle,
            isPresented: $showingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(stopConfirmationButton, role: .destructive) {
                Task { await stop() }
            }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {}
        } message: {
            Text(stopConfirmationMessage)
        }
        #if os(iOS)
        .sheet(isPresented: $showingShareSheet) {
            if let share {
                CloudShareSheet(
                    share: share,
                    container: persistence.cloudKitContainer(),
                    onEnd: {
                        persistence.invalidateLedgerAccess(for: ledger)
                        reload()
                    },
                    onStop: {
                        Task { await completeSystemStop(using: share) }
                    },
                    onError: { error in
                        errorMessage = String(
                            localized: "Sharing changes could not be saved: \(error.localizedDescription)",
                            comment: "Share sheet error"
                        )
                    }
                )
                .ignoresSafeArea()
            }
        }
        #endif
    }

    private var iCloudStatusValue: String {
        if !persistence.cloudKitEnabled {
            String(localized: "Sync Off", comment: "iCloud account status")
        } else {
            accountMonitor.statusDescription
        }
    }

    private var sharingFooter: String {
        if persistence.cloudKitEnabled && accountMonitor.isAvailable {
            String(localized: "Invite someone with their Apple Account using Messages or Mail. They get the same family expenses, not a bill split.")
        } else {
            persistence.iCloudSyncDetail
        }
    }

    private var shareBlockedReason: String {
        if !persistence.cloudKitEnabled {
            persistence.iCloudSyncDetail
        } else if !accountMonitor.isAvailable {
            PlatformCopy.signInToICloud
        } else {
            ""
        }
    }

    private var stopConfirmationTitle: String {
        sharingRole == .owner
            ? String(localized: "Stop sharing this family ledger?", comment: "Confirmation title")
            : String(localized: "Leave this family ledger?", comment: "Confirmation title")
    }

    private var stopConfirmationButton: String {
        sharingRole == .owner
            ? String(localized: "Save Private Copy and Stop", comment: "Confirmation button")
            : String(localized: "Leave and Remove Local Data", comment: "Confirmation button")
    }

    private var stopConfirmationMessage: String {
        if sharingRole == .owner {
            return String(localized: "A complete private copy will be saved automatically. The shared ledger will then be removed for every participant.", comment: "Confirmation message")
        }
        return String(localized: "This shared ledger and its expenses will be removed from this device. You will not keep a local copy.", comment: "Confirmation message")
    }

    private func reload() {
        persistence.invalidateLedgerAccess(for: ledger)
        share = persistence.existingShare(for: ledger)
        participants = persistence.participants(for: ledger)
    }

    @MainActor
    private func shareLedger() async {
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        do {
            let prepared = try await persistence.prepareShare(for: ledger)
            share = prepared
            participants = persistence.participants(for: ledger)
            showingShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func stop() async {
        guard !isStopping else { return }
        isStopping = true
        errorMessage = nil
        defer { isStopping = false }
        do {
            let result = try await persistence.stopSharing(ledger, retry: stopRetry)
            stopRetry = nil
            systemStopPending = false
            appState.selectedLedgerID = result.selectedLedgerID
            dismiss()
        } catch let error as PersistenceShareError {
            stopRetry = error.retry
            if let retainedLedgerID = error.retainedLedgerID {
                appState.selectedLedgerID = retainedLedgerID
            }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func completeSystemStop(using knownShare: CKShare) async {
        guard !isStopping else { return }
        isStopping = true
        systemStopPending = true
        stopRetry = nil
        errorMessage = nil
        defer { isStopping = false }
        do {
            let result = try await persistence.completeSystemStopSharing(
                ledger,
                knownShare: knownShare
            )
            systemStopPending = false
            appState.selectedLedgerID = result.selectedLedgerID
            dismiss()
        } catch let error as PersistenceShareError {
            if let retainedLedgerID = error.retainedLedgerID {
                appState.selectedLedgerID = retainedLedgerID
            }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
