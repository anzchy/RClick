import Foundation
import Darwin

nonisolated struct StableMoveIdentity: Codable, Equatable, Sendable {
    let volumeUUID: String
    let inode: UInt64
    // Additional evidence against inode reuse; an ambiguous replacement is never eligible.
    let creationDate: Date
}

nonisolated struct MoveJournalEntry: Codable, Sendable {
    enum Outcome: String, Codable { case intended, moved, failed }
    let originalPath: String
    let movedToPath: String
    let identity: StableMoveIdentity
    let timestamp: Date
    var outcome: Outcome
    // Optional so version-1 journals written by older builds still decode.
    var originalParentIdentity: StableMoveIdentity? = nil
}

nonisolated struct MoveJournal: Codable, Sendable {
    let version: Int
    var previous: [MoveJournalEntry]
    var entries: [MoveJournalEntry]
    var inProgress: Bool
    // Separate from the last Paste's undo record. Retain unresolved older work
    // (and subsequently recovered moves) until its original 24-hour expiry.
    var deferred: [MoveJournalEntry]?
    init(previous: [MoveJournalEntry] = [], entries: [MoveJournalEntry] = [], inProgress: Bool = false) {
        version = 1; self.previous = previous; self.entries = entries; self.inProgress = inProgress
    }
}

nonisolated protocol UndoJournalStore: Sendable {
    func load() throws -> MoveJournal?
    func save(_ journal: MoveJournal) throws
}

nonisolated enum JournalFailure: Error {
    case discarded, unreadable, writeFailed
}

extension UndoJournalStore {
    nonisolated func persist(_ journal: MoveJournal) throws {
        do { try save(journal) }
        catch { throw JournalFailure.writeFailed }
    }
}

nonisolated struct JournalRecoveryReport: Sendable {
    var missingAccess = 0
    var ambiguous = 0
    var unreadable = 0
    var pruned = 0
}

import Darwin

/// A private temp file is flushed, then atomically renamed over the journal.
/// The containing directory is flushed as well. Paths in this file grant no access.
nonisolated struct AtomicUndoJournalStore: UndoJournalStore {
    let url: URL
    static func appGroup() throws -> Self {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedAppGroup.identifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Self(url: root.appendingPathComponent("paste-journal.json"))
    }
    func load() throws -> MoveJournal? {
        do {
            let journal = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: url))
            guard journal.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            return journal
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch {
            // Rename does not require reading the damaged file. Keep exactly one
            // quarantined predecessor, including for unknown schema versions.
            let quarantine = url.appendingPathExtension("unrecoverable")
            let result = url.withUnsafeFileSystemRepresentation { from in
                quarantine.withUnsafeFileSystemRepresentation { to in rename(from, to) }
            }
            guard result == 0 else { throw JournalFailure.unreadable }
            throw JournalFailure.discarded
        }
    }
    func save(_ journal: MoveJournal) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".paste-journal-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(journal).write(to: temporary, options: [.withoutOverwriting])
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        let renamed = temporary.withUnsafeFileSystemRepresentation { from in
            url.withUnsafeFileSystemRepresentation { to in rename(from, to) }
        }
        guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}

extension FileOperations {
    nonisolated func volumeUUID(of url: URL) throws -> String {
        guard let value = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw CocoaError(.fileReadUnknown)
        }
        return value
    }
    nonisolated func stableMoveIdentity(of url: URL) throws -> StableMoveIdentity {
        let identity = try fileIdentity(of: url)
        let uuid = try volumeUUID(of: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let birth = attributes[.creationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return StableMoveIdentity(volumeUUID: uuid, inode: identity.fileNumber, creationDate: birth)
    }
}

extension MoveJournal {
    /// Recovery never moves files. An interrupted intent becomes eligible only
    /// when the destination is the recorded object and the original is absent.
    @discardableResult
    nonisolated mutating func reconcile(using operations: any FileOperations, at now: Date,
        accessibleDirectories: Set<String>? = nil) throws -> JournalRecoveryReport {
        var report = JournalRecoveryReport()
        let before = entries.count + previous.count + (deferred?.count ?? 0)
        func expired(_ entry: MoveJournalEntry) -> Bool {
            now.timeIntervalSince(entry.timestamp) >= 86400 || entry.timestamp > now
        }
        entries.removeAll(where: expired)
        previous.removeAll(where: expired)
        var retained = deferred ?? []
        retained.removeAll(where: expired)
        report.pruned = before - entries.count - previous.count - retained.count
        func recover(_ entry: inout MoveJournalEntry) {
            guard entry.outcome == .intended else { return }
            let source = URL(fileURLWithPath: entry.originalPath)
            let destination = URL(fileURLWithPath: entry.movedToPath)
            if let accessibleDirectories,
               ![source, destination].allSatisfy({ accessibleDirectories.contains($0.deletingLastPathComponent().path) }) {
                report.missingAccess += 1
                return
            }
            do {
                let original = try operations.stableIdentityIfPresent(source)
                let moved = try operations.stableIdentityIfPresent(destination)
                if original == nil && moved == entry.identity { entry.outcome = .moved }
                else if original == entry.identity && moved == nil { entry.outcome = .failed }
                else { report.ambiguous += 1 }
            } catch { report.unreadable += 1 }
        }
        for index in retained.indices { recover(&retained[index]) }
        retained.removeAll { $0.outcome == .failed }
        if inProgress {
            for index in entries.indices { recover(&entries[index]) }
            retained += entries.filter { $0.outcome == .intended }
            let moved = entries.filter { $0.outcome == .moved }
            entries = moved.isEmpty ? previous : moved
            previous = []
            inProgress = false
        }
        deferred = retained.isEmpty ? nil : retained
        return report
    }
}

extension FileOperations {
    nonisolated func stableIdentityIfPresent(_ url: URL) throws -> StableMoveIdentity? {
        do { return try stableMoveIdentity(of: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
}

nonisolated enum UndoMoveError: Error { case changed, originalFolder, originalFolderReplaced }

extension MoveJournal {
    nonisolated func undoEntries(at now: Date) -> [MoveJournalEntry] {
        guard !inProgress else { return [] }
        return entries.filter { $0.outcome == .moved && $0.timestamp <= now && now.timeIntervalSince($0.timestamp) < 86400 }
    }
}


extension FileOperations {
    /// Check the lexical parent without following a final symlink, then pin the
    /// resulting identity through the existing descriptor-based move engine.
    nonisolated func originalUndoDirectory(_ url: URL, expected: StableMoveIdentity?) throws -> (URL, FileIdentity) {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard status == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw UndoMoveError.originalFolderReplaced
        }
        let identity = FileIdentity(volume: VolumeIdentity(rawValue: NSNumber(value: info.st_dev).uint64Value), fileNumber: info.st_ino)
        let observed = try stableMoveIdentity(of: url)
        guard expected == nil || observed == expected else { throw UndoMoveError.originalFolderReplaced }
        let canonical = try url.canonicalMoveDirectory().standardizedFileURL
        guard try fileIdentity(of: canonical) == identity,
              try stableMoveIdentity(of: canonical) == observed else { throw UndoMoveError.originalFolderReplaced }
        return (canonical, identity)
    }
}
