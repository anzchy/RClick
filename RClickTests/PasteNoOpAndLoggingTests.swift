import AppKit
import Synchronization
import Testing
@testable import RClick

extension PasteActionServiceTests {
    @Test func sameFolderPasteDoesNotRewriteAnExistingJournal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try f.file()
        await f.cut([source])
        let previous = MoveJournalEntry(originalPath: source.path, movedToPath: source.path,
            identity: try f.operations.stableMoveIdentity(of: source), timestamp: f.clock.now(), outcome: .moved)
        try f.journal.save(MoveJournal(entries: [previous]))
        let writes = f.journal.history.withLock { $0.count }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(f.journal.load())
        let count = f.board.changeCount
        await f.paste(f.source)
        #expect(f.journal.history.withLock { $0.count } == writes)
        #expect(try encoder.encode(f.journal.load()) == bytes)
        #expect(f.board.changeCount == count)
        #expect(f.service.pendingCut?.paths == [source.path])
        #expect(f.warnings.isEmpty)
    }

    @Test(arguments: [false, true])
    func mixedNoOpsRemainPendingAlongsideFailures(includeMissing: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let staying = f.destination.appendingPathComponent("stays.txt")
        try Data("stay".utf8).write(to: staying)
        let incoming = try f.file("incoming.txt")
        let missing = try f.file("missing.txt")
        let selection = includeMissing ? [staying, incoming, missing] : [staying, incoming]
        await f.cut(selection)
        let originalCount = f.board.changeCount
        if includeMissing { try FileManager.default.removeItem(at: missing) }
        let updates = Counter()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: f.service, queue: nil) { _ in
            updates.value.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await f.paste()
        let remaining = includeMissing ? [staying, missing] : [staying]
        #expect(f.service.pendingCut?.paths == remaining.map(\.path))
        #expect(f.board.changeCount != originalCount)
        #expect(f.service.pendingCut?.changeCount == f.board.changeCount)
        #expect(f.board.pasteboardItems?.compactMap { $0.string(forType: .fileURL) } == remaining.map(\.absoluteString))
        #expect(PendingCut(pasteboard: f.board).isStillPending(f.board.changeCount))
        #expect(try Data(contentsOf: staying) == Data("stay".utf8))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("incoming.txt")) == Data("original".utf8))
        #expect(f.journal.load()?.entries.map(\.originalPath) == [incoming.path])
        #expect(f.warnings.count == (includeMissing ? 1 : 0))
        #expect(updates.value.withLock { $0 } == 1)
        #expect(f.leaser.balance == 0)
    }
}
