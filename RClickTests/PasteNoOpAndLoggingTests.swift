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

extension PasteActionServiceTests {
    nonisolated final class MoveLogCapture: Sendable {
        let entries = Mutex<[(MoveLogEvent, String)]>([])
        func append(_ event: MoveLogEvent, _ message: String) { entries.withLock { $0.append((event, message)) } }
        func clear() { entries.withLock { $0 = [] } }
        var events: [MoveLogEvent] { entries.withLock { $0.map { $0.0 } } }
        var messages: [String] { entries.withLock { $0.map { $0.1 } } }
    }
    nonisolated struct UnwritableMoveJournal: UndoJournalStore {
        let journal: MoveJournal
        func load() -> MoveJournal? { journal }
        func save(_ journal: MoveJournal) throws { throw CocoaError(.fileWriteNoPermission) }
    }
    func attachMoveLog(_ f: Fixture) -> MoveLogCapture {
        let capture = MoveLogCapture()
        let clock = f.clock
        f.service = ActionService(state: State(), permission: f.permission, confirmation: Confirmation(),
            fileOperations: f.operations, pasteboard: f.board, now: { clock.now() }, accessLeaser: f.leaser,
            journalStore: f.storeOverride ?? f.journal, cutPasteboard: f.cutBoard, terminationBoundary: f.termination,
            coordinationTimeout: f.coordinationTimeout, moveLogSink: { event, message in capture.append(event, message) },
            cutWarning: { [weak f] in f?.warnings.append($0) })
        return capture
    }

    @Test(arguments: ["moved", "refused", "partial", "mixed-noop", "timeout", "journal", "destination-changed", "skipped-recovery", "ambiguous-recovery", "expired-recovery", "failed-recovery", "recovery-write", "no-op"])
    func moveOutcomeLogsAreOncePerKindAndContainOnlyCountsAndEnums(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let privateName = "PRIVATE-client-personal-record.txt"
        let source = try f.file(privateName)
        let other = try f.file("PRIVATE-other-person.txt")
        let staying = f.destination.appendingPathComponent("PRIVATE-stay.txt")
        try Data("stay".utf8).write(to: staying)
        let historicRoot = f.root.appendingPathComponent("PRIVATE-history")
        let historicSource = historicRoot.appendingPathComponent("PRIVATE-original.txt")
        let historicDestination = historicRoot.appendingPathComponent("PRIVATE-moved.txt")
        let journalPath = f.root.appendingPathComponent("PRIVATE-journal.json")
        var expiredJournal: MoveJournal?
        if ["skipped-recovery", "ambiguous-recovery", "expired-recovery", "recovery-write"].contains(kind) {
            try FileManager.default.createDirectory(at: historicRoot, withIntermediateDirectories: true)
            try Data("history".utf8).write(to: historicSource)
            let entry = MoveJournalEntry(originalPath: historicSource.path, movedToPath: historicDestination.path,
                identity: try f.operations.stableMoveIdentity(of: historicSource), timestamp: f.clock.now().addingTimeInterval(kind == "expired-recovery" ? -86400 : 0), outcome: .intended)
            let journal = MoveJournal(entries: [entry], inProgress: true)
            if kind == "recovery-write" { f.storeOverride = UnwritableMoveJournal(journal: journal) }
            else if kind == "expired-recovery" { expiredJournal = journal }
            else { try f.journal.save(journal) }
            if kind == "skipped-recovery" || kind == "expired-recovery" { f.permission.allowedPaths = [f.source.path, f.destination.path] }
            if kind == "ambiguous-recovery" {
                try FileManager.default.moveItem(at: historicSource, to: historicSource.appendingPathExtension("old"))
                try Data("replacement".utf8).write(to: historicSource)
                try Data("occupied".utf8).write(to: historicDestination)
            }
        }
        if kind == "failed-recovery" { f.storeOverride = AtomicUndoJournalStore(url: journalPath) }
        let capture = attachMoveLog(f)
        await f.cut(kind == "partial" ? [source, other] : (kind == "mixed-noop" ? [source, staying] : [source]))
        capture.clear() // Startup recovery is a separate attempt; observe this Paste.
        if let expiredJournal { try f.journal.save(expiredJournal) }
        if kind == "refused" { f.operations.refuseDestination(f.destination, reason: .systemRoot) }
        if kind == "partial" { f.operations.failRename(other, with: .ENOTSUP) }
        if kind == "timeout" { f.operations.onNextCoordination { _ in throw PasteMoveError.timeout } }
        if kind == "journal" { f.journal.failOutcomes.withLock { $0 = true } }
        if kind == "failed-recovery" { try Data("truncated".utf8).write(to: journalPath) }
        if kind == "destination-changed" {
            let operations = f.operations, destination = f.destination
            operations.onNextCoordination { _ in operations.setMoveFacts(MoveFacts(directory: true, package: true), for: destination) }
        }
        await f.paste(kind == "no-op" ? f.source : nil)
        let events = capture.events
        let expected: Set<MoveLogEvent.Kind>
        switch kind {
        case "refused": expected = [.moved, .refused]
        case "partial": expected = [.moved, .partial, .refused]
        case "mixed-noop": expected = [.moved, .partial]
        case "timeout": expected = [.moved, .refused, .coordinationTimeout]
        case "journal": expected = [.moved, .journalFailure]
        case "destination-changed": expected = [.moved, .refused, .destinationChanged]
        case "skipped-recovery", "ambiguous-recovery": expected = [.moved, .recoverySkipped]
        case "failed-recovery": expected = [.moved, .recoveryFailed]
        case "expired-recovery": expected = [.moved, .recoveryExpired]
        case "recovery-write": expected = [.moved, .refused, .recoveryFailed, .journalFailure]
        case "no-op": expected = []
        default: expected = [.moved]
        }
        #expect(Set(events.map(\.kind)) == expected)
        for expectedKind in expected { #expect(events.filter { $0.kind == expectedKind }.count == 1) }
        if let summary = events.first(where: { $0.kind == .moved }) {
            let refused = ["refused", "timeout", "destination-changed", "recovery-write"].contains(kind)
            #expect(summary.moved == (refused ? 0 : 1))
            #expect(summary.total == (["partial", "mixed-noop"].contains(kind) ? 2 : 1))
        }
        let reason: MoveLogEvent.Reason?
        switch kind {
        case "refused": reason = .systemRoot
        case "partial": reason = .unsupported
        case "timeout": reason = .timeout
        case "destination-changed": reason = .destinationChanged
        case "journal", "recovery-write": reason = .journalWrite
        case "skipped-recovery": reason = .missingAccess
        case "ambiguous-recovery": reason = .ambiguous
        case "failed-recovery": reason = .journalDiscarded
        case "expired-recovery": reason = .expired
        default: reason = nil
        }
        if let reason { #expect(events.contains { $0.reasons.contains(reason) }) }
        let forbidden = [f.root.path, f.source.path, f.destination.path, source.path, source.lastPathComponent,
                         other.lastPathComponent, staying.lastPathComponent, historicRoot.lastPathComponent, historicSource.lastPathComponent,
                         historicDestination.lastPathComponent, journalPath.lastPathComponent]
        #expect(capture.messages.allSatisfy { message in forbidden.allSatisfy { !message.contains($0) } })
        #expect(f.leaser.balance == 0)
    }
}
