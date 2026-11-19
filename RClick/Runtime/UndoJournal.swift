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
    nonisolated func stableMoveIdentity(of url: URL) throws -> StableMoveIdentity {
        let identity = try fileIdentity(of: url)
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let uuid = values.volumeUUIDString, let birth = attributes[.creationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return StableMoveIdentity(volumeUUID: uuid, inode: identity.fileNumber, creationDate: birth)
    }
}
