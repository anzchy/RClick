import AppKit
import Synchronization
import Testing
@testable import RClick

@MainActor
struct CutActionServiceTests {
    private final class MockState: ActionStateProviding {
        var apps: [OpenWithApp] = []
        var actions: [RCAction] = []
        var newFiles: [NewFile] = []
        var cdirs: [CommonDir] = []
        var showCommonDirs = false
        init() { var cut = RCAction.cut; cut.enabled = true; actions = [cut] }
        func getAppItem(rid: String) -> OpenWithApp? { nil }
        func getActionItem(rid: String) -> RCAction? { actions.first { $0.id == rid } }
        func getFileType(rid: String) -> NewFile? { nil }
    }

    private final class MockPermission: PermissionProviding {
        var authorized: Set<String> = []
        var replies: [Bool] = []
        var prompts: [URL] = []
        var holdNextPrompt = false
        var heldPrompt: CheckedContinuation<URL?, Never>?
        var onPromptStarted: (() -> Void)?
        func hasAccess(to url: URL) -> Bool { authorized.contains(url.path) }
        func promptForPermission(for url: URL) async -> URL? {
            prompts.append(url)
            if holdNextPrompt {
                holdNextPrompt = false
                return await withCheckedContinuation { continuation in
                    heldPrompt = continuation
                    onPromptStarted?()
                }
            }
            guard !replies.isEmpty, replies.removeFirst() else { return nil }
            authorized.insert(url.path)
            return url
        }
        func saveBookmark(for url: URL) {}
        func cancelHeldPrompt() {
            heldPrompt?.resume(returning: nil)
            heldPrompt = nil
        }
    }

    private final class MockConfirmation: DeleteConfirmationProviding {
        func confirmPermanentDelete(paths: [String]) -> Bool { false }
    }

    nonisolated private final class LeaseCounter: Sendable {
        let ends = Mutex(0)
    }

    private final class TrackingLease: ScopedAccessLeasing {
        var parents: [[URL]] = []
        private let counter = LeaseCounter()
        var ended: Int { counter.ends.withLock { $0 } }
        func beginAccess(covering directories: [URL]) -> ScopedAccessLease {
            parents.append(directories)
            let counter = self.counter
            return ScopedAccessLease(directories: directories) { counter.ends.withLock { $0 += 1 } }
        }
    }

    private func makeFiles() throws -> (URL, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RClick-cut-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = [root.appendingPathComponent("a%20b.txt"), root.appendingPathComponent("b.txt")]
        for file in files { try Data("unchanged".utf8).write(to: file) }
        return (root, files)
    }

    @Test func cutRecordsSelectionIdentityAndChangeCountWithoutChangingFiles() async throws {
        let (root, files) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        let permission = MockPermission()
        permission.authorized = [root.path]
        let lease = TrackingLease()
        let operations = FaultInjectingFileOperations()
        let identities = try files.map { try operations.fileIdentity(of: $0) }
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(),
                                    fileOperations: operations, pasteboard: board, accessLeaser: lease)
        await service.actionHandler(rid: "cut", target: files.map(\.path), trigger: "ctx-items")
        let pending = try #require(service.pendingCut)
        #expect(pending.paths == files.map(\.path))
        #expect(pending.identities == identities)
        #expect(pending.changeCount == board.changeCount)
        #expect(board.pasteboardItems?.first?.string(forType: .fileURL) == files[0].absoluteString)
        for file in files { #expect(try Data(contentsOf: file) == Data("unchanged".utf8)) }
        #expect(operations.removeCalls.isEmpty)
        #expect(lease.parents == [[root]])
        #expect(lease.ended == 1)
        board.clearContents()
        board.setString("new copy", forType: .string)
        #expect(service.pendingCut == nil)
    }
    @Test func protectedSourceRefusesTheWholeCutAndWarnsWithoutTouchingClipboard() async throws {
        let (root, files) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let before = board.changeCount
        let permission = MockPermission()
        permission.authorized = [root.path, "/"]
        let lease = TrackingLease()
        var warnings: [String] = []
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(),
                                    pasteboard: board, accessLeaser: lease, cutWarning: { warnings.append($0) })
        await service.actionHandler(rid: "cut", target: [files[0].path, "/System"], trigger: "ctx-items")
        #expect(service.pendingCut == nil)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "keep")
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("/System") == true)
        #expect(permission.prompts.isEmpty)
        #expect(lease.parents.isEmpty)
        #expect(try Data(contentsOf: files[0]) == Data("unchanged".utf8))
    }

    @Test func cancelledParentPermissionPreservesPreviousCutAndAllFiles() async throws {
        let (oldRoot, oldFiles) = try makeFiles()
        let (firstRoot, firstFiles) = try makeFiles()
        let (secondRoot, secondFiles) = try makeFiles()
        defer { for root in [oldRoot, firstRoot, secondRoot] { try? FileManager.default.removeItem(at: root) } }
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        let permission = MockPermission()
        permission.authorized = [oldRoot.path]
        let lease = TrackingLease()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(),
                                    pasteboard: board, accessLeaser: lease)
        await service.actionHandler(rid: "cut", target: [oldFiles[0].path], trigger: "ctx-items")
        let old = try #require(service.pendingCut)
        permission.replies = [true, false]
        await service.actionHandler(rid: "cut", target: (firstFiles + [secondFiles[0]]).map(\.path), trigger: "ctx-items")
        #expect(permission.prompts == [firstRoot, secondRoot])
        #expect(service.pendingCut?.paths == old.paths)
        #expect(service.pendingCut?.changeCount == old.changeCount)
        #expect(board.changeCount == old.changeCount)
        #expect(lease.parents == [[oldRoot]])
        #expect(lease.ended == 1)
        for file in oldFiles + firstFiles + secondFiles {
            #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
        }
    }

    @Test(arguments: [true, false])
    func readOnlyVolumeOrUnwritableParentWarnsBeforeWritingCut(readOnlyVolume: Bool) async throws {
        let (root, files) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let before = board.changeCount
        let permission = MockPermission()
        permission.replies = [true]
        let lease = TrackingLease()
        let operations = FaultInjectingFileOperations()
        if !readOnlyVolume { operations.reportUnwritable(root) }
        var warnings: [String] = []
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(),
                                    fileOperations: operations, pasteboard: board, accessLeaser: lease,
                                    cutWarning: { warnings.append($0) },
                                    cutVolumeIsReadOnly: { url in readOnlyVolume && url.path == files[0].path })
        await service.actionHandler(rid: "cut", target: [files[0].path], trigger: "ctx-items")
        #expect(permission.prompts == [root])
        #expect(service.pendingCut == nil)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "keep")
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains(files[0].path) == true)
        #expect(lease.ended == 1)
        #expect(try Data(contentsOf: files[0]) == Data("unchanged".utf8))
    }

    @Test(arguments: ["disabled", "container", "empty"])
    func cutRejectsInvalidRequestsBeforeAccessOrClipboardChanges(request: String) async throws {
        let (root, files) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let before = board.changeCount
        let state = MockState()
        if request == "disabled" { state.actions[0].enabled = false }
        let permission = MockPermission()
        permission.authorized = [root.path]
        let lease = TrackingLease()
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(),
                                    pasteboard: board, accessLeaser: lease)
        await service.actionHandler(rid: "cut", target: request == "empty" ? [] : files.map(\.path),
                                    trigger: request == "container" ? "ctx-container" : "ctx-items")
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "keep")
        #expect(service.pendingCut == nil)
        #expect(permission.prompts.isEmpty)
        #expect(lease.parents.isEmpty)
        for file in files { #expect(try Data(contentsOf: file) == Data("unchanged".utf8)) }
    }

    @Test func secondCutWhilePermissionPanelIsOpenDoesNotChangeClipboardOrPendingState() async throws {
        let (firstRoot, firstFiles) = try makeFiles()
        let (secondRoot, secondFiles) = try makeFiles()
        defer { for root in [firstRoot, secondRoot] { try? FileManager.default.removeItem(at: root) } }
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let before = board.changeCount
        let permission = MockPermission()
        permission.authorized = [secondRoot.path]
        permission.holdNextPrompt = true
        let lease = TrackingLease()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(),
                                    pasteboard: board, accessLeaser: lease)
        var first: Task<Void, Never>?
        await withCheckedContinuation { started in
            permission.onPromptStarted = { started.resume() }
            first = Task { await service.actionHandler(rid: "cut", target: firstFiles.map(\.path), trigger: "ctx-items") }
        }
        permission.onPromptStarted = nil
        defer { permission.cancelHeldPrompt() }
        await service.actionHandler(rid: "cut", target: secondFiles.map(\.path), trigger: "ctx-items")
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "keep")
        #expect(service.pendingCut == nil)
        #expect(permission.prompts == [firstRoot])
        #expect(lease.parents.isEmpty)
        permission.cancelHeldPrompt()
        if let first { await first.value }
        #expect(board.changeCount == before)
        #expect(service.pendingCut == nil)
        for file in firstFiles + secondFiles {
            #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
        }
    }

}
