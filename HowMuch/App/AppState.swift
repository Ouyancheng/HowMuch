import Foundation
import Observation

struct PendingOpenedArchive: Identifiable, Sendable {
    let id: UUID
    let package: HowMuchEncodedArchive
}

struct ArchiveOpenFailure: Identifiable, Sendable {
    let id: UUID
    let message: String
}

@MainActor
@Observable
final class AppState {
    var selectedLedgerID: UUID? {
        didSet {
            if let selectedLedgerID {
                UserDefaults.standard.set(selectedLedgerID.uuidString, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
        }
    }
    var presentingNewExpense = false
    var presentingNewPersonal = false
    var presentingNewHousehold = false
    var presentingLedgerSettings = false
    var presentingSettings = false
    var expenseToEdit: Expense?
    private(set) var pendingOpenedArchive: PendingOpenedArchive?
    private(set) var archiveOpenFailure: ArchiveOpenFailure?
    private(set) var isOpeningArchive = false
    private(set) var archiveOpenEventGeneration = 0
    private(set) var observedStackGeneration = 0
    private var archiveOpenGeneration: UInt = 0

    private static let defaultsKey = "selectedLedgerID"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey), let uuid = UUID(uuidString: raw) {
            selectedLedgerID = uuid
        }
    }

    func resetForStackGeneration(_ generation: Int) {
        guard generation != observedStackGeneration else { return }
        let shouldPresentPendingArchive = pendingOpenedArchive != nil
            || archiveOpenFailure != nil
            || isOpeningArchive
        observedStackGeneration = generation
        selectedLedgerID = nil
        presentingNewExpense = false
        presentingNewPersonal = false
        presentingNewHousehold = false
        presentingLedgerSettings = false
        presentingSettings = shouldPresentPendingArchive
        expenseToEdit = nil
    }

    @discardableResult
    func beginOpeningArchive() -> UInt {
        archiveOpenGeneration &+= 1
        pendingOpenedArchive = nil
        archiveOpenFailure = nil
        isOpeningArchive = true
        presentingSettings = true
        archiveOpenEventGeneration &+= 1
        return archiveOpenGeneration
    }

    @discardableResult
    func finishOpeningArchive(_ package: HowMuchEncodedArchive, generation: UInt) -> Bool {
        guard generation == archiveOpenGeneration else { return false }
        pendingOpenedArchive = PendingOpenedArchive(id: UUID(), package: package)
        archiveOpenFailure = nil
        isOpeningArchive = false
        presentingSettings = true
        archiveOpenEventGeneration &+= 1
        return true
    }

    @discardableResult
    func failOpeningArchive(_ error: Error, generation: UInt) -> Bool {
        guard generation == archiveOpenGeneration else { return false }
        pendingOpenedArchive = nil
        archiveOpenFailure = ArchiveOpenFailure(id: UUID(), message: error.localizedDescription)
        isOpeningArchive = false
        presentingSettings = true
        archiveOpenEventGeneration &+= 1
        return true
    }

    func takePendingOpenedArchive() -> PendingOpenedArchive? {
        defer { pendingOpenedArchive = nil }
        return pendingOpenedArchive
    }

    func takeArchiveOpenFailure() -> ArchiveOpenFailure? {
        defer { archiveOpenFailure = nil }
        return archiveOpenFailure
    }
}
