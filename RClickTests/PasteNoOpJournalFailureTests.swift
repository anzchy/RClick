import AppKit
import Synchronization
import Testing
@testable import RClick

extension PasteActionServiceTests {
    nonisolated struct UnreadableNoOpJournal: UndoJournalStore {
        func load() throws -> MoveJournal? { throw CocoaError(.fileReadUnknown) }
        func save(_ journal: MoveJournal) throws { throw CocoaError(.fileWriteNoPermission) }
    }
    @Test(arguments: ["initial-journal", "outcome-journal", "destination-refusal"])
    func mixedNoOpsAreNeverReportedAsFailedItems(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let staying = f.destination.appendingPathComponent("already-here.txt")
        try Data("stay".utf8).write(to: staying)
        let incoming = try f.file("incoming.txt")
        if kind == "initial-journal" { f.storeOverride = UnreadableNoOpJournal() }
        await f.cut([staying, incoming])
        if kind == "outcome-journal" { f.journal.failOutcomes.withLock { $0 = true } }
        if kind == "destination-refusal" { f.operations.refuseDestination(f.destination, reason: .trash) }
        await f.paste()
        #expect(!f.warnings.joined(separator: "\n").contains(staying.lastPathComponent))
        #expect(f.service.pendingCut?.paths.contains(staying.path) == true)
        #expect(try Data(contentsOf: staying) == Data("stay".utf8))
        #expect(!f.operations.renameCalls.contains(staying.path))
        #expect(f.leaser.balance == 0)
    }
}
