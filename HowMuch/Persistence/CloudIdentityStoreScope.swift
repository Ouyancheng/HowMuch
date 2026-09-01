import CryptoKit
import Foundation

enum CloudAccountIdentity: Equatable {
    case resolving
    case signedOut
    case unavailable(String)
    case available(fingerprint: String)
}

enum CloudIdentityFingerprint {
    static func make(containerIdentifier: String, accountRecordName: String) -> String {
        let source = Data("\(containerIdentifier)\u{0}\(accountRecordName)".utf8)
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }
}

struct ScopedStoreLocations: Equatable {
    let directory: URL
    let privateStore: URL
    let sharedStore: URL
    let adoptionMarker: URL
}

struct LocalStoreLocations: Equatable {
    let directory: URL
    let privateStore: URL
    let adoptionMarker: URL
}

private struct LegacyPrivateAdoptionClaim: Codable, Equatable {
    let version: Int
    let accountFingerprint: String
}

enum CloudStoreScope {
    static let accountsDirectoryName = "Accounts"
    static let localDirectoryName = "Local"
    static let adoptionMarkerName = ".unscoped-stores-adopted-v1"
    static let localAdoptionMarkerName = ".legacy-private-adopted-v1"
    static let baseAdoptionClaimName = ".legacy-private-adoption-claim-v1"
    static let adoptionIntentName = ".legacy-private-adoption-in-progress-v1"

    static func locations(baseDirectory: URL, fingerprint: String) -> ScopedStoreLocations {
        let directory = baseDirectory
            .appendingPathComponent(accountsDirectoryName, isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
        return ScopedStoreLocations(
            directory: directory,
            privateStore: directory.appendingPathComponent("private.sqlite"),
            sharedStore: directory.appendingPathComponent("shared.sqlite"),
            adoptionMarker: directory.appendingPathComponent(adoptionMarkerName)
        )
    }

    static func localLocations(baseDirectory: URL) -> LocalStoreLocations {
        let directory = baseDirectory.appendingPathComponent(localDirectoryName, isDirectory: true)
        return LocalStoreLocations(
            directory: directory,
            privateStore: directory.appendingPathComponent("private.sqlite"),
            adoptionMarker: directory.appendingPathComponent(localAdoptionMarkerName)
        )
    }

    /// Makes the supported no-entitlement store local-only. The legacy source
    /// remains as a backup; the marker prevents a later launch from recopying.
    static func prepareLocalStoreIfNeeded(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> LocalStoreLocations {
        let locations = localLocations(baseDirectory: baseDirectory)
        guard !fileManager.fileExists(atPath: locations.adoptionMarker.path) else {
            return locations
        }
        try fileManager.createDirectory(at: locations.directory, withIntermediateDirectories: true)

        let legacyPrivate = baseDirectory.appendingPathComponent("private.sqlite")
        if fileManager.fileExists(atPath: legacyPrivate.path) {
            try adoptSQLiteFamily(
                from: legacyPrivate,
                to: locations.privateStore,
                fileManager: fileManager
            )
        }
        try Data().write(to: locations.adoptionMarker, options: .atomic)
        return locations
    }

    /// Copies the local/legacy private store into exactly one verified account.
    /// A durable base-level claim binds the retained source to the first
    /// adopting account. The unscoped shared store is never adopted
    /// automatically because its ownership cannot be proven.
    static func adoptUnscopedStoresIfNeeded(
        baseDirectory: URL,
        fingerprint: String,
        fileManager: FileManager = .default
    ) throws {
        let locations = locations(baseDirectory: baseDirectory, fingerprint: fingerprint)
        guard !fileManager.fileExists(atPath: locations.adoptionMarker.path) else { return }

        try fileManager.createDirectory(
            at: locations.directory,
            withIntermediateDirectories: true
        )

        let localPrivate = localLocations(baseDirectory: baseDirectory).privateStore
        let legacyPrivate = baseDirectory.appendingPathComponent("private.sqlite")
        let privateSource = fileManager.fileExists(atPath: localPrivate.path)
            ? localPrivate
            : legacyPrivate

        if fileManager.fileExists(atPath: privateSource.path) {
            let claim = try claimLegacyPrivateAdoption(
                baseDirectory: baseDirectory,
                fingerprint: fingerprint,
                fileManager: fileManager
            )
            if claim.accountFingerprint == fingerprint {
                let intentURL = locations.directory.appendingPathComponent(adoptionIntentName)
                let completionMarker = adoptionCompletionMarker(for: locations.privateStore)
                if fileManager.fileExists(atPath: locations.privateStore.path),
                   !fileManager.fileExists(atPath: completionMarker.path),
                   !fileManager.fileExists(atPath: intentURL.path) {
                    // This destination predates our copy intent and may contain
                    // account data. Never classify it as an interrupted copy.
                    throw CocoaError(.fileWriteFileExists)
                }
                if !fileManager.fileExists(atPath: intentURL.path) {
                    try Data().write(to: intentURL, options: .atomic)
                }
                try adoptSQLiteFamily(
                    from: privateSource,
                    to: locations.privateStore,
                    repairingInterruptedCopy: true,
                    fileManager: fileManager
                )
                guard fileManager.fileExists(atPath: locations.privateStore.path),
                      fileManager.fileExists(
                        atPath: adoptionCompletionMarker(for: locations.privateStore).path
                      ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try? fileManager.removeItem(at: intentURL)
            }
        }

        try Data().write(to: locations.adoptionMarker, options: .atomic)
    }

    static func sqliteFamily(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
    }

    private static func adoptSQLiteFamily(
        from source: URL,
        to destination: URL,
        repairingInterruptedCopy: Bool = false,
        fileManager: FileManager
    ) throws {
        let completionMarker = adoptionCompletionMarker(for: destination)
        if fileManager.fileExists(atPath: destination.path) {
            guard fileManager.fileExists(atPath: completionMarker.path) else {
                guard repairingInterruptedCopy else {
                    throw CocoaError(.fileWriteFileExists)
                }
                // The base claim proves this destination belongs to the one
                // adoption attempt. The retained source is authoritative until
                // the completion marker is durable, so a partial promotion is
                // safe to discard and retry.
                for member in sqliteFamily(for: destination) {
                    if fileManager.fileExists(atPath: member.path) {
                        try fileManager.removeItem(at: member)
                    }
                }
                return try adoptSQLiteFamily(
                    from: source,
                    to: destination,
                    repairingInterruptedCopy: false,
                    fileManager: fileManager
                )
            }
            return
        }

        let stagingDirectory = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".adoption-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let sourceFamily = sqliteFamily(for: source)
        let destinationFamily = sqliteFamily(for: destination)
        guard destinationFamily.allSatisfy({
            !fileManager.fileExists(atPath: $0.path)
        }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        for (index, sourceMember) in sourceFamily.enumerated()
        where fileManager.fileExists(atPath: sourceMember.path) {
            let staged = stagingDirectory.appendingPathComponent(destinationFamily[index].lastPathComponent)
            try fileManager.copyItem(at: sourceMember, to: staged)
        }

        var promoted: [URL] = []
        do {
            for destinationMember in destinationFamily {
                let staged = stagingDirectory.appendingPathComponent(destinationMember.lastPathComponent)
                if fileManager.fileExists(atPath: staged.path) {
                    try fileManager.moveItem(at: staged, to: destinationMember)
                    promoted.append(destinationMember)
                }
            }
            try Data().write(to: completionMarker, options: .atomic)
        } catch {
            for member in promoted {
                try? fileManager.removeItem(at: member)
            }
            throw error
        }
    }

    private static func adoptionCompletionMarker(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + ".adopted-v1")
    }

    private static func claimLegacyPrivateAdoption(
        baseDirectory: URL,
        fingerprint: String,
        fileManager: FileManager
    ) throws -> LegacyPrivateAdoptionClaim {
        let claimURL = baseDirectory.appendingPathComponent(baseAdoptionClaimName)
        if fileManager.fileExists(atPath: claimURL.path) {
            return try readAdoptionClaim(at: claimURL)
        }

        let claim = LegacyPrivateAdoptionClaim(version: 1, accountFingerprint: fingerprint)
        let data = try JSONEncoder().encode(claim)
        let stagedClaim = baseDirectory.appendingPathComponent(
            ".legacy-private-claim-\(UUID().uuidString)"
        )
        try data.write(to: stagedClaim, options: .atomic)
        defer { try? fileManager.removeItem(at: stagedClaim) }
        do {
            // A hard link publishes the complete staged bytes in one
            // no-overwrite filesystem operation.
            try fileManager.linkItem(at: stagedClaim, to: claimURL)
            return claim
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return try readAdoptionClaim(at: claimURL)
        }
    }

    private static func readAdoptionClaim(at url: URL) throws -> LegacyPrivateAdoptionClaim {
        let claim = try JSONDecoder().decode(
            LegacyPrivateAdoptionClaim.self,
            from: Data(contentsOf: url)
        )
        guard claim.version == 1, !claim.accountFingerprint.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return claim
    }
}
