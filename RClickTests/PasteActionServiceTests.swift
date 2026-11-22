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
        var allowedPaths: Set<String>?
        var replies: [Bool] = []
        var prompts: [String] = []
        var hold: CheckedContinuation<URL?, Never>?
        var onPrompt: (() -> Void)?
        func hasAccess(to url: URL) -> Bool { allowedPaths?.contains(url.path) ?? allowed }
        func promptForPermission(for url: URL) async -> URL? {
            prompts.append(url.path)
            if let onPrompt {
                return await withCheckedContinuation { hold = $0; onPrompt() }
            }
            if !replies.isEmpty, replies.removeFirst() {
                allowedPaths?.insert(url.path)
                return url
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
        let history = Mutex<[MoveJournal]>([])
        let failOutcomes = Mutex(false)
        let failFinal = Mutex(false)
        func load() -> MoveJournal? { value.withLock { $0 } }
        func save(_ journal: MoveJournal) throws {
            if failFinal.withLock({ $0 }), !journal.inProgress { throw CocoaError(.fileWriteUnknown) }
            if failOutcomes.withLock({ $0 }), journal.entries.contains(where: { $0.outcome == .moved }) {
                throw CocoaError(.fileWriteUnknown)
            }
            value.withLock { $0 = journal }
            history.withLock { $0.append(journal) }
        }
    }
    @MainActor final class ManualTermination: MoveTerminationBoundary {
        var date = Date(timeIntervalSince1970: 100000)
        var scheduled: [(Date, @MainActor () -> Void)] = []
        nonisolated let protection = Counter()
        var balance: Int { protection.value.withLock { $0 } }
        func protectMutation() { protection.value.withLock { $0 += 1 } }
        func unprotectMutation() { protection.value.withLock { $0 -= 1 } }
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
        var storeOverride: (any UndoJournalStore)?
        var coordinationTimeout: TimeInterval = 30
        let termination = ManualTermination()
        let clock = Clock()
        let journal = JournalStore()
        lazy var cutBoard = FailingCutBoard(board)
        let state = State()
        var expiryWait: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
        let permission = Permission()
        let leaser = Leaser()
        let operations = FaultInjectingFileOperations()
        var warnings: [String] = []
        lazy var service = ActionService(state: state, permission: permission, confirmation: Confirmation(),
            fileOperations: operations, pasteboard: board, now: { [clock] in clock.now() }, accessLeaser: leaser, journalStore: storeOverride ?? journal, undoExpiryWait: expiryWait, cutPasteboard: cutBoard, terminationBoundary: termination, coordinationTimeout: coordinationTimeout,
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
        f.operations.failRename(missing, with: .EACCES)
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
        let beforeRecord = f.service.pendingCut
        let beforeClipboard = f.board.changeCount
        let beforeURLs = f.board.pasteboardItems?.map { $0.string(forType: .fileURL) }
        let journalEncoder = JSONEncoder()
        journalEncoder.outputFormatting = .sortedKeys
        let beforeJournal = try f.journal.load().map { try journalEncoder.encode($0) }
        let beforeWrites = f.journal.history.withLock { $0.count }
        let updates = Counter()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: f.service, queue: nil) { _ in
            updates.value.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await f.paste(destination)
        #expect(f.operations.renameCalls.isEmpty)
        if kind != "missing" { #expect(FileManager.default.fileExists(atPath: item.path)) }
        #expect(f.leaser.balance == 0)
        if kind == "same-folder" {
            #expect(f.warnings.isEmpty)
            #expect(f.board.changeCount == beforeClipboard)
            #expect(f.board.pasteboardItems?.map { $0.string(forType: .fileURL) } == beforeURLs)
            #expect(f.service.pendingCut?.paths == beforeRecord?.paths)
            #expect(f.service.pendingCut?.identities == beforeRecord?.identities)
            #expect(f.service.pendingCut?.changeCount == beforeRecord?.changeCount)
            #expect(try f.journal.load().map { try journalEncoder.encode($0) } == beforeJournal)
            #expect(f.journal.history.withLock { $0.count } == beforeWrites)
            #expect(updates.value.withLock { $0 } == 0)
        } else { #expect(f.warnings.count == 1) }
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
        let file = try f.file()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let observed = Counter()
        let ended = AsyncStream<Void> { end in
            f.operations.onNextCoordination { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 2) // Test watchdog; never the production timeout.
                end.yield(())
                end.finish()
            }
        }
        f.operations.onNextCoordinationWait { _, _ in
            if entered.wait(timeout: .now() + 2) == .success { observed.value.withLock { $0 += 1 } }
            return .timedOut // Deterministic injected deadline, after the accessor entered.
        }
        await f.cut([file]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.warnings.first?.contains("timed out") == true)
        #expect(f.service.pendingCut?.paths == [file.path])
        release.signal()
        for await _ in ended { break }
        #expect(observed.value.withLock { $0 } == 1)
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
        f.operations.failRename(missing, with: .EACCES)
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

    @Test(arguments: ["success", "partial", "refusal", "cancel-panel", "cancel-task", "timeout"])
    func delegateDefersAndRepliesOnceOnEveryExit(exit: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.file(), second = try f.file("second.txt")
        await f.cut(exit == "partial" ? [first, second] : [first])
        if exit == "partial" { f.operations.failRename(second, with: .EACCES) }
        if exit == "refusal" { f.operations.refuseDestination(f.destination, reason: .trash) }
        f.permission.allowed = false
        var operation: Task<Void, Never>?
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            f.permission.onPrompt = { ready.resume() }
            operation = Task { await f.paste() }
        }
        var replies = 0
        let delegate = AppDelegate(isTestHost: true, sendQuit: {}, terminationService: f.service, replyToTermination: {
            replies += 1
            if exit != "timeout" {
                #expect(f.leaser.balance == 0)
                #expect(f.termination.balance == 0)
                if ["success", "partial"].contains(exit) {
                    #expect(f.journal.load()?.inProgress == false)
                    #expect(f.journal.load()?.entries.first?.outcome == .moved)
                }
                if exit == "success" {
                    #expect(f.service.pendingCut == nil)
                    #expect(f.board.pasteboardItems?.isEmpty != false)
                } else if exit == "partial" {
                    #expect(f.service.pendingCut?.paths == [second.path])
                    #expect(f.service.pendingCut?.changeCount == f.board.changeCount)
                }
            }
        })
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(replies == 0)
        if exit == "timeout" { f.termination.advance(by: 35); #expect(replies == 1) }
        if exit == "cancel-task" { operation?.cancel() }
        f.permission.allowed = true
        f.permission.hold?.resume(returning: ["cancel-panel", "timeout"].contains(exit) ? nil : f.destination)
        f.permission.hold = nil
        await operation?.value
        #expect(replies == 1)
        f.termination.advance(by: 100)
        #expect(replies == 1)
        #expect(f.leaser.balance == 0)
        #expect(f.termination.balance == 0)
        if ["success", "partial"].contains(exit) {
            #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        } else { #expect(FileManager.default.fileExists(atPath: first.path)) }
    }

    @Test(arguments: ["outside", "same-container", "other-container"])
    func providerFallbackPreservesContainerBoundary(destinationKind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let cloud = f.source.appendingPathComponent("CloudStorage")
        let provider = cloud.appendingPathComponent("ProviderA")
        let folder = provider.appendingPathComponent("source")
        let destination = destinationKind == "outside" ? f.destination :
            (destinationKind == "same-container" ? provider : cloud.appendingPathComponent("ProviderB")).appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("cloud.txt")
        try Data("cloud".utf8).write(to: file)
        f.operations.setProviderRoots([cloud])
        await f.cut([file]); await f.paste(destination)
        if destinationKind == "same-container" {
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("cloud.txt").path))
            #expect(f.warnings.isEmpty)
        } else {
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(f.operations.renameCalls.isEmpty)
            #expect(f.warnings.first?.contains("cloud container") == true)
        }
    }

    @Test(arguments: [false, true]) func providerStorageRootCannotEscapeItsContainer(differentCase: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let root = f.source.appendingPathComponent("CloudStorage")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        f.operations.setProviderRoots([root])
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        let selected = differentCase && !caseSensitive ? f.source.appendingPathComponent("cloudstorage") : root
        await f.cut([selected]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(f.operations.renameCalls.isEmpty)
        #expect(f.warnings.first?.contains("cloud container") == true)
    }

    @Test func unsupportedRenamePersistsItsFailedOutcomeAndKeepsTheSource() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        f.operations.failRename(file, with: .ENOTSUP)
        await f.cut([file]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.service.pendingCut?.paths == [file.path])
        #expect(f.warnings.first?.contains("does not support exclusive") == true)
        #expect(f.journal.history.withLock { $0.contains { $0.entries.last?.outcome == .failed } })
        #expect(f.journal.load()?.entries.isEmpty == true)
        #expect(f.leaser.balance == 0)
    }

    @Test func journalUsesTheInjectedVolumeUUIDSystemBoundary() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        f.operations.setVolumeUUID("TEST-VOLUME-UUID", for: file)
        await f.cut([file]); await f.paste()
        #expect(f.journal.load()?.entries.first?.identity.volumeUUID == "TEST-VOLUME-UUID")
    }

    // test only, already enforced: production store is exercised in a temp folder.
    @Test func atomicJournalReloadsThroughANewStoreAndService() async throws {
        let f = try Fixture(); defer { f.clean() }
        let path = f.root.appendingPathComponent("journal.json")
        let store = AtomicUndoJournalStore(url: path)
        f.storeOverride = store
        let file = try f.file(); await f.cut([file]); await f.paste()
        #expect(try store.load()?.entries.first?.outcome == .moved)
        let reloaded = AtomicUndoJournalStore(url: path)
        let service = ActionService(state: State(), permission: f.permission, confirmation: Confirmation(),
            fileOperations: f.operations, pasteboard: f.board, now: { [clock = f.clock] in clock.now() },
            accessLeaser: f.leaser, journalStore: reloaded, terminationBoundary: f.termination, cutWarning: { _ in })
        await service.actionHandler(rid: "cut", target: [], trigger: "ctx-items")
        #expect(try reloaded.load()?.entries.first?.originalPath == file.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        #expect(!files.contains { $0.hasPrefix(".paste-journal-") })
    }

    @Test(arguments: ["home", "Desktop", "Documents", "trash", "trash-child", "provider"])
    func accountHomeBoundaryDrivesRealDestinationAndProviderClassification(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.operations.setAccountHome(f.destination)
        var file = try f.file()
        var destination = f.destination
        if kind == "Desktop" || kind == "Documents" { destination = destination.appendingPathComponent(kind) }
        if kind == "trash" || kind == "trash-child" {
            destination = destination.appendingPathComponent(kind == "trash" ? ".Trash" : ".Trash/child")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if kind == "provider" {
            let folder = f.destination.appendingPathComponent("Library/CloudStorage/Provider/source")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = folder.appendingPathComponent("cloud.txt")
            try Data("cloud".utf8).write(to: file)
            destination = f.source
        }
        await f.cut([file]); await f.paste(destination)
        if ["home", "Desktop", "Documents"].contains(kind) {
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("notes.txt").path))
            #expect(f.warnings.isEmpty)
        } else {
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(f.operations.renameCalls.isEmpty)
            #expect(f.warnings.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func trashNameVariantsAreRefusedRegardlessOfVolumeCaseSensitivity(caseSensitive: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.operations.setAccountHome(f.destination)
        f.operations.setMoveFacts(MoveFacts(directory: true, caseSensitiveNames: caseSensitive), for: f.destination)
        let folder = f.destination.appendingPathComponent(".TRASH")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try f.file(); await f.cut([file]); await f.paste(folder)
        // Amendment 1 deliberately refuses dotted Trash names conservatively,
        // even when a case-sensitive volume treats the spelling as distinct.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.operations.renameCalls.isEmpty)
        #expect(f.warnings.first?.contains("Use Finder’s Move to Trash") == true)
        #expect(f.service.pendingCut?.paths == [file.path])
    }

    // test only, already enforced; final mutants remove the relevant protection.
    @Test func cancellingTheLastSourceParentPanelMovesNothing() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.file()
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let second = other.appendingPathComponent("second.txt")
        try Data("second".utf8).write(to: second)
        f.permission.allowedPaths = [f.source.path, other.path]
        await f.cut([first, second])
        let count = f.board.changeCount
        f.permission.allowedPaths = [f.source.path]
        f.permission.replies = [true, false]
        await f.paste()
        #expect(f.permission.prompts == [f.destination.path, other.path])
        #expect(f.operations.renameCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(f.board.changeCount == count)
        #expect(f.service.pendingCut?.paths == [first.path, second.path])
        #expect(f.leaser.balance == 0)
    }

    @Test func overlongNumberedNameLeavesOriginalAndClashIntact() async throws {
        let f = try Fixture(); defer { f.clean() }
        let name = String(repeating: "a", count: 251) + ".txt"
        let file = try f.file(name)
        let clash = f.destination.appendingPathComponent(name)
        try Data("keep".utf8).write(to: clash)
        await f.cut([file]); await f.paste()
        #expect(try Data(contentsOf: file) == Data("original".utf8))
        #expect(try Data(contentsOf: clash) == Data("keep".utf8))
        #expect(f.service.pendingCut?.paths == [file.path])
        #expect(f.warnings.first?.contains("255 UTF-8 bytes") == true)
        #expect(f.operations.renameCalls.count == 1)
    }

    @Test func writableVolumeRootPassesDestinationPolicyWithoutTouchingUserFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        let volume = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        let reached = Counter()
        f.operations.onNextCoordination { _ in
            reached.value.withLock { $0 += 1 }
            throw POSIXError(.ENOTSUP) // No actual rename outside the temp tree.
        }
        await f.cut([file]); await f.paste(volume)
        #expect(reached.value.withLock { $0 } == 1)
        #expect(f.operations.renameCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func danglingTerminalSymlinkMovesAsALink() async throws {
        let f = try Fixture(); defer { f.clean() }
        let link = f.source.appendingPathComponent("dangling")
        let target = f.root.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await f.cut([link]); await f.paste()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("dangling").path) == target.path)
        #expect(f.warnings.isEmpty)
        #expect(f.service.pendingCut == nil)
    }

    // test only, already enforced: observe protection at the filesystem boundary.
    @Test func mutationHoldsLeasesAndSuddenTerminationProtection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        let protection = f.termination.protection, lease = f.leaser.counter, observed = Counter()
        f.operations.onNextCoordination { _ in
            if protection.value.withLock({ $0 }) == 1 && lease.value.withLock({ $0 }) == 1 {
                observed.value.withLock { $0 += 1 }
            }
        }
        await f.cut([file]); await f.paste()
        #expect(observed.value.withLock { $0 } == 1)
        #expect(f.leaser.balance == 0)
        #expect(f.termination.balance == 0)
    }

}

extension PasteActionServiceTests {
    @Test func undoRoundTripRestoresOriginalNameAndConsumesRecord() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file("Résumé 日本語.txt")
        try Data("occupied".utf8).write(to: f.destination.appendingPathComponent(file.lastPathComponent))
        await f.cut([file]); await f.paste()
        await f.service.actionHandler(rid: "undo-move", target: [], trigger: "ctx-container")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(f.journal.load()?.entries.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("Résumé 日本語 2.txt").path))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent(file.lastPathComponent)) == Data("occupied".utf8))
    }
}

extension PasteActionServiceTests {
    @Test func undoAvailabilityUsesClockAndPublishesAfterPasteUndoAndLaunch() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        let signals = Counter()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: f.service, queue: nil) { _ in
            signals.value.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await f.cut([file])
        #expect(!f.service.undoMoveAvailable)
        #expect(signals.value.withLock { $0 } >= 1) // Launch recovery completed.
        await f.paste()
        #expect(f.service.undoMoveAvailable)
        let afterPaste = signals.value.withLock { $0 }
        #expect(afterPaste >= 2)
        f.clock.date.withLock { $0.addTimeInterval(86400) }
        #expect(!f.service.undoMoveAvailable)
        await f.service.actionHandler(rid: "undo-move", target: [], trigger: "ctx-container")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(f.warnings.last?.contains("no move to undo") == true)
        #expect(signals.value.withLock { $0 } > afterPaste)
    }
}

extension PasteActionServiceTests {
    @Test func undoExpiringDuringPermissionPanelDoesNotMoveAnything() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file]); await f.paste()
        f.permission.allowed = false
        var operation: Task<Void, Never>?
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            f.permission.onPrompt = { ready.resume() }
            operation = Task { await f.service.actionHandler(rid: "undo-move", target: [], trigger: "ctx-container") }
        }
        f.clock.date.withLock { $0.addTimeInterval(86400) }
        f.permission.allowed = true
        f.permission.hold?.resume(returning: f.source)
        await operation?.value
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent(file.lastPathComponent).path))
        #expect(f.warnings.last?.contains("no move to undo") == true)
    }
}

extension PasteActionServiceTests {
    private func undo(_ service: ActionService) async {
        await service.actionHandler(rid: "undo-move", target: [], trigger: "ctx-container")
    }

    @Test func undoClashUsesOriginalNameAndNeverOverwritesRacingOwner() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file]); await f.paste()
        try Data("second owner".utf8).write(to: f.source.appendingPathComponent("notes 2.txt"))
        f.operations.createClashAtRename(file)
        await undo(f.service)
        #expect(try Data(contentsOf: file) == Data("racing owner".utf8))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("notes 2.txt")) == Data("second owner".utf8))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("notes 3.txt")) == Data("original".utf8))
        #expect(f.warnings.isEmpty)
        #expect(!f.service.undoMoveAvailable)
    }

    @Test(arguments: ["replacement", "missing", "uuid", "birth", "ambiguous"])
    func undoSkipsUnprovenIdentityAndStillRestoresTheOtherItem(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let bad = try f.file("bad.txt"), good = try f.file("good.txt")
        await f.cut([bad, good]); await f.paste()
        let moved = f.destination.appendingPathComponent("bad.txt")
        if kind == "replacement" {
            try FileManager.default.moveItem(at: moved, to: moved.appendingPathExtension("old"))
            try Data("replacement".utf8).write(to: moved)
        } else if kind == "missing" {
            try FileManager.default.removeItem(at: moved)
        } else {
            var journal = try #require(f.journal.load())
            let index = try #require(journal.entries.firstIndex { $0.originalPath == bad.path })
            let entry = journal.entries[index]
            if kind == "ambiguous" { journal.entries.append(entry) }
            else {
                let identity = StableMoveIdentity(volumeUUID: kind == "uuid" ? "different-volume" : entry.identity.volumeUUID,
                    inode: entry.identity.inode, creationDate: kind == "birth" ? entry.identity.creationDate.addingTimeInterval(1) : entry.identity.creationDate)
                journal.entries[index] = MoveJournalEntry(originalPath: entry.originalPath, movedToPath: entry.movedToPath,
                    identity: identity, timestamp: entry.timestamp, outcome: .moved)
            }
            try f.journal.save(journal)
        }
        await undo(f.service)
        #expect(!FileManager.default.fileExists(atPath: bad.path))
        #expect(try Data(contentsOf: good) == Data("original".utf8))
        if kind == "replacement" { #expect(try Data(contentsOf: moved) == Data("replacement".utf8)) }
        #expect(f.warnings.count == 1)
        #expect(f.warnings.first?.contains("bad.txt") == true)
        #expect(f.warnings.first?.contains("good.txt") == false)
        #expect(f.journal.load()?.entries.isEmpty == true)
        #expect(!f.service.undoMoveAvailable)
    }

    @Test(arguments: ["deleted", "trash", "package", "unwritable"])
    func undoNeverRecreatesOrWritesIntoAnUnavailableOriginalFolder(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file]); await f.paste()
        if kind == "deleted" { try FileManager.default.removeItem(at: f.source) }
        if kind == "trash" { f.operations.setTrashDirectories([f.source]) }
        if kind == "package" { f.operations.setMoveFacts(MoveFacts(directory: true, package: true), for: f.source) }
        if kind == "unwritable" { f.operations.reportUnwritable(f.source) }
        await undo(f.service)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent(file.lastPathComponent).path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        if kind == "deleted" { #expect(!FileManager.default.fileExists(atPath: f.source.path)) }
        #expect(f.warnings.count == 1)
        #expect(f.journal.load()?.entries.isEmpty == true)
        #expect(f.leaser.balance == 0)
    }

    @Test(arguments: [false, true])
    func undoRequiresBothFolderGrantsBeforeTouchingAnyItem(_ deniedOriginal: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file]); await f.paste()
        f.permission.allowedPaths = [deniedOriginal ? f.destination.path : f.source.path]
        let priorRenames = f.operations.renameCalls.count
        await undo(f.service)
        #expect(f.permission.prompts == [deniedOriginal ? f.source.path : f.destination.path])
        #expect(f.operations.renameCalls.count == priorRenames)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(f.journal.load()?.entries.count == 1)
        #expect(f.service.undoMoveAvailable)
        #expect(f.warnings.count == 1)
        #expect(f.leaser.balance == 0)
    }

    @Test func undoReloadsAtomicStorageAndOnlyRestoresTheLastPaste() async throws {
        let f = try Fixture(); defer { f.clean() }
        let journalURL = f.root.appendingPathComponent("journal.json")
        f.storeOverride = AtomicUndoJournalStore(url: journalURL)
        let old = try f.file("old.txt"), last = try f.file("last.txt")
        await f.cut([old]); await f.paste()
        await f.cut([last]); await f.paste()
        var warnings: [String] = []
        let relaunched = ActionService(state: State(), permission: f.permission, confirmation: Confirmation(),
            fileOperations: f.operations, pasteboard: f.board, now: { [clock = f.clock] in clock.now() },
            accessLeaser: f.leaser, journalStore: AtomicUndoJournalStore(url: journalURL), cutWarning: { warnings.append($0) })
        await relaunched.actionHandler(rid: "not-an-action", target: [], trigger: "ctx-container") // Wait for launch recovery.
        #expect(relaunched.undoMoveAvailable)
        await undo(relaunched)
        #expect(try Data(contentsOf: last) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("old.txt")) == Data("original".utf8))
        #expect(try AtomicUndoJournalStore(url: journalURL).load()?.entries.isEmpty == true)
        #expect(!relaunched.undoMoveAvailable)
        #expect(warnings.isEmpty)
    }

    @Test(arguments: [false, true])
    func pasteAndUndoRefuseEachOtherWhileOneMoveIsReserved(_ firstIsUndo: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file])
        if firstIsUndo { await f.paste() }
        let gate = DispatchSemaphore(value: 0)
        var operation: Task<Void, Never>?
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            f.operations.onNextCoordination { _ in ready.resume(); _ = gate.wait(timeout: .now() + 5) }
            operation = Task {
                if firstIsUndo { await undo(f.service) } else { await f.paste() }
            }
        }
        await undo(f.service)
        await f.paste()
        #expect(f.warnings.count == 2)
        #expect(f.warnings.allSatisfy { $0.contains("in progress") })
        gate.signal(); await operation?.value
        #expect(f.leaser.balance == 0)
        #expect(f.termination.balance == 0)
    }

    @Test func undoPinsOriginalParentAgainstAnAncestorSymlinkSwap() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        await f.cut([item]); await f.paste()
        let source = f.source, parked = f.root.appendingPathComponent("parked")
        let elsewhere = f.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        f.operations.onNextRename {
            try FileManager.default.moveItem(at: source, to: parked)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: elsewhere)
        }
        await undo(f.service)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent(item.lastPathComponent).path))
        #expect(try Data(contentsOf: parked.appendingPathComponent(item.lastPathComponent)) == Data("original".utf8))
        #expect(f.warnings.isEmpty)
    }

    @Test func undoRechecksIdentityInsideCoordination() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        await f.cut([item]); await f.paste()
        f.operations.onNextCoordination { moved in
            try FileManager.default.moveItem(at: moved, to: moved.appendingPathExtension("old"))
            try Data("impostor".utf8).write(to: moved)
        }
        await undo(f.service)
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent(item.lastPathComponent)) == Data("impostor".utf8))
        #expect(f.warnings.count == 1)
    }
}

private actor UndoExpirySleeper {
    nonisolated let scheduled: AsyncStream<TimeInterval>
    private let signal: AsyncStream<TimeInterval>.Continuation
    private var waiting: CheckedContinuation<Void, Never>?
    init() {
        let pair = AsyncStream<TimeInterval>.makeStream()
        scheduled = pair.stream; signal = pair.continuation
    }
    func wait(_ interval: TimeInterval) async {
        await withCheckedContinuation { waiting = $0; signal.yield(interval) }
    }
    func wake() { waiting?.resume(); waiting = nil }
}

extension PasteActionServiceTests {
    @Test func undoExpiryPublishesWithoutAnotherUserAction() async throws {
        let f = try Fixture(); defer { f.clean() }
        let sleeper = UndoExpirySleeper()
        f.expiryWait = { await sleeper.wait($0) }
        let file = try f.file()
        await f.cut([file]); await f.paste()
        var scheduled = sleeper.scheduled.makeAsyncIterator()
        #expect(await scheduled.next() == 86400)
        let updates = AsyncStream<Void>.makeStream()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: f.service, queue: nil) { _ in
            updates.continuation.yield(())
        }
        defer { NotificationCenter.default.removeObserver(token) }
        f.clock.date.withLock { $0.addTimeInterval(86400) }
        await sleeper.wake()
        var events = updates.stream.makeAsyncIterator()
        await events.next()
        #expect(!f.service.undoMoveAvailable)
    }

    @Test func disablingCutAlsoRefusesUndoAndKeepsItsRecord() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file]); await f.paste()
        f.state.actions[0].enabled = false
        await f.service.actionHandler(rid: "undo-move", target: [], trigger: "ctx-container")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(f.journal.load()?.entries.count == 1)
        #expect(f.warnings.isEmpty)
    }
}


extension PasteActionServiceTests {
    @Test func undoIsHiddenAndStaleClickRefusedUntilFailedFinalPersistIsRecovered() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = try f.file()
        await f.cut([file]) // Wait for launch recovery before injecting the failure.
        let signals = Counter()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: f.service, queue: nil) { _ in
            signals.value.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        f.journal.failFinal.withLock { $0 = true }
        await f.paste()
        #expect(f.journal.load()?.inProgress == true)
        #expect(f.journal.load()?.entries.first?.outcome == .moved)
        #expect(!f.service.undoMoveAvailable)
        #expect(signals.value.withLock { $0 } > 0)
        for kind in [MenuTrigger.contextualContainer, .contextualItems] {
            let config = MenuConfigPayload(actions: [ActionMenuItem(id: "cut", name: "Cut & Paste", icon: "scissors", tag: 6)],
                undoMoveAvailable: f.service.undoMoveAvailable)
            #expect(!PendingCut.renderMenuVisibility(config: config, menuKind: kind,
                selection: [file.path], selectedItemIsDirectory: false, currentChangeCount: 0, hostOnline: true).undo)
        }
        f.warnings = []
        await undo(f.service)
        #expect(f.warnings.last?.contains("no move to undo") == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent(file.lastPathComponent)) == Data("original".utf8))
        #expect(f.journal.load()?.inProgress == true)
        f.journal.failFinal.withLock { $0 = false }
        let relaunched = ActionService(state: State(), permission: f.permission, confirmation: Confirmation(),
            fileOperations: f.operations, pasteboard: f.board, now: { [clock = f.clock] in clock.now() },
            accessLeaser: f.leaser, journalStore: f.journal, cutWarning: { _ in })
        let recoveredSignals = Counter()
        let recoveredToken = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: relaunched, queue: nil) { _ in
            recoveredSignals.value.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(recoveredToken) }
        await relaunched.actionHandler(rid: "cut", target: [], trigger: "ctx-items")
        #expect(relaunched.undoMoveAvailable)
        #expect(recoveredSignals.value.withLock { $0 } > 0)
        #expect(!FileManager.default.fileExists(atPath: file.path)) // Recovery never moves files.
    }
}
