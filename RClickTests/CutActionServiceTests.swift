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
        func hasAccess(to url: URL) -> Bool { authorized.contains(url.path) }
        func promptForPermission(for url: URL) async -> URL? {
            prompts.append(url)
            guard !replies.isEmpty, replies.removeFirst() else { return nil }
            authorized.insert(url.path)
            return url
        }
        func saveBookmark(for url: URL) {}
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
}
