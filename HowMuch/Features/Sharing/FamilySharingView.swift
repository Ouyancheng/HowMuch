import CloudKit
import CoreData
import SwiftUI

struct FamilySharingView: View {
    @ObservedObject var ledger: Ledger
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor

    @State private var share: CKShare?
    @State private var isPreparing = false
    @State private var showingShareSheet = false
    @State private var errorMessage: String?
    @State private var participants: [ShareParticipantInfo] = []

    private var canShare: Bool {
        persistence.cloudKitEnabled && accountMonitor.isAvailable && !isPreparing
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

            if !canShare && !isPreparing {
                Section {
                    iCloudStatusBanner()
                }
            }

            Section(String(localized: "Participants", comment: "Section")) {
                if participants.isEmpty {
                    Text("No one else is on this ledger yet.")
                        .foregroundStyle(.secondary)
                        .hmWrappingText()
                } else {
                    ForEach(participants) { participant in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(participant.name)
                                if participant.isCurrentUser {
                                    Text("You")
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
                .disabled(!canShare)
                #if os(macOS)
                .background {
                    MacCloudShareTrigger(
                        share: share,
                        container: persistence.cloudKitEnabled ? persistence.cloudKitContainer() : nil,
                        isPresented: $showingShareSheet
                    )
                }
                #endif

                if share != nil {
                    Button(role: .destructive) {
                        Task { await stop() }
                    } label: {
                        Text(persistence.isInSharedStore(ledger)
                             ? String(localized: "Leave Family", comment: "Button")
                             : String(localized: "Stop Sharing", comment: "Button"))
                    }
                }
            } footer: {
                if !canShare {
                    Text(shareBlockedReason)
                        .hmWrappingFooter()
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Family Sharing", comment: "Screen title"))
        .onAppear(perform: reload)
        #if os(iOS)
        .sheet(isPresented: $showingShareSheet) {
            if let share {
                CloudShareSheet(share: share, container: persistence.cloudKitContainer()) {
                    reload()
                }
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
            String(localized: "Invite someone with their Apple ID using Messages or Mail. They get the same family expenses, not a bill split.")
        } else {
            persistence.iCloudSyncDetail
        }
    }

    private var shareBlockedReason: String {
        if !persistence.cloudKitEnabled {
            persistence.iCloudSyncDetail
        } else if !accountMonitor.isAvailable {
            String(localized: "Sign in to iCloud in System Settings, then return here to send an invite.")
        } else {
            ""
        }
    }

    private func reload() {
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
        errorMessage = nil
        do {
            try await persistence.stopSharing(ledger)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
