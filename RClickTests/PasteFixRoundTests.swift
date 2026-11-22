import AppKit
import Synchronization
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

extension PasteActionServiceTests {
    @Test func coordinatedMoveAnnouncesBeforeRenameAndCompletion() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        await f.cut([item]); await f.paste()
        #expect(f.operations.moveEvents == ["willMoveTo", "rename", "didMoveTo"])
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes.txt")) == Data("original".utf8))
    }
}

extension PasteActionServiceTests {
    @Test(arguments: ["symlink", "package", "replacement", "moved-away", "later-item", "volume"])
    func destinationChangedInsideCoordinationNeverReceivesTheItem(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.file("first.txt")
        let second = try f.file("second.txt")
        let destination = f.destination
        let parked = f.root.appendingPathComponent("original-destination")
        let elsewhere = f.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let operations = f.operations
        let swap: @Sendable (URL) throws -> Void = { _ in
            if kind == "package" {
                operations.setMoveFacts(MoveFacts(directory: true, package: true), for: destination)
            } else if kind == "volume" {
                operations.placeOnOtherVolume(destination.path)
            } else {
                try FileManager.default.moveItem(at: destination, to: parked)
                if kind == "symlink" || kind == "later-item" {
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
                } else if kind == "replacement" {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                }
            }
        }
        if kind == "later-item" {
            operations.onNextCoordination { _ in operations.onNextCoordination(swap) }
        } else { operations.onNextCoordination(swap) }
        await f.cut(kind == "later-item" ? [first, second] : [first])
        await f.paste()
        let refused = kind == "later-item" ? second : first
        #expect(FileManager.default.fileExists(atPath: refused.path))
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent(refused.lastPathComponent).path))
        #expect(operations.renameCalls.count == (kind == "later-item" ? 1 : 0))
        #expect(f.service.pendingCut?.paths == [refused.path])
        #expect(f.warnings.first?.contains("The destination changed") == true)
        if kind == "later-item" {
            #expect(try Data(contentsOf: parked.appendingPathComponent("first.txt")) == Data("original".utf8))
        }
        #expect(f.leaser.balance == 0)
    }
}

extension PasteActionServiceTests {
    @Test func crossVolumeRefusalPrecedesJournalIntentAndCoordination() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let entered = Counter()
        f.operations.placeOnOtherVolume(f.destination.path)
        f.operations.onNextCoordination { _ in entered.value.withLock { $0 += 1 } }
        await f.cut([item]); await f.paste()
        #expect(entered.value.withLock { $0 } == 0)
        #expect(!f.journal.history.withLock { $0.contains { $0.entries.contains { $0.outcome == .intended } } })
        #expect(f.warnings.first?.contains("Moving between disks is not supported yet") == true)
        #expect(FileManager.default.fileExists(atPath: item.path))
    }
}

extension PasteActionServiceTests {
    @Test(arguments: ["/", "/System", "/Library", "/usr", "/bin", "/sbin"])
    func realSystemRootClassifierRefusesEveryRoot(_ path: String) throws {
        #expect(try SystemFileOperations().readDestinationRefusal(URL(fileURLWithPath: path)) == .systemRoot)
    }

    @Test func realPerVolumeTrashClassifierRefusesDescendants() throws {
        let f = try Fixture(); defer { f.clean() }
        let trash = f.destination.appendingPathComponent(".Trashes")
        let child = trash.appendingPathComponent("501/subfolder")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        f.operations.setMoveFacts(MoveFacts(directory: true, mountPoint: true), for: f.destination)
        #expect(try f.operations.readDestinationRefusal(trash) == .trash)
        #expect(try f.operations.readDestinationRefusal(child) == .trash)
        #expect(f.operations.renameCalls.isEmpty)
    }
}

extension PasteActionServiceTests {
    @Test func failedRecoverySaveCannotDropAnOlderInterruptedIntent() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try f.file("first.txt")
        f.journal.failOutcomes.withLock { $0 = true }
        await f.cut([first]); await f.paste()
        let older = try #require(f.journal.load()?.entries.first)
        #expect(older.outcome == .intended)
        let second = try f.file("second.txt")
        await f.cut([second]); await f.paste()
        // Recovery found the first move, but saving that outcome still failed.
        // The second write-ahead intent must retain the first durable intent.
        #expect(f.journal.load()?.deferred?.first?.originalPath == first.path)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("second.txt").path))
        f.journal.failOutcomes.withLock { $0 = false }
        let third = try f.file("third.txt")
        await f.cut([third]); await f.paste()
        #expect(f.journal.load()?.deferred?.first?.identity == older.identity)
        #expect(f.journal.load()?.deferred?.first?.outcome == .moved)
        #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("third.txt").path))
        #expect(f.leaser.balance == 0)
    }
}

extension PasteActionServiceTests {
    @Test(arguments: [".Trash", "Disguised.app"])
    func ancestorSymlinkSwapCannotMoveIntoUnsafeDestination(_ unsafeName: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let parent = f.root.appendingPathComponent("ordinary")
        let folder = parent.appendingPathComponent("destination")
        let parked = f.root.appendingPathComponent(unsafeName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        f.operations.onNextCoordination { _ in
            try FileManager.default.moveItem(at: parent, to: parked)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: parked)
        }
        await f.cut([item]); await f.paste(folder)
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(!FileManager.default.fileExists(atPath: parked.appendingPathComponent("destination/notes.txt").path))
        #expect(f.operations.renameCalls.isEmpty)
        #expect(f.warnings.first?.contains("The destination changed") == true)
        #expect(f.service.pendingCut?.paths == [item.path])
        #expect(f.leaser.balance == 0)
    }
}


extension PasteActionServiceTests {
    @Test(arguments: [DestinationRefusal.trash, .package, .systemRoot])
    func descriptorReportedUnsafePathRefusesEvenWhenLexicalPathLooksSafe(_ refusal: DestinationRefusal) async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let real = f.root.appendingPathComponent("descriptor-destination")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let operations = f.operations
        operations.refuseDestination(real, reason: refusal)
        operations.onNextCoordination { _ in operations.reportDescriptorPath(real) }
        await f.cut([item]); await f.paste()
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
        #expect(f.warnings.first?.contains("The destination changed") == true)
        #expect(operations.renameCalls.isEmpty)
    }

    @Test func ancestorReplacedAfterValidationCannotRedirectDescriptorRename() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let parent = f.root.appendingPathComponent("ordinary")
        let folder = parent.appendingPathComponent("destination")
        let parked = f.root.appendingPathComponent("parked")
        let replacement = f.root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement.appendingPathComponent("destination"), withIntermediateDirectories: true)
        let operations = f.operations
        let expected = try operations.fileIdentity(of: item)
        let expectedDestination = try operations.fileIdentity(of: folder)
        operations.onNextRename {
            try FileManager.default.moveItem(at: parent, to: parked)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: replacement)
        }
        try await Task.detached {
            try operations.coordinatedExclusiveMove(from: item, to: folder.appendingPathComponent("notes.txt"),
                expected: expected, expectedDestination: expectedDestination, timeout: 30)
        }.value
        #expect(!FileManager.default.fileExists(atPath: replacement.appendingPathComponent("destination/notes.txt").path))
        #expect(try Data(contentsOf: parked.appendingPathComponent("destination/notes.txt")) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }
}

extension PasteActionServiceTests {
    @Test(arguments: [false, true])
    func vanishedCutItemsReportChangedAndNeverLeaveAnOrphanMarker(_ mixed: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let gone = try f.file("gone.txt")
        let retry = try f.file("retry.txt")
        let good = try f.file("good.txt")
        await f.cut(mixed ? [gone, retry, good] : [gone])
        try FileManager.default.removeItem(at: gone)
        if mixed { f.operations.failRename(retry, with: .EACCES) }
        await f.paste()
        #expect(f.warnings.first?.contains("gone.txt: Changed since cut") == true)
        if mixed {
            #expect(f.service.pendingCut?.paths == [retry.path])
            #expect(f.board.pasteboardItems?.count == 1)
            #expect(f.board.pasteboardItems?.first?.string(forType: .fileURL) == retry.absoluteString)
            #expect(f.board.types?.contains(PendingCut.markerType) == true)
            #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("good.txt").path))
            #expect(f.journal.load()?.entries.count == 1)
        } else {
            #expect(f.service.pendingCut == nil)
            #expect(f.board.pasteboardItems?.isEmpty != false)
            #expect(f.board.types?.contains(PendingCut.markerType) != true)
            #expect(f.board.types?.contains(PendingCut.sourceType) != true)
        }
        #expect(f.leaser.balance == 0)
    }
}


extension PasteActionServiceTests {
    @Test func writableSearchableDropBoxAcceptsPasteWithoutReadPermission() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        await f.cut([item])
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: f.destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.destination.path) }
        await f.paste()
        #expect(f.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("notes.txt")) == Data("original".utf8))
        #expect(f.journal.load()?.entries.first?.outcome == .moved)
        #expect(f.service.pendingCut == nil)
    }

    @Test func directoryOpenPermissionFailureIsNotDestinationChanged() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let operations = f.operations
        let destination = f.destination
        operations.onNextCoordination { _ in operations.denyDirectoryOpen(destination) }
        await f.cut([item]); await f.paste()
        #expect(f.warnings.first?.contains(POSIXError(.EACCES).localizedDescription) == true)
        #expect(f.warnings.first?.contains("The destination changed") == false)
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(f.service.pendingCut?.paths == [item.path])
    }
}


extension PasteActionServiceTests {
    @Test func cutParentReplacedByFileReportsChangedAndClearsClipboard() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        await f.cut([item])
        try FileManager.default.removeItem(at: f.source)
        try Data("parent is now a file".utf8).write(to: f.source)
        await f.paste()
        #expect(f.warnings.first?.contains("notes.txt: Changed since cut") == true)
        #expect(f.service.pendingCut == nil)
        #expect(f.board.types?.contains(PendingCut.markerType) != true)
        #expect(f.board.types?.contains(PendingCut.sourceType) != true)
        #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("notes.txt").path))
    }
}


extension PasteActionServiceTests {
    @Test func sourceAncestorSwapCannotSubstituteAnotherItemAtRename() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file("Résumé 日本語 notes.txt")
        let expected = try f.operations.fileIdentity(of: item)
        let expectedDestination = try f.operations.fileIdentity(of: f.destination)
        let parked = f.root.appendingPathComponent("parked-source")
        let replacement = f.root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let impostor = replacement.appendingPathComponent(item.lastPathComponent)
        try Data("impostor".utf8).write(to: impostor)
        let source = f.source
        f.operations.onNextRename {
            try FileManager.default.moveItem(at: source, to: parked)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: replacement)
        }
        let operations = f.operations
        let to = f.destination.appendingPathComponent(item.lastPathComponent)
        try await Task.detached {
            try operations.coordinatedExclusiveMove(from: item, to: to, expected: expected,
                expectedDestination: expectedDestination, timeout: 30)
        }.value
        #expect(try Data(contentsOf: to) == Data("original".utf8))
        #expect(try operations.fileIdentity(of: to) == expected)
        #expect(try Data(contentsOf: impostor) == Data("impostor".utf8))
        #expect(!FileManager.default.fileExists(atPath: parked.appendingPathComponent(item.lastPathComponent).path))
    }
}


extension PasteActionServiceTests {
    @Test func descriptorPathRereadAloneRefusesRelocationDuringClassification() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let elsewhere = f.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let operations = f.operations
        operations.onNextDestinationClassification { operations.reportDescriptorPath(elsewhere) }
        let expected = try operations.fileIdentity(of: item)
        let expectedDestination = try operations.fileIdentity(of: f.destination)
        let to = f.destination.appendingPathComponent("notes.txt")
        let refused = await Task.detached {
            do {
                try operations.coordinatedExclusiveMove(from: item, to: to, expected: expected,
                    expectedDestination: expectedDestination, timeout: 30)
                return false
            } catch PasteMoveError.destinationChanged { return true }
            catch { return false }
        }.value
        #expect(refused)
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(!FileManager.default.fileExists(atPath: to.path))
        #expect(operations.renameCalls.isEmpty)
    }

    @Test func coordinatedSameParentCheckAloneRefusesNumberingTheSource() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let operations = f.operations
        let expected = try operations.fileIdentity(of: item)
        let expectedDestination = try operations.fileIdentity(of: f.source)
        let to = f.source.appendingPathComponent("notes 2.txt")
        // Exercise the coordinated guard directly: batch preflight's no-op
        // must not mask a removed in-accessor same-parent check.
        let refused = await Task.detached {
            do {
                try operations.coordinatedExclusiveMove(from: item, to: to, expected: expected,
                    expectedDestination: expectedDestination, timeout: 30)
                return false
            } catch PasteMoveError.destinationChanged { return true }
            catch { return false }
        }.value
        #expect(refused)
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(!FileManager.default.fileExists(atPath: to.path))
        #expect(operations.renameCalls.isEmpty)
    }
}

extension PasteActionServiceTests {
    @Test(arguments: [false, true])
    func symlinkReachedDirectoryCanBePinnedAndMoved(_ destinationSide: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let link = f.root.appendingPathComponent("tmp-link")
        let real = destinationSide ? f.destination : f.source
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // Exercise the same directory-open seam used inside coordination. Unlike
        // Foundation's normalisation, this keeps the symlink as the final component.
        let descriptor = try f.operations.openMoveDirectory(link)
        defer { f.operations.closeMoveDirectory(descriptor) }
        #expect(try f.operations.directoryIdentity(descriptor) == f.operations.fileIdentity(of: real))
        let item = try f.file()
        let source = destinationSide ? item : link.appendingPathComponent(item.lastPathComponent)
        await f.cut([source]); await f.paste(destinationSide ? link : f.destination)
        #expect(f.warnings.isEmpty)
        #expect(try Data(contentsOf: f.destination.appendingPathComponent(item.lastPathComponent)) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(f.leaser.balance == 0)
    }

    @Test(arguments: [false, true])
    func privateTmpRootCanBeSourceOrDestination(_ destinationSide: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        // Create only a unique file in the existing directory; never chmod or
        // remove the system directory. Both possible file locations are cleaned.
        let name = "RClick-private-tmp-\(UUID()).txt"
        let tmpItem = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: tmpItem) }
        let item = destinationSide ? try f.file(name) : tmpItem
        if !destinationSide { try Data("original".utf8).write(to: item) }
        await f.cut([item])
        await f.paste(destinationSide ? tmpItem.deletingLastPathComponent() : f.destination)
        let moved = destinationSide ? tmpItem : f.destination.appendingPathComponent(name)
        #expect(f.warnings.isEmpty)
        #expect(try Data(contentsOf: moved) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(f.service.pendingCut == nil)
        #expect(f.leaser.balance == 0)
    }
}


extension PasteActionServiceTests {
    @Test func privateTmpSameFolderPasteRemainsANoOp() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = URL(fileURLWithPath: "/private/tmp/RClick-noop-\(UUID()).txt")
        try Data("original".utf8).write(to: item)
        defer { try? FileManager.default.removeItem(at: item) }
        await f.cut([item])
        let pending = f.service.pendingCut
        let generation = f.board.changeCount
        await f.paste(item.deletingLastPathComponent())
        #expect(f.warnings.isEmpty)
        #expect(try Data(contentsOf: item) == Data("original".utf8))
        #expect(f.service.pendingCut?.paths == pending?.paths)
        #expect(f.service.pendingCut?.changeCount == pending?.changeCount)
        #expect(f.board.changeCount == generation)
        #expect(f.journal.load() == nil)
    }
}


extension PasteActionServiceTests {
    @Test(arguments: [POSIXErrorCode.ENOENT, .ENOTDIR, .ELOOP])
    func failedSourceParentOpenReportsChanged(_ code: POSIXErrorCode) async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let operations = f.operations
        let expected = try operations.fileIdentity(of: item)
        let expectedDestination = try operations.fileIdentity(of: f.destination)
        let to = f.destination.appendingPathComponent(item.lastPathComponent)
        operations.denyDirectoryOpen(item.deletingLastPathComponent(), error: code)
        // Check the engine result directly: ActionService's later vanished-item
        // probe must not mask a missing source-parent error translation.
        let changed = await Task.detached {
            do {
                try operations.coordinatedExclusiveMove(from: item, to: to, expected: expected,
                    expectedDestination: expectedDestination, timeout: 30)
                return false
            } catch PasteMoveError.changed { return true }
            catch { return false }
        }.value
        #expect(changed)
        #expect(try Data(contentsOf: item) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: to.path))
        #expect(operations.renameCalls.isEmpty)
    }
}
