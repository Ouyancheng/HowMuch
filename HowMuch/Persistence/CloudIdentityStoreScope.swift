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
    static let inodeRewriteMarkerSuffix = ".inodes-rewritten-v1"

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
        let legacyPrivate = baseDirectory.appendingPathComponent("private.sqlite")
        if fileManager.fileExists(atPath: locations.adoptionMarker.path) {
            try finishStoreLocation(
                source: fileManager.fileExists(atPath: legacyPrivate.path) ? legacyPrivate : nil,
                destination: locations.privateStore,
                baseDirectory: baseDirectory,
                fileManager: fileManager
            )
            return locations
        }
        try fileManager.createDirectory(at: locations.directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: legacyPrivate.path) {
            try adoptSQLiteFamily(
                from: legacyPrivate,
                to: locations.privateStore,
                fileManager: fileManager
            )
        }
        try Data().write(to: locations.adoptionMarker, options: atomicWriteOptions)
        try finishStoreLocation(
            source: fileManager.fileExists(atPath: legacyPrivate.path) ? legacyPrivate : nil,
            destination: locations.privateStore,
            baseDirectory: baseDirectory,
            fileManager: fileManager
        )
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
        let localPrivate = localLocations(baseDirectory: baseDirectory).privateStore
        let legacyPrivate = baseDirectory.appendingPathComponent("private.sqlite")
        let privateSource = fileManager.fileExists(atPath: localPrivate.path)
            ? localPrivate
            : legacyPrivate
        if fileManager.fileExists(atPath: locations.adoptionMarker.path) {
            try finishStoreLocation(
                source: fileManager.fileExists(atPath: privateSource.path) ? privateSource : nil,
                destination: locations.privateStore,
                baseDirectory: baseDirectory,
                fileManager: fileManager
            )
            return
        }

        try fileManager.createDirectory(
            at: locations.directory,
            withIntermediateDirectories: true
        )

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
                    try Data().write(to: intentURL, options: atomicWriteOptions)
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

        try Data().write(to: locations.adoptionMarker, options: atomicWriteOptions)
        try finishStoreLocation(
            source: fileManager.fileExists(atPath: privateSource.path) ? privateSource : nil,
            destination: locations.privateStore,
            baseDirectory: baseDirectory,
            fileManager: fileManager
        )
    }

    /// Core Data and SQLite sidecar writes fail with NSCocoaErrorDomain 513
    /// on both iOS and macOS when a copied store, WAL, `_SUPPORT` tree, or
    /// Core Data default directory is not writable.
    static func ensureWritableDirectory(
        _ directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? makeWritable(directoryURL, directory: true, fileManager: fileManager)
    }

    static func ensureWritableStoreLocation(
        _ storeURL: URL,
        fileManager: FileManager = .default,
        allowRewrite: Bool = true
    ) throws {
        let store = storeURL.standardizedFileURL
        let directory = store.deletingLastPathComponent()
        try ensureWritableDirectory(directory, fileManager: fileManager)

        let support = supportDirectory(for: store)
        let externalData = support.appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try fileManager.createDirectory(at: externalData, withIntermediateDirectories: true)
        try? makeWritableTree(at: support, fileManager: fileManager)

        let family = sqliteFamily(for: store).filter { fileManager.fileExists(atPath: $0.path) }
        for member in family {
            try? makeWritable(member, directory: false, fileManager: fileManager)
        }
        let rewriteMarker = URL(fileURLWithPath: store.path + inodeRewriteMarkerSuffix)
        let alreadyRewritten = fileManager.fileExists(atPath: rewriteMarker.path)
        // Unconditional rewrite uses Data.write. On iOS that can apply
        // complete file protection and later saves fail with 513.
        let mustRewrite = family.contains(where: { !canOpenForUpdating($0) })
        #if os(iOS)
        let shouldRewrite = allowRewrite && mustRewrite
        #else
        let shouldRewrite = allowRewrite && (!alreadyRewritten || mustRewrite)
        #endif
        if shouldRewrite {
            for member in family {
                try recreateFileWithoutInheritedMetadata(member, fileManager: fileManager)
            }
            try? recreateRestrictedFiles(in: support, fileManager: fileManager, force: true)
            try Data().write(to: rewriteMarker, options: atomicWriteOptions)
        } else if allowRewrite {
            try? recreateRestrictedFiles(in: support, fileManager: fileManager, force: false)
            if !alreadyRewritten {
                try Data().write(to: rewriteMarker, options: atomicWriteOptions)
            }
        }
    }

    static func supportDirectory(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + "_SUPPORT", isDirectory: true)
    }

    private static func finishStoreLocation(
        source: URL?,
        destination: URL,
        baseDirectory: URL,
        fileManager: FileManager
    ) throws {
        if let source, fileManager.fileExists(atPath: source.path) {
            try adoptSupportDirectory(from: source, to: destination, fileManager: fileManager)
        }
        try repairExternalBinaryStorage(
            for: destination,
            baseDirectory: baseDirectory,
            fileManager: fileManager
        )
        try ensureWritableStoreLocation(destination, fileManager: fileManager)
    }

    /// Receipts use `allowsExternalBinaryDataStorage`. The UUID lives in sqlite;
    /// the bytes live in `*_SUPPORT/_EXTERNAL_DATA`. A store copy that misses
    /// `.private_SUPPORT` or `private.sqlite_SUPPORT` makes later saves fail
    /// with NSCocoaErrorDomain 513.
    static func repairExternalBinaryStorage(
        for storeURL: URL,
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let destinationExternal = supportDirectory(for: storeURL)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try fileManager.createDirectory(at: destinationExternal, withIntermediateDirectories: true)

        let candidates = [
            supportDirectory(for: storeURL),
            supportDirectory(for: baseDirectory.appendingPathComponent("private.sqlite")),
            supportDirectory(for: localLocations(baseDirectory: baseDirectory).privateStore),
            baseDirectory.appendingPathComponent(".private_SUPPORT", isDirectory: true),
            storeURL.deletingLastPathComponent()
                .appendingPathComponent(".private_SUPPORT", isDirectory: true)
        ]
        var seen = Set<String>()
        for support in candidates {
            let path = support.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let sourceExternal = support.appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            guard fileManager.fileExists(atPath: sourceExternal.path) else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: sourceExternal,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files {
                let destination = destinationExternal.appendingPathComponent(file.lastPathComponent)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try copyFileReplacingMetadata(from: file, to: destination)
            }
        }
    }

    private static func adoptSupportDirectory(
        from sourceStore: URL,
        to destinationStore: URL,
        fileManager: FileManager
    ) throws {
        let sourceSupport = supportDirectory(for: sourceStore)
        let destinationSupport = supportDirectory(for: destinationStore)
        guard fileManager.fileExists(atPath: sourceSupport.path) else { return }
        if fileManager.fileExists(atPath: destinationSupport.path) {
            if !isEmptySupportDirectory(destinationSupport, fileManager: fileManager) {
                return
            }
            try fileManager.removeItem(at: destinationSupport)
        }
        try copyDirectoryReplacingMetadata(
            from: sourceSupport,
            to: destinationSupport,
            fileManager: fileManager
        )
    }

    private static func copyDirectoryReplacingMetadata(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for child in children {
            let destChild = destination.appendingPathComponent(child.lastPathComponent)
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try copyDirectoryReplacingMetadata(
                    from: child,
                    to: destChild,
                    fileManager: fileManager
                )
            } else {
                try copyFileReplacingMetadata(from: child, to: destChild)
            }
        }
    }

    private static var atomicWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .noFileProtection]
        #else
        [.atomic]
        #endif
    }

    private static func copyFileReplacingMetadata(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        try data.write(to: destination, options: atomicWriteOptions)
    }

    /// `access(W_OK)` ignores sandbox provenance/quarantine. Opening the file
    /// for updating is what Core Data does on save.
    static func canOpenForUpdating(_ url: URL) -> Bool {
        do {
            let handle = try FileHandle(forUpdating: url)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    private static func recreateFileWithoutInheritedMetadata(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.setAttributes([.immutable: false], ofItemAtPath: url.path)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".rewrite-\(UUID().uuidString)")
        try data.write(to: staging, options: atomicWriteOptions)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.removeItem(at: url)
        try fileManager.moveItem(at: staging, to: url)
        try? makeWritable(url, directory: false, fileManager: fileManager)
    }

    private static func recreateRestrictedFiles(
        in directory: URL,
        fileManager: FileManager,
        force: Bool
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for child in children {
            var childIsDirectory: ObjCBool = false
            fileManager.fileExists(atPath: child.path, isDirectory: &childIsDirectory)
            if childIsDirectory.boolValue {
                try recreateRestrictedFiles(in: child, fileManager: fileManager, force: force)
            } else if force || !canOpenForUpdating(child) {
                try recreateFileWithoutInheritedMetadata(child, fileManager: fileManager)
            }
        }
    }

    private static func isEmptySupportDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        let externalData = url.appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: externalData.path)) ?? []
        return contents.isEmpty
    }

    private static func makeWritableTree(at url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        try makeWritable(url, directory: isDirectory.boolValue, fileManager: fileManager)
        guard isDirectory.boolValue else { return }
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        for child in children {
            try? makeWritableTree(at: child, fileManager: fileManager)
        }
    }

    private static func makeWritable(
        _ url: URL,
        directory: Bool,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes(
            [
                .immutable: false,
                .posixPermissions: directory ? 0o755 : 0o644
            ],
            ofItemAtPath: url.path
        )
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
                let destinationSupport = supportDirectory(for: destination)
                if fileManager.fileExists(atPath: destinationSupport.path) {
                    try fileManager.removeItem(at: destinationSupport)
                }
                return try adoptSQLiteFamily(
                    from: source,
                    to: destination,
                    repairingInterruptedCopy: false,
                    fileManager: fileManager
                )
            }
            try adoptSupportDirectory(from: source, to: destination, fileManager: fileManager)
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
            try copyFileReplacingMetadata(from: sourceMember, to: staged)
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
            try Data().write(to: completionMarker, options: atomicWriteOptions)
            try adoptSupportDirectory(from: source, to: destination, fileManager: fileManager)
        } catch {
            for member in promoted {
                try? fileManager.removeItem(at: member)
            }
            let destinationSupport = supportDirectory(for: destination)
            if fileManager.fileExists(atPath: destinationSupport.path) {
                try? fileManager.removeItem(at: destinationSupport)
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
        try data.write(to: stagedClaim, options: atomicWriteOptions)
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
