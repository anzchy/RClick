import AppKit
import Synchronization
import Testing
@testable import RClick

@MainActor
struct PasteActionServiceTests {
    @MainActor final class State: ActionStateProviding {
        var apps: [OpenWithApp] = []
        var newFiles: [NewFile] = []
        var cdirs: [CommonDir] = []
        var showCommonDirs = false
        var actions: [RCAction] = { var cut = RCAction.cut; cut.enabled = true; return [cut] }()
        func getAppItem(rid: String) -> OpenWithApp? { nil }
        func getFileType(rid: String) -> NewFile? { nil }
        func getActionItem(rid: String) -> RCAction? { actions.first { $0.id == rid } }
    }
    @MainActor final class Permission: PermissionProviding {
        var allowed = true
        var hold: CheckedContinuation<URL?, Never>?
        var onPrompt: (() -> Void)?
        func hasAccess(to url: URL) -> Bool { allowed }
        func promptForPermission(for url: URL) async -> URL? {
            if let onPrompt {
                return await withCheckedContinuation { hold = $0; onPrompt() }
            }
            return nil
        }
        func saveBookmark(for url: URL) {}
    }
    @MainActor final class Confirmation: DeleteConfirmationProviding {
        func confirmPermanentDelete(paths: [String]) -> Bool { false }
    }
    nonisolated final class Counter: Sendable { let value = Mutex(0) }
    @MainActor final class Leaser: ScopedAccessLeasing {
        let counter = Counter()
        var balance: Int { counter.value.withLock { $0 } }
        func beginAccess(covering directories: [URL]) -> ScopedAccessLease {
            counter.value.withLock { $0 += 1 }
            let counter = counter
            return ScopedAccessLease(directories: directories) { counter.value.withLock { $0 -= 1 } }
        }
    }
    nonisolated final class JournalStore: UndoJournalStore {
        let value = Mutex<MoveJournal?>(nil)
        let failOutcomes = Mutex(false)
        func load() -> MoveJournal? { value.withLock { $0 } }
        func save(_ journal: MoveJournal) throws {
            if failOutcomes.withLock({ $0 }), journal.entries.contains(where: { $0.outcome == .moved }) {
                throw CocoaError(.fileWriteUnknown)
            }
            value.withLock { $0 = journal }
        }
    }
    @MainActor final class ManualTermination: MoveTerminationBoundary {
        var date = Date(timeIntervalSince1970: 100000)
        var scheduled: [(Date, @MainActor () -> Void)] = []
        var balance = 0
        func protectMutation() { balance += 1 }
        func unprotectMutation() { balance -= 1 }
        func scheduleDeadline(_ date: Date, action: @escaping @MainActor () -> Void) { scheduled.append((date, action)) }
        func advance(by interval: TimeInterval) {
            date.addTimeInterval(interval)
            let ready = scheduled.filter { $0.0 <= date }
            scheduled.removeAll { $0.0 <= date }
            ready.forEach { $0.1() }
        }
    }
    nonisolated final class Clock: Sendable {
        let date = Mutex(Date(timeIntervalSince1970: 100000))
        func now() -> Date { date.withLock { $0 } }
    }
    @MainActor final class FailingCutBoard: CutPasteboard {
        let board: NSPasteboard
        var rejectWrites = false
        init(_ board: NSPasteboard) { self.board = board }
        var changeCount: Int { board.changeCount }
        var types: [NSPasteboard.PasteboardType]? { board.types }
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int { board.prepareForNewContents(with: options) }
        func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool { !rejectWrites && board.writeObjects(objects) }
    }
    @MainActor final class Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let board = NSPasteboard(name: .init("RClickTests-paste-\(UUID())"))
        var coordinationTimeout: TimeInterval = 30
        let termination = ManualTermination()
        let clock = Clock()
        let journal = JournalStore()
        lazy var cutBoard = FailingCutBoard(board)
        let permission = Permission()
        let leaser = Leaser()
        let operations = FaultInjectingFileOperations()
        var warnings: [String] = []
        lazy var service = ActionService(state: State(), permission: permission, confirmation: Confirmation(),
            fileOperations: operations, pasteboard: board, now: { [clock] in clock.now() }, accessLeaser: leaser, journalStore: journal, cutPasteboard: cutBoard, terminationBoundary: termination, coordinationTimeout: coordinationTimeout,
            cutWarning: { [weak self] in self?.warnings.append($0) })
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RClick-paste-\(UUID())").resolvingSymlinksInPath()
            source = root.appendingPathComponent("source")
            destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        func file(_ name: String = "notes.txt") throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data("original".utf8).write(to: url)
            return url
        }
        func cut(_ urls: [URL]) async { await service.actionHandler(rid: "cut", target: urls.map(\.path), trigger: "ctx-items") }
        func paste(_ url: URL? = nil) async {
            await service.actionHandler(rid: "paste-move", target: [(url ?? destination).path], trigger: "ctx-container")
        }
        func clean() { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    }

    @Test func singlePasteMovesFileAndEndsCut() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file])
        await f.paste()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes.txt")) == Data("original".utf8))
        #expect(f.service.pendingCut == nil)
        #expect(f.board.pasteboardItems?.isEmpty != false)
        #expect(f.leaser.balance == 0)
        #expect(f.warnings.isEmpty)
    }
    @Test func clashesRetryWithoutReplacingFilesCreatedAtRename() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        try Data("keep second".utf8).write(to: f.destination.appendingPathComponent("notes 2.txt"))
        f.operations.createClashAtRename(f.destination.appendingPathComponent("notes.txt"))
        await f.cut([file]); await f.paste()
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes.txt")) == Data("racing owner".utf8))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes 2.txt")) == Data("keep second".utf8))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes 3.txt")) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func partialFailureRewritesOnlyFailedItemsAndRefreshesPendingCount() async throws {
        let f = try Fixture(); defer { f.clean() }
        let good = try f.file("good.txt"), missing = try f.file("missing.txt")
        await f.cut([good, missing])
        let old = f.board.changeCount
        try FileManager.default.removeItem(at: missing)
        await f.paste()
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("good.txt")) == Data("original".utf8))
        #expect(f.service.pendingCut?.paths == [missing.path])
        #expect(f.service.pendingCut?.changeCount == f.board.changeCount)
        #expect(f.board.changeCount != old)
        #expect(f.board.pasteboardItems?.count == 1)
        #expect(f.board.pasteboardItems?.first?.string(forType: .fileURL) == missing.absoluteString)
        #expect(f.warnings.count == 1)
        #expect(f.warnings.first?.contains("missing.txt") == true)
        #expect(f.leaser.balance == 0)
    }

    @Test(arguments: ["same-folder", "self", "inside", "cross-volume", "changed", "missing", "system-root", "file-destination", "package", "package-interior", "trash", "trash-child", "cloud", "mount"])
    func refusesUnsafeMovesWithoutRenaming(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        var item = try f.file()
        var destination = f.destination
        if kind == "self" || kind == "inside" {
            item = f.source.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            destination = kind == "self" ? item : item.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        if kind == "same-folder" { destination = f.source }
        if kind == "cross-volume" { f.operations.placeOnOtherVolume(f.destination.path) }
        if kind == "cloud" { f.operations.setMoveFacts(MoveFacts(ubiquitous: true, providerContainer: f.source), for: item) }
        if kind == "mount" { f.operations.setMoveFacts(MoveFacts(directory: true, mountPoint: true), for: item) }
        if kind == "file-destination" { destination = try f.file("destination.txt") }
        if kind == "package" || kind == "package-interior" {
            destination = f.destination.appendingPathComponent("Test.app")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if kind == "package-interior" {
                destination = destination.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
        }
        if kind == "system-root" { f.operations.refuseDestination(destination, reason: .systemRoot) }
        if kind == "trash" || kind == "trash-child" { f.operations.refuseDestination(destination, reason: .trash) }
        await f.cut([item])
        if kind == "missing" { try FileManager.default.removeItem(at: item) }
        if kind == "changed" {
            try FileManager.default.moveItem(at: item, to: f.source.appendingPathComponent("saved-old.txt"))
            try Data("replacement".utf8).write(to: item)
        }
        await f.paste(destination)
        #expect(f.operations.renameCalls.isEmpty)
        if kind != "missing" { #expect(FileManager.default.fileExists(atPath: item.path)) }
        #expect(f.leaser.balance == 0)
        if kind == "same-folder" { #expect(f.warnings.isEmpty) }
        else { #expect(f.warnings.count == 1) }
    }

    @Test func successfulPastePersistsOneRestartStableUndoRecord() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        let uuid = try #require(file.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        await f.cut([file]); await f.paste()
        let record = try #require(f.journal.load())
        #expect(record.version == 1)
        #expect(record.entries.count == 1)
        let entry = try #require(record.entries.first)
        #expect(entry.originalPath == file.path)
        #expect(entry.movedToPath == f.destination.appendingPathComponent("notes.txt").path)
        #expect(entry.identity.inode == inode)
        #expect(entry.identity.volumeUUID == uuid)
        #expect(entry.outcome == .moved)
        let encoded = try JSONEncoder().encode(record)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("st_dev"))
        #expect(!json.contains("fileResourceIdentifier"))
    }

    @Test func launchReconcilesCrashBetweenIntentAndOutcome() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        f.journal.failOutcomes.withLock { $0 = true }
        await f.cut([file]); await f.paste()
        #expect(f.journal.load()?.entries.first?.outcome == .intended)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        f.journal.failOutcomes.withLock { $0 = false }
        let relaunched = ActionService(state: State(), permission: f.permission, confirmation: Confirmation(),
            fileOperations: f.operations, pasteboard: f.board, now: { [clock = f.clock] in clock.now() }, accessLeaser: f.leaser, journalStore: f.journal,
            cutWarning: { _ in })
        // Any action waits for the initialization recovery, just as a launch-delivered click does.
        await relaunched.actionHandler(rid: "cut", target: [], trigger: "ctx-items")
        #expect(f.journal.load()?.entries.first?.outcome == .moved)
        #expect(f.journal.load()?.inProgress == false)
        #expect(f.leaser.balance == 0)
    }

    @Test(arguments: ["cancel-panel", "cancel-task", "timeout"])
    func deferredQuitRepliesExactlyOnceAndNeverWaitsForever(exit: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file(); await f.cut([file])
        f.permission.allowed = false
        var operation: Task<Void, Never>?
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            f.permission.onPrompt = { ready.resume() }
            operation = Task { await f.paste() }
        }
        var replies = 0
        #expect(f.service.deferTermination { replies += 1 })
        #expect(replies == 0)
        if exit == "timeout" {
            f.termination.advance(by: 35)
            #expect(replies == 1)
        }
        if exit == "cancel-task" { operation?.cancel() }
        f.permission.hold?.resume(returning: nil)
        f.permission.hold = nil
        await operation?.value
        #expect(replies == 1)
        f.termination.advance(by: 100)
        #expect(replies == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.leaser.balance == 0)
        #expect(f.termination.balance == 0)
        let count = f.board.changeCount
        await f.cut([file])
        #expect(f.board.changeCount == count) // No new reservations once Quit is pending.
    }

    @Test func coordinationTimeoutPreventsALateRenameAndNextPasteWorks() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.coordinationTimeout = 0.05
        let file = try f.file()
        let gate = DispatchSemaphore(value: 0)
        f.operations.onNextCoordination { _ in _ = gate.wait(timeout: .now() + 2) }
        // The red implementation eventually returns, so RED is an assertion failure,
        // never a hung test. The timeout implementation cancels before this release.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.signal() }
        await f.cut([file]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.warnings.first?.contains("timed out") == true)
        #expect(f.service.pendingCut?.paths == [file.path])
        try await Task.sleep(for: .milliseconds(350))
        #expect(FileManager.default.fileExists(atPath: file.path)) // Late accessor cannot mutate.
        await f.paste()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(f.leaser.balance == 0)
        #expect(f.termination.balance == 0)
    }

    @Test func batchCollapsesDuplicateAndNestedSelectionsAndMovesSymlinkAsLink() async throws {
        let f = try Fixture(); defer { f.clean() }
        let folder = f.source.appendingPathComponent("Project.v2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child.txt")
        try Data("child".utf8).write(to: child)
        let target = try f.file("target.txt")
        let link = f.source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await f.cut([folder, child, folder, link]); await f.paste()
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("Project.v2/child.txt")) == Data("child".utf8))
        let movedLink = f.destination.appendingPathComponent("link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: movedLink.path) == target.path)
        #expect(try Data(contentsOf: target) == Data("original".utf8))
        #expect(f.warnings.isEmpty)
        #expect(f.service.pendingCut == nil)
        #expect(f.journal.load()?.entries.count == 2)
        #expect(f.leaser.balance == 0)
    }

    @Test func failedClipboardRewriteDisablesPendingPaste() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file(); await f.cut([file])
        try FileManager.default.removeItem(at: file)
        f.cutBoard.rejectWrites = true
        await f.paste()
        #expect(f.service.pendingCut == nil)
        #expect(f.operations.renameCalls.isEmpty)
        #expect(f.warnings.count == 1)
        #expect(f.leaser.balance == 0)
    }

    @Test func journalOutcomeFailurePreservesUnattemptedItemsAndDurableIntent() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.file("first.txt"), second = try f.file("second.txt")
        let journal = f.journal
        let intentSeen = Counter()
        f.operations.onNextCoordination { _ in
            if journal.load()?.entries.last?.outcome == .intended { intentSeen.value.withLock { $0 += 1 } }
        }
        f.journal.failOutcomes.withLock { $0 = true }
        await f.cut([first, second]); await f.paste()
        #expect(intentSeen.value.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("first.txt").path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(f.service.pendingCut?.paths == [second.path])
        #expect(f.journal.load()?.entries.first?.outcome == .intended)
        #expect(f.warnings.count == 1)
        #expect(f.leaser.balance == 0)
    }

    // test only, already enforced: the final verification runs targeted mutants.
    @Test func newerClipboardSurvivesMoveAndSecondPasteIsRefused() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        let gate = DispatchSemaphore(value: 0)
        var operation: Task<Void, Never>?
        await f.cut([file])
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            f.operations.onNextCoordination { _ in
                ready.resume()
                _ = gate.wait(timeout: .now() + 5)
            }
            operation = Task { await f.paste() }
        }
        await f.paste()
        #expect(f.warnings.first?.contains("in progress") == true)
        let count = f.board.changeCount
        await f.cut([file])
        #expect(f.board.changeCount == count)
        f.board.clearContents(); f.board.setString("new owner", forType: .string)
        let newer = f.board.changeCount
        gate.signal(); await operation?.value
        #expect(f.board.changeCount == newer)
        #expect(f.board.string(forType: .string) == "new owner")
        #expect(f.service.pendingCut == nil)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        #expect(f.operations.renameCalls.count == 1)
    }

    @Test func identityIsCheckedInsideCoordinationAfterAReplacement() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file])
        f.operations.onNextCoordination { source in
            try FileManager.default.moveItem(at: source, to: source.appendingPathExtension("old"))
            try Data("replacement".utf8).write(to: source)
        }
        await f.paste()
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))
        #expect(f.operations.renameCalls.isEmpty)
        #expect(f.warnings.first?.localizedCaseInsensitiveContains("changed since cut") == true)
        #expect(f.service.pendingCut?.paths == [file.path])
    }

    @Test func staleCutRefusesBeforeAnyRename() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file(); await f.cut([file])
        f.board.clearContents(); f.board.setString("other copy", forType: .string)
        await f.paste()
        #expect(f.operations.renameCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.warnings.first?.contains("cut has ended") == true)
        #expect(f.board.string(forType: .string) == "other copy")
    }

    @Test func undoRecordSurvivesZeroSuccessIsReplacedBySuccessAndExpiresAt24Hours() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.file("first.txt")
        await f.cut([first]); await f.paste()
        let previous = try #require(f.journal.load()?.entries.first)
        let second = try f.file("second.txt")
        await f.cut([second]); await f.paste(f.source)
        #expect(f.journal.load()?.entries.first?.originalPath == previous.originalPath)
        await f.cut([second]); await f.paste()
        #expect(f.journal.load()?.entries.count == 1)
        #expect(f.journal.load()?.entries.first?.originalPath == second.path)
        f.clock.date.withLock { $0.addTimeInterval(86400) }
        let relaunched = ActionService(state: State(), permission: f.permission, confirmation: Confirmation(),
            fileOperations: f.operations, pasteboard: f.board, now: { [clock = f.clock] in clock.now() },
            accessLeaser: f.leaser, journalStore: f.journal, terminationBoundary: f.termination, cutWarning: { _ in })
        await relaunched.actionHandler(rid: "cut", target: [], trigger: "ctx-items")
        #expect(f.journal.load()?.entries.isEmpty == true)
    }

    @Test(arguments: ["Report.pages", "Foo.app", "Project.v2"])
    func numberedDirectoryAndPackageClashesKeepTheirMeaning(name: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = f.source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.destination.appendingPathComponent(name), withIntermediateDirectories: true)
        await f.cut([item]); await f.paste()
        let expected: String = name == "Report.pages" ? "Report 2.pages" : (name == "Foo.app" ? "Foo 2.app" : "Project.v2 2")
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent(expected).path))
        #expect(f.journal.load()?.entries.first?.movedToPath == f.destination.appendingPathComponent(expected).path)
    }

    @Test func caseOnlyClashNeverReplacesAndDifferentCaseDescendantIsRefused() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file("Notes.txt")
        try Data("existing".utf8).write(to: f.destination.appendingPathComponent("notes.txt"))
        await f.cut([file]); await f.paste()
        let caseSensitive = try f.destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        if !caseSensitive {
            #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes.txt")) == Data("existing".utf8))
            #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("Notes 2.txt").path))
        }
        let folder = f.source.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("child"), withIntermediateDirectories: true)
        await f.cut([folder])
        await f.paste(f.source.appendingPathComponent(caseSensitive ? "Folder/child" : "folder/child"))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(f.warnings.last?.contains("itself") == true)
    }

    @Test func everyPastePublishesRefreshedPendingStateToMenuObserver() async throws {
        let f = try Fixture(); defer { f.clean() }
        let good = try f.file("good.txt"), missing = try f.file("missing.txt")
        await f.cut([good, missing])
        try FileManager.default.removeItem(at: missing)
        let signals = Counter()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: f.service, queue: nil) { _ in
            signals.value.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await f.paste()
        #expect(signals.value.withLock { $0 } == 1)
        #expect(f.service.pendingCut?.paths == [missing.path])
        #expect(f.service.pendingCut?.changeCount == f.board.changeCount)
        await f.paste()
        #expect(signals.value.withLock { $0 } == 2)
    }

}
