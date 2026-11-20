import Foundation
import Testing
@testable import RClick

@MainActor
struct NewFileCreationTests {
    final class State: ActionStateProviding {
        var apps: [OpenWithApp] = []
        var actions: [RCAction] = []
        var newFiles: [NewFile] = []
        var cdirs: [CommonDir] = []
        var showCommonDirs = false
        func getAppItem(rid: String) -> OpenWithApp? { nil }
        func getActionItem(rid: String) -> RCAction? { nil }
        func getFileType(rid: String) -> NewFile? { newFiles.first { $0.id == rid } }
    }
    final class Permission: PermissionProviding {
        func hasAccess(to url: URL) -> Bool { true }
        func promptForPermission(for url: URL) async -> URL? { url }
        func saveBookmark(for url: URL) {}
    }
    final class Confirmation: DeleteConfirmationProviding {
        func confirmPermanentDelete(paths: [String]) -> Bool { false }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func missingRequiredTemplateCreatesNothing() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = State()
        state.newFiles = [NewFile(ext: ".pages", name: "Missing", idx: 0, id: "missing")]
        var revealed: [URL] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(),
            revealNewFile: { revealed.append($0) })
        var warnings: [String] = []
        await service.createFile(rid: "missing", target: [dir.path], templateWarning: { warnings.append($0) })
        #expect(warnings.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(revealed.isEmpty)
    }
    @Test func customTypesWithoutTemplatesCreateEmptyFilesAndOfficeTypesUseBundle() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let python = NewFile(ext: ".py", name: "Python", idx: 0)
        let office = NewFile(ext: ".docx", name: "Custom DOCX", idx: 1)
        let state = State()
        state.newFiles = [python, office]
        var revealed: [URL] = []
        var warnings: [String] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(),
            revealNewFile: { revealed.append($0) })
        await service.createFile(rid: python.id, target: [dir.path], templateWarning: { warnings.append($0) })
        #expect(revealed.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        if let file = revealed.first { #expect(try Data(contentsOf: file).isEmpty) }
        await service.createFile(rid: office.id, target: [dir.path], templateWarning: { warnings.append($0) })
        let bundled = try #require(Bundle.main.url(forResource: "template", withExtension: "docx"))
        let copy = try #require(revealed.first { $0.pathExtension == "docx" })
        #expect(try Data(contentsOf: copy) == Data(contentsOf: bundled))
        state.newFiles[1].template = dir.appendingPathComponent("missing.docx")
        await service.createFile(rid: office.id, target: [dir.path], templateWarning: { warnings.append($0) })
        #expect(revealed.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        #expect(warnings.count == 1)
    }

    @Test func officeCopiesMatchBundledBytesWithoutOverwriting() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = State()
        state.newFiles = [.docx, .pptx, .xlsx]
        var revealed: [URL] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(),
            revealNewFile: { revealed.append($0) })
        for ext in ["docx", "pptx", "xlsx"] {
            let template = try #require(Bundle.main.url(forResource: "template", withExtension: ext))
            let expected = try Data(contentsOf: template)
            await service.createFile(rid: ext, target: [dir.path], templateWarning: { _ in Issue.record("Unexpected template warning") })
            await service.createFile(rid: ext, target: [dir.path], templateWarning: { _ in Issue.record("Unexpected template warning") })
            let copies = revealed.filter { $0.pathExtension == ext }
            #expect(copies.count == 2)
            #expect(Set(copies).count == 2)
            for copy in copies { #expect(try Data(contentsOf: copy) == expected) }
        }
    }

    @Test func userTemplatesWinAndBuiltinTextTypesStayEmpty() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let expected = Data("user supplied template bytes".utf8)
        try expected.write(to: source)
        let state = State()
        state.newFiles = [.docx, NewFile(ext: ".custom", name: "Custom", idx: 0, id: "custom"), .txt, .md, .json]
        state.newFiles[0].template = source
        state.newFiles[1].template = source
        var revealed: [URL] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(),
            revealNewFile: { revealed.append($0) })
        for id in ["docx", "custom", "txt", "md", "json"] {
            await service.createFile(rid: id, target: [dir.path], templateWarning: { _ in Issue.record("Unexpected template warning") })
        }
        #expect(revealed.count == 5)
        #expect(try Data(contentsOf: source) == expected)
        for file in revealed {
            #expect(try Data(contentsOf: file) == (["docx", "custom"].contains(file.pathExtension) ? expected : Data()))
        }
    }

    @Test func directoryTemplatesCopyContentsWithoutOverwriting() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pages")
        let nested = source.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let expected = Data("package content".utf8)
        try expected.write(to: nested.appendingPathComponent("document"))
        var type = NewFile.pages
        type.template = source
        let state = State()
        state.newFiles = [type]
        var revealed: [URL] = []
        var warnings: [String] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(),
            revealNewFile: { revealed.append($0) })
        for _ in 0..<2 {
            await service.createFile(rid: type.id, target: [dir.path], templateWarning: { warnings.append($0) })
        }
        #expect(revealed.count == 2)
        #expect(Set(revealed).count == 2)
        #expect(warnings.isEmpty)
        for copy in revealed {
            #expect(try copy.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
            #expect(try Data(contentsOf: copy.appendingPathComponent("Contents/document")) == expected)
        }
        #expect(try Data(contentsOf: nested.appendingPathComponent("document")) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
    }

    @Test func unavailableOfficeTemplatesWarnOnceAndNeverRevealOrWrite() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty-template")
        try Data().write(to: empty)
        let state = State()
        var revealed: [URL] = []
        var warnings: [String] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(),
            revealNewFile: { revealed.append($0) })
        for type in [NewFile.docx, .pptx, .xlsx] {
            for source in [nil, dir.appendingPathComponent("missing"), empty] as [URL?] {
                var configured = type
                configured.template = source
                state.newFiles = [configured]
                let count = warnings.count
                await service.createFile(rid: type.id, target: [dir.path], templateResource: { _ in nil },
                    templateWarning: { warnings.append($0) })
                #expect(warnings.count == count + 1)
                #expect(warnings.last?.contains(type.displayName) == true)
                #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["empty-template"])
                #expect(revealed.isEmpty)
            }
        }
    }

    @Test func selectedTemplateAndOldClickUseCorrectBytesWhileUnknownAndMissingRefuse() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        try Data("chosen bytes".utf8).write(to: source)
        var file = NewFile.txt
        file.blankEnabled = false
        file.templates = [NewFile.Template(id: "chosen", name: "Letter", path: source.path)]
        let state = State()
        state.newFiles = [file]
        var outputs: [URL] = []
        var warnings: [String] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(), revealNewFile: { outputs.append($0) })
        for selection in ["chosen", nil] as [String?] {
            await service.createFile(rid: "txt", target: [dir.path], templateId: selection, templateWarning: { warnings.append($0) })
        }
        #expect(outputs.count == 2)
        #expect(Set(outputs).count == 2)
        for output in outputs { #expect(try Data(contentsOf: output) == Data("chosen bytes".utf8)) }
        for invalid in ["unknown", NewFile.blankTemplateID] {
            let before = warnings.count
            await service.createFile(rid: "txt", target: [dir.path], templateId: invalid, templateWarning: { warnings.append($0) })
            #expect(warnings.count == before + 1)
            #expect(outputs.count == 2)
        }
        try FileManager.default.removeItem(at: source)
        await service.createFile(rid: "txt", target: [dir.path], templateId: "chosen", templateWarning: { warnings.append($0) })
        #expect(warnings.count == 3)
        #expect(outputs.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        state.newFiles[0].blankEnabled = true
        await service.createFile(rid: "txt", target: [dir.path], templateId: NewFile.blankTemplateID, templateWarning: { warnings.append($0) })
        #expect(outputs.count == 3)
        #expect(try Data(contentsOf: #require(outputs.last)).isEmpty)
        #expect(warnings.count == 3)
    }

    @Test func emptyStoredPathNeverCopiesTheWorkingDirectory() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("cwd")
        let output = dir.appendingPathComponent("output")
        for folder in [source, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("canary".utf8).write(to: source.appendingPathComponent("canary"))
        let state = State()
        var file = NewFile.txt
        file.blankEnabled = false
        file.templates = [.init(id: "empty", name: "Missing", path: "")]
        state.newFiles = [file]
        var warnings: [String] = []
        var revealed: [URL] = []
        let service = ActionService(state: state, permission: Permission(), confirmation: Confirmation(), revealNewFile: { revealed.append($0) })
        // Keep the pre-fix directory-copy behavior confined to tiny disposable input.
        // This actor-isolated create path never awaits a permission prompt.
        let previous = FileManager.default.currentDirectoryPath
        try #require(FileManager.default.changeCurrentDirectoryPath(source.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        await service.createFile(rid: "txt", target: [output.path], templateId: "empty", templateWarning: { warnings.append($0) })
        #expect(warnings.count == 1)
        #expect(revealed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(try Data(contentsOf: source.appendingPathComponent("canary")) == Data("canary".utf8))
    }

}
