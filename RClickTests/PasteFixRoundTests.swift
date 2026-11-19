import AppKit
import Testing
@testable import RClick

extension PasteActionServiceTests {
    @Test(arguments: ["desktop-subfolder", "outside", "other-provider", "unknown-root"])
    func ubiquitousMovesRespectDestinationSyncState(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let root = f.source
        let destination = kind == "desktop-subfolder" ? root.appendingPathComponent("subfolder") : f.destination
        if kind == "desktop-subfolder" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        f.operations.setMoveFacts(MoveFacts(ubiquitous: true, providerContainer: kind == "other-provider" ? root : nil), for: item)
        f.operations.setMoveFacts(MoveFacts(directory: true, ubiquitous: kind != "outside", providerContainer: kind == "other-provider" ? destination : nil), for: destination)
        await f.cut([item]); await f.paste(destination)
        let allowed = kind == "desktop-subfolder" || kind == "unknown-root"
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(item.lastPathComponent).path) == allowed)
        #expect(f.operations.renameCalls.count == (allowed ? 1 : 0))
        #expect(f.warnings.isEmpty == allowed)
    }
}

extension PasteActionServiceTests {
    @Test(arguments: ["corrupt", "version", "unreadable"])
    func damagedJournalIsQuarantinedAndPasteWorks(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let path = f.root.appendingPathComponent("paste-journal.json")
        let data = kind == "version" ? Data("{\"version\":99,\"entries\":[],\"previous\":[],\"inProgress\":false}".utf8) : Data("broken".utf8)
        try data.write(to: path)
        if kind == "unreadable" { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path) }
        f.storeOverride = AtomicUndoJournalStore(url: path)
        let first = try f.file()
        await f.cut([first]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: path.path + ".unrecoverable"))
        #expect(f.warnings.count == 1)
        #expect(f.warnings.first == "A previous move could not be fully recovered; its undo information was discarded")
        let second = try f.file("second.txt")
        await f.cut([second]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("second.txt").path))
        #expect(f.warnings.count == 1)
    }

    @Test(arguments: ["missing-access", "ambiguous", "expired-without-access"])
    func interruptedJournalDoesNotBlockNewPasteOrLoseUnexpiredIntents(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let oldRoot = f.root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let old = oldRoot.appendingPathComponent("old.txt")
        let oldDestination = oldRoot.appendingPathComponent("moved.txt")
        try Data("old".utf8).write(to: old)
        let identity = try f.operations.stableMoveIdentity(of: old)
        // Source replaced and destination occupied: neither may be touched by recovery.
        try FileManager.default.moveItem(at: old, to: oldRoot.appendingPathComponent("saved.txt"))
        try Data("replacement".utf8).write(to: old)
        try Data("occupied".utf8).write(to: oldDestination)
        let expired = kind == "expired-without-access"
        let timestamp = f.clock.now().addingTimeInterval(expired ? -86400 : 0)
        try f.journal.save(MoveJournal(entries: [MoveJournalEntry(originalPath: old.path, movedToPath: oldDestination.path, identity: identity, timestamp: timestamp, outcome: .intended)], inProgress: true))
        if kind != "ambiguous" { f.permission.allowedPaths = [f.source.path, f.destination.path] }
        let item = try f.file()
        await f.cut([item])
        if expired { #expect(f.journal.load()?.entries.isEmpty == true) }
        await f.paste()
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        #expect(try Data(contentsOf: old) == Data("replacement".utf8))
        #expect(try Data(contentsOf: oldDestination) == Data("occupied".utf8))
        let saved = try #require(f.journal.load())
        let json = try #require(String(data: JSONEncoder().encode(saved), encoding: .utf8))
        #expect(json.replacingOccurrences(of: "\\/", with: "/").contains(old.path) == !expired)
        #expect(!saved.inProgress)
        #expect(f.warnings.isEmpty == expired)
        if !expired {
            #expect(f.warnings.first?.contains(kind == "missing-access" ? "folder access is missing" : "locations are ambiguous") == true)
        }
        let next = try f.file("next.txt")
        await f.cut([next]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("next.txt").path))
        let afterNext = try #require(f.journal.load())
        #expect(try String(data: JSONEncoder().encode(afterNext), encoding: .utf8)?.replacingOccurrences(of: "\\/", with: "/").contains(old.path) == !expired)
        #expect(f.leaser.balance == 0)
    }
}

extension PasteActionServiceTests {
    @Test func inaccessibleIntentIsRetainedAndRecoveredAfterAccessReturns() async throws {
        let f = try Fixture(); defer { f.clean() }
        let historic = f.root.appendingPathComponent("historic")
        try FileManager.default.createDirectory(at: historic, withIntermediateDirectories: true)
        let old = historic.appendingPathComponent("old.txt")
        let moved = historic.appendingPathComponent("moved.txt")
        try Data("historic".utf8).write(to: old)
        let identity = try f.operations.stableMoveIdentity(of: old)
        try f.journal.save(MoveJournal(entries: [MoveJournalEntry(originalPath: old.path, movedToPath: moved.path, identity: identity, timestamp: f.clock.now(), outcome: .intended)], inProgress: true))
        try FileManager.default.moveItem(at: old, to: moved)
        f.permission.allowedPaths = [f.source.path, f.destination.path]
        let first = try f.file()
        await f.cut([first]); await f.paste()
        #expect(f.journal.load()?.deferred?.first?.outcome == .intended)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        f.permission.allowedPaths = nil
        let second = try f.file("second.txt")
        await f.cut([second]); await f.paste()
        #expect(f.journal.load()?.deferred?.first?.outcome == .moved)
        #expect(f.journal.load()?.deferred?.first?.identity == identity)
        #expect(try Data(contentsOf: moved) == Data("historic".utf8))
        #expect(f.leaser.balance == 0)
    }
}
