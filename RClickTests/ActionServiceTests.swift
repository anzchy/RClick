//
//  ActionServiceTests.swift
//  RClickTests
//
//  ActionService 单测：用 mock 的 PermissionProviding / ActionStateProviding /
//  DeleteConfirmationProviding 验证授权取消、确认取消与授权→确认顺序。
//

import AppKit
import Foundation
import SwiftData
import Synchronization
import Testing
@testable import RClick

@MainActor
final class ActionServiceTests {

    /// Shared ordered log so permission and confirmation mocks can record sequence.
    @MainActor
    private final class CallLog {
        var steps: [String] = []
    }

    @MainActor
    private final class MockPermission: PermissionProviding {
        var hasAccessResult = false
        /// 模拟授权面板已把目录写进 BookmarkManager 的那部分目录
        var authorizedDirs: Set<String> = []
        var promptResult: URL?
        var saveCalls: [URL] = []
        var promptCalls: [URL] = []
        var callLog: CallLog?

        func hasAccess(to url: URL) -> Bool {
            hasAccessResult || authorizedDirs.contains(url.resolvingSymlinksInPath().path)
        }
        func promptForPermission(for url: URL) async -> URL? {
            promptCalls.append(url)
            callLog?.steps.append("permission")
            if let granted = promptResult {          // 对齐 saveBookmark 的副作用
                authorizedDirs.insert(granted.resolvingSymlinksInPath().path)
            }
            return promptResult
        }
        func saveBookmark(for url: URL) { saveCalls.append(url) }
    }

    @MainActor
    private final class MockConfirmation: DeleteConfirmationProviding {
        var result = true
        var confirmCalls: [[String]] = []
        var callLog: CallLog?

        func confirmPermanentDelete(paths: [String]) -> Bool {
            confirmCalls.append(paths)
            callLog?.steps.append("confirmation")
            return result
        }
    }

    @MainActor
    private final class MockState: ActionStateProviding {
        var apps: [OpenWithApp] = []
        var actions: [RCAction] = []
        var newFiles: [NewFile] = []
        var cdirs: [CommonDir] = []
        var showCommonDirs = false

        func getAppItem(rid: String) -> OpenWithApp? { apps.first { $0.id == rid } }
        func getActionItem(rid: String) -> RCAction? { nil }
        func getFileType(rid: String) -> NewFile? { nil }
    }

    @Test func openAppSendsTheRawSelectedPercentPathToWorkspace() async throws {
        let (dir, _) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("100%41.txt")
        let other = dir.appendingPathComponent("100A.txt")
        try Data("selected".utf8).write(to: raw)
        try Data("other".utf8).write(to: other)
        let state = MockState()
        var app = OpenWithApp(id: "editor", appURL: dir.appendingPathComponent("Editor.app"))
        app.opensContainingDir = false
        state.apps = [app]
        let permission = MockPermission(); permission.hasAccessResult = true
        var opened: [URL] = []
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(),
            openApplication: { urls, _, _, _ in opened += urls })
        await service.openApp(rid: "editor", target: [raw.path, raw.absoluteString])
        #expect(opened == [raw, raw])
        #expect(try Data(contentsOf: raw) == Data("selected".utf8))
        #expect(try Data(contentsOf: other) == Data("other".utf8))
    }

    private func makeTempFile() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("dummy.txt")
        try Data("x".utf8).write(to: file)
        return (dir, file)
    }

    private func percentSiblings() throws -> (root: URL, selected: URL, sibling: URL, marker: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rclick-percent-\(UUID().uuidString)")
        let selected = root.appendingPathComponent("%2544ocuments")
        let sibling = root.appendingPathComponent("%44ocuments")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let marker = sibling.appendingPathComponent("marker.txt")
        try Data("keep".utf8).write(to: marker)
        return (root, selected, sibling, marker)
    }

    @Test func deletePreservesRawPercentSelection() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)
        let result = await service.deleteFoldorFile([f.selected.path], "ctx-items")
        #expect(!FileManager.default.fileExists(atPath: f.selected.path))
        #expect(FileManager.default.fileExists(atPath: f.sibling.path))
        #expect(FileManager.default.fileExists(atPath: f.marker.path))
        #expect(result.completed == [f.selected.path])
        #expect(confirmation.confirmCalls == [[f.selected.path]])
    }

    @Test func hideItemsPreserveRawPercentSelection() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let permission = MockPermission()
        permission.hasAccessResult = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        await service.hideFilesAndDirs([f.selected.path], "ctx-items")
        #expect(try f.selected.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        #expect(try f.sibling.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(FileManager.default.fileExists(atPath: f.marker.path))
    }

    @Test func hideContentsPreserveRawPercentContainer() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let permission = MockPermission()
        permission.hasAccessResult = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        let selectedChild = f.selected.appendingPathComponent("child.txt")
        try Data().write(to: selectedChild)
        await service.hideFilesAndDirs([f.selected.path], "ctx-container")
        #expect(try selectedChild.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        #expect(try f.marker.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
    }

    @Test func unhidePreservesRawPercentContainer() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let permission = MockPermission()
        permission.hasAccessResult = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        var selectedChild = f.selected.appendingPathComponent("child.txt")
        try Data().write(to: selectedChild)
        var marker = f.marker
        var hidden = URLResourceValues()
        hidden.isHidden = true
        try selectedChild.setResourceValues(hidden)
        try marker.setResourceValues(hidden)
        await service.unhideFilesAndDirs([f.selected.path], "ctx-container")
        #expect(try selectedChild.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(try f.marker.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
    }

    @Test func airDropRequestsAccessForRawPercentSelection() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let selectedFile = f.selected.appendingPathComponent("share.txt")
        let siblingFile = f.sibling.appendingPathComponent("share.txt")
        try Data().write(to: selectedFile)
        try Data().write(to: siblingFile)
        let permission = MockPermission()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        // Refuse permission so the test never starts a real AirDrop session.
        await service.showAirDrop([selectedFile.path], "ctx-items")
        #expect(permission.promptCalls.map(\.path) == [f.selected.path])
    }

    @Test func commonDirectoryRequestsAccessForRawPercentPath() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let permission = MockPermission()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        // Refuse permission so the test never opens Finder.
        await service.openCommonDirs(target: [f.selected.path])
        #expect(permission.promptCalls.map(\.path) == [f.selected.path])
    }

    @Test func newFilePreservesRawPercentTarget() async throws {
        let f = try percentSiblings()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let permission = MockPermission()
        permission.hasAccessResult = true
        var revealed: [URL] = []
        let service = ActionService(
            state: MockState(), permission: permission, confirmation: MockConfirmation(),
            revealNewFile: { revealed.append($0) }
        )
        let existing = f.selected.appendingPathComponent(AppLocalization.localized("Untitled"))
        try Data("keep existing".utf8).write(to: existing)
        await service.createFile(rid: NewFileMenuItem.customFileId, target: [f.selected.path])
        let created = f.selected.appendingPathComponent(AppLocalization.localized("Untitled") + "1")
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep existing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.sibling.path) == ["marker.txt"])
        #expect(revealed == [created])
    }

    @Test func deleteAcceptsSpacesAndCJK() async throws {
        let (dir, _) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = dir.appendingPathComponent("Space 中文.txt")
        try Data("delete me".utf8).write(to: selected)
        let permission = MockPermission()
        permission.hasAccessResult = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        await service.deleteFoldorFile([selected.path], "ctx-items")
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dummy.txt").path))
    }

    @Test(arguments: ["Space 中文", "Literal%41", "Literal%2544"])
    func commonDirectoryPersistencePreservesRawTargets(name: String) async throws {
        let (root, _) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fresh = CommonDir(id: "round-trip", name: name, url: directory, icon: "folder")
        let persisted = CommonDirEntity(from: fresh)
        #expect(persisted.path.path == directory.path)
        let reloaded = CommonDir(id: persisted.id, name: persisted.name, url: persisted.path, icon: persisted.icon)
        let permission = MockPermission()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        // Match MenuService's raw URL.path payload; deny access to avoid opening Finder.
        await service.openCommonDirs(target: [fresh.url.path])
        await service.openCommonDirs(target: [reloaded.url.path])
        #expect(permission.promptCalls.map(\.path) == [directory.path, directory.path])
    }

    @Test func deleteIsSkippedWhenAuthorizationIsCancelled() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = nil
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.isEmpty)
    }

    @Test func deleteProceedsWhenAuthorizationGranted() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = file.deletingLastPathComponent()
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls == [[file.path]])
    }

    @Test func deleteIsSkippedWhenUserCancelsConfirmation() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        confirmation.result = false
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.count == 1)
        #expect(confirmation.confirmCalls[0] == [file.path])
    }

    @Test func deleteProceedsWhenUserConfirms() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        confirmation.result = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.count == 1)
    }

    @Test func optionClickSkipsConfirmation() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items", optionKeyPressed: true)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.isEmpty)
    }

    @Test func authorizationIsRequestedBeforeConfirmation() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = CallLog()
        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = file.deletingLastPathComponent()
        permission.callLog = log
        let confirmation = MockConfirmation()
        confirmation.result = true
        confirmation.callLog = log
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(log.steps == ["permission", "confirmation"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.count == 1)
        #expect(confirmation.confirmCalls[0] == [file.path])
    }


    @Test func deleteIsSkippedWhenPromptGrantsUnrelatedDirectory() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-unrelated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = unrelated   // 面板返回了无关目录 → 目标目录仍未授权
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.isEmpty)
    }

    @Test func confirmationOnlySeesAuthorizedPaths() async throws {
        let (dirA, fileA) = try makeTempFile()
        let (dirB, fileB) = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let permission = MockPermission()
        permission.authorizedDirs = [dirA.resolvingSymlinksInPath().path]
        permission.promptResult = nil          // B 的授权被取消 → B 在确认之前出局
        let confirmation = MockConfirmation()  // result 默认 true
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([fileA.path, fileB.path], "ctx-items")

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))
        #expect(permission.promptCalls.count == 1)          // 非死字段：只为 B 弹了一次
        #expect(confirmation.confirmCalls == [[fileA.path]]) // 确认框只拿到已授权子集
    }

    @Test func appEntityPersistsOpensNewInstance() throws {
        let container = try ModelContainer(
            for: AppEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        var app = OpenWithApp(appURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        app.opensNewInstance = true
        context.insert(AppEntity(from: app, sortOrder: 0))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AppEntity>())
        #expect(fetched.first?.opensNewInstance == true)
    }

    @Test func fileTemplateSurvivesSaveAndReload() throws {
        let container = try ModelContainer(
            for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self, CommonDirEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = ConfigService(modelContext: container.mainContext)
        var file = NewFile(ext: ".txt", name: "Template", idx: 0, id: "stable-template-id")
        file.template = URL(fileURLWithPath: "/tmp/template with spaces.txt")
        file.openApp = URL(fileURLWithPath: "/Applications/TextEdit.app")
        try service.save(AppConfigData(newFiles: [file]))

        for _ in 0..<2 {
            let loaded = try #require(service.load().newFiles.first)
            #expect(loaded.id == file.id)
            #expect(loaded.template == file.template)
            #expect(loaded.openApp == file.openApp)
            try service.save(AppConfigData(newFiles: [loaded]))
        }
    }

    // MARK: - Injected file operations (#13)

    @Test func injectedRemoveFailureReachesTheDeleteResult() async throws {
        let (dirA, fileA) = try makeTempFile()
        let (dirB, fileB) = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        let fileOperations = FaultInjectingFileOperations()
        fileOperations.failRemoving(fileA.path)   // 原件无法删除
        let service = ActionService(
            state: MockState(), permission: permission, confirmation: confirmation,
            fileOperations: fileOperations
        )

        let result = await service.deleteFoldorFile([fileA.path, fileB.path], "ctx-items")

        #expect(fileOperations.removeCalls == [fileA.path, fileB.path])
        #expect(result.failures.map(\.path) == [fileA.path])
        #expect(result.failures.first?.error as? FaultInjectingFileOperations.InjectedFault
                == .init(operation: "remove", path: fileA.path))
        #expect(result.completed == [fileB.path])
        #expect(FileManager.default.fileExists(atPath: fileA.path))
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
    }

    // MARK: - Injected pasteboard (#13)

    @Test func copyPathAndFileNameWriteToTheInjectedPasteboard() {
        let pasteboard = NSPasteboard(name: .init("RClickTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let service = ActionService(
            state: MockState(), permission: MockPermission(), confirmation: MockConfirmation(),
            pasteboard: pasteboard
        )

        service.copyPath(["/tmp/a.txt", "/tmp/b.txt"])
        #expect(pasteboard.string(forType: .string) == "/tmp/a.txt\n/tmp/b.txt")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.pasteboardItems?.first?.types == [.string])

        service.copyFileName(["/tmp/a.txt", "/tmp/folder/b.md"])
        #expect(pasteboard.string(forType: .string) == "a.txt\nb.md")
    }


    // MARK: - Access held through the background removal (#13, fix r1 M1)

    /// 沙盒访问的模型：每个目录一个计数，BookmarkManager 的授权与操作租约各占一份。
    nonisolated private final class FakeSandbox: Sendable {
        private let counts = Mutex([String: Int]())

        func open(_ dir: URL) { counts.withLock { $0[dir.path, default: 0] += 1 } }
        func close(_ dir: URL) { counts.withLock { $0[dir.path, default: 0] -= 1 } }
        func openCount(_ dir: URL) -> Int { counts.withLock { $0[dir.path, default: 0] } }
        func canWrite(in dir: URL) -> Bool { openCount(dir) > 0 }
    }

    /// 租约替身：每个目录在沙盒里多开一份访问，end() 时关掉。
    @MainActor
    private final class FakeLeaser: ScopedAccessLeasing {
        let sandbox: FakeSandbox
        var begun: [[URL]] = []
        init(sandbox: FakeSandbox) { self.sandbox = sandbox }

        func beginAccess(covering directories: [URL]) -> ScopedAccessLease {
            begun.append(directories)
            let dirs = Array(Set(directories.map(\.standardizedFileURL)))
            let sandbox = self.sandbox
            dirs.forEach(sandbox.open)
            return ScopedAccessLease(directories: dirs) { dirs.forEach(sandbox.close) }
        }
    }

    /// 只在沙盒里有访问时才删得掉；可以在删某个路径之前停住，等测试放行。
    nonisolated private final class SandboxedFileOperations: FileOperations {
        private let base = SystemFileOperations()
        private let sandbox: FakeSandbox
        private let pauseBefore: String
        private let paused = Mutex(false)
        private let resume = DispatchSemaphore(value: 0)

        init(sandbox: FakeSandbox, pauseBefore path: String) {
            self.sandbox = sandbox
            self.pauseBefore = path
        }

        var isPaused: Bool { paused.withLock { $0 } }
        func proceed() { resume.signal() }

        func removeItem(at url: URL) throws {
            if url.path == pauseBefore {
                paused.withLock { $0 = true }
                resume.wait()
            }
            guard sandbox.canWrite(in: url.deletingLastPathComponent().standardizedFileURL) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            try base.removeItem(at: url)
        }

        func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
        func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
        func volumeIdentity(of url: URL) throws -> VolumeIdentity { try base.volumeIdentity(of: url) }
        func fileIdentity(of url: URL) throws -> FileIdentity { try base.fileIdentity(of: url) }
        func isWritable(_ url: URL) -> Bool { base.isWritable(url) }
        func coordinatedTransfer(_ kind: FileTransferKind, from source: URL, to destination: URL) throws {
            try base.coordinatedTransfer(kind, from: source, to: destination)
        }
    }

    @Test func revokingTheGrantMidBatchDoesNotStopTheRemainingRemovals() async throws {
        let (dir, fileA) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileB = dir.appendingPathComponent("second.txt")
        try Data("y".utf8).write(to: fileB)
        let grantedDir = dir.standardizedFileURL

        let sandbox = FakeSandbox()
        sandbox.open(grantedDir)                       // BookmarkManager 恢复/保存书签时开的那一份
        let permission = MockPermission()
        permission.hasAccessResult = true
        let leaser = FakeLeaser(sandbox: sandbox)
        let fileOperations = SandboxedFileOperations(sandbox: sandbox, pauseBefore: fileB.path)
        defer { fileOperations.proceed() }
        let service = ActionService(
            state: MockState(), permission: permission, confirmation: MockConfirmation(),
            fileOperations: fileOperations, accessLeaser: leaser
        )

        let deletion = Task {
            await service.deleteFoldorFile([fileA.path, fileB.path], "ctx-items", optionKeyPressed: true)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !fileOperations.isPaused, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(fileOperations.isPaused)          // 批次停在 A 删完、B 之前

        sandbox.close(grantedDir)                      // 设置页撤销授权：BookmarkManager.removeDirectory → stopAccessing
        fileOperations.proceed()
        let result = await deletion.value

        #expect(result.failures.map(\.path) == [])
        #expect(result.completed == [fileA.path, fileB.path])
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
        #expect(leaser.begun.count == 1)
        #expect(sandbox.openCount(grantedDir) == 0)    // 租约在批次结束后归还
    }
}


extension ActionServiceTests {
    nonisolated private final class CapturedActionLog: Sendable {
        let lines = Mutex<[String]>([])
        func record(_ line: String) { lines.withLock { $0.append(line) } }
    }

    @Test(arguments: ["delete"])
    func fileActionLogsExcludeSelection(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SECRET-folder-%41-ü-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("SECRET-name-%41-ü.txt")
        try Data("keep".utf8).write(to: file)
        let permission = MockPermission()
        let recorder = CapturedActionLog()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(),
            logSink: { recorder.record($0) })
        switch action {
        case "delete":
            await service.deleteFoldorFile([file.path], "ctx-items")
            permission.hasAccessResult = true
            await service.deleteFoldorFile([file.path], "ctx-items")
            await service.deleteFoldorFile([file.path], "ctx-items") // missing-file error embeds path
        default: Issue.record("Unknown action")
        }
        let lines = recorder.lines.withLock { $0 }
        #expect(!lines.isEmpty, "A disconnected sink must fail")
        #expect(lines.contains { $0.contains("count") }, "Counts must remain observable")
        for secret in [file.path, file.lastPathComponent, root.lastPathComponent, "%41", "SECRET-"] {
            #expect(!lines.contains { $0.contains(secret) }, "File-derived text reached the log sink")
        }
    }
}
