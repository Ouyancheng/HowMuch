import Foundation

struct DurableStopSharingRetry: Codable, Equatable {
    let containerIdentifier: String
    let accountRecordName: String
    let originalLedgerUUID: UUID
    let originalObjectURI: String
    let retainedLedgerUUID: UUID?
    let retainedObjectURI: String?
    let zoneName: String
    let zoneOwnerName: String
    let role: SharingMembershipRole
    var accountFingerprint: String? = nil

    func matches(
        containerIdentifier: String,
        accountRecordName: String,
        accountFingerprint: String,
        originalLedgerUUID: UUID,
        originalObjectURI: String,
        zoneName: String,
        zoneOwnerName: String,
        role: SharingMembershipRole
    ) -> Bool {
        self.containerIdentifier == containerIdentifier
            && self.accountRecordName == accountRecordName
            && (self.accountFingerprint
                ?? CloudIdentityFingerprint.make(
                    containerIdentifier: self.containerIdentifier,
                    accountRecordName: self.accountRecordName
                )) == accountFingerprint
            && self.originalLedgerUUID == originalLedgerUUID
            && self.originalObjectURI == originalObjectURI
            && self.zoneName == zoneName
            && self.zoneOwnerName == zoneOwnerName
            && self.role == role
    }
}

enum DurableStopSharingRetryLookup {
    case missing
    case found(DurableStopSharingRetry)
    case unsafe
}

struct StopSharingRetryStore {
    private static let defaultKey = "sharing.stopSharingRetries.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func lookup(originalLedgerUUID: UUID, originalObjectURI: String) -> DurableStopSharingRetryLookup {
        guard let data = defaults.data(forKey: key) else {
            return .missing
        }
        guard let records = try? JSONDecoder().decode([DurableStopSharingRetry].self, from: data) else {
            return .unsafe
        }
        let matchingUUID = records.filter { $0.originalLedgerUUID == originalLedgerUUID }
        guard !matchingUUID.isEmpty else {
            return .missing
        }
        guard let exact = matchingUUID.first(where: { $0.originalObjectURI == originalObjectURI }),
              matchingUUID.allSatisfy({ $0.originalObjectURI == originalObjectURI }) else {
            return .unsafe
        }
        return .found(exact)
    }

    @discardableResult
    func save(_ record: DurableStopSharingRetry) -> Bool {
        var records: [DurableStopSharingRetry]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DurableStopSharingRetry].self, from: data) {
            records = decoded.filter {
                $0.originalLedgerUUID != record.originalLedgerUUID
                    && $0.originalObjectURI != record.originalObjectURI
            }
        } else {
            records = []
        }
        records.append(record)
        guard let encoded = try? JSONEncoder().encode(records) else {
            return false
        }
        defaults.set(encoded, forKey: key)
        return defaults.synchronize()
    }

    @discardableResult
    func remove(originalLedgerUUID: UUID, originalObjectURI: String) -> Bool {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DurableStopSharingRetry].self, from: data) else {
            defaults.removeObject(forKey: key)
            return defaults.synchronize()
        }
        let remaining = decoded.filter {
            $0.originalLedgerUUID != originalLedgerUUID
                && $0.originalObjectURI != originalObjectURI
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let encoded = try? JSONEncoder().encode(remaining) {
            defaults.set(encoded, forKey: key)
        } else {
            return false
        }
        return defaults.synchronize()
    }
}
