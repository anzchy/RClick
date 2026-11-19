import Foundation

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
}

nonisolated struct MoveJournal: Codable, Sendable {
    let version: Int
    var previous: [MoveJournalEntry]
    var entries: [MoveJournalEntry]
    var inProgress: Bool
    init(previous: [MoveJournalEntry] = [], entries: [MoveJournalEntry] = [], inProgress: Bool = false) {
        version = 1; self.previous = previous; self.entries = entries; self.inProgress = inProgress
    }
}

nonisolated protocol UndoJournalStore: Sendable {
    func load() throws -> MoveJournal?
    func save(_ journal: MoveJournal) throws
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
    nonisolated mutating func reconcile(using operations: any FileOperations, at now: Date) throws {
        entries.removeAll { now.timeIntervalSince($0.timestamp) >= 86400 || $0.timestamp > now }
        previous.removeAll { now.timeIntervalSince($0.timestamp) >= 86400 || $0.timestamp > now }
        if inProgress {
            for index in entries.indices where entries[index].outcome == .intended {
                let entry = entries[index]
                let source = try operations.stableIdentityIfPresent(URL(fileURLWithPath: entry.originalPath))
                let destination = try operations.stableIdentityIfPresent(URL(fileURLWithPath: entry.movedToPath))
                if source == nil && destination == entry.identity { entries[index].outcome = .moved }
                else if source == entry.identity || destination == nil { entries[index].outcome = .failed }
                // Both locations occupied, a replacement, or an inode reuse is
                // ambiguous. Preserve the intent and refuse a new Paste.
            }
            guard !entries.contains(where: { $0.outcome == .intended }) else { return }
            let moved = entries.filter { $0.outcome == .moved }
            entries = moved.isEmpty ? previous : moved
            previous = []
            inProgress = false
        }
    }
}

extension FileOperations {
    nonisolated func stableIdentityIfPresent(_ url: URL) throws -> StableMoveIdentity? {
        do { return try stableMoveIdentity(of: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
}
