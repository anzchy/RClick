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
    @MainActor final class Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let board = NSPasteboard(name: .init("RClickTests-paste-\(UUID())"))
        let permission = Permission()
        let leaser = Leaser()
        let operations = FaultInjectingFileOperations()
        var warnings: [String] = []
        lazy var service = ActionService(state: State(), permission: permission, confirmation: Confirmation(),
            fileOperations: operations, pasteboard: board, accessLeaser: leaser,
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

}
