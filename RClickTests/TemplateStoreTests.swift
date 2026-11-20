import Foundation
import Testing
@testable import RClick

@MainActor
struct TemplateStoreTests {
    @Test func sameNamedImportsNeverAliasOrOverwriteOriginals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a/same.txt")
        let b = dir.appendingPathComponent("b/same.txt")
        for url in [a, b] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let one = try store.importFile(a)
        let two = try store.importFile(b)
        #expect(one.path != two.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(one.path))) == Data("first".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(two.path))) == Data("second".utf8))
        #expect(try Data(contentsOf: a) == Data("first".utf8))
    }
    @Test func cancellingDraftLeavesNoCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.txt")
        try Data("snapshot".utf8).write(to: source)
        let root = dir.appendingPathComponent("Templates")
        let store = TemplateStore(baseURL: root)
        var draft = TemplateDraft(file: .txt)
        try draft.add(source, store: store)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(draft.entries.map(\.name) == ["source.txt"])
    }

    @Test func savedDraftKeepsSnapshotsAndReplacementMetadataThenRemovesOnlyOwnedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("same.txt")
        try Data("first".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        var draft = TemplateDraft(file: .txt)
        try draft.add(source, store: store)
        try Data("second".utf8).write(to: source)
        try draft.add(source, store: store)
        #expect(draft.entries.map(\.name) == ["same.txt", "same.txt 2"])
        let saved = try draft.save(store: store, replacing: [])
        let firstPath = try #require(saved.first?.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: firstPath)) == Data("first".utf8))
        var file = NewFile.txt
        file.templates = saved
        var edit = TemplateDraft(file: file)
        edit.rename(id: saved[0].id, name: "Letter")
        try edit.replace(id: saved[0].id, source: source)
        edit.entries[0].enabled = false
        let replaced = try edit.save(store: store, replacing: saved)
        #expect(replaced.map(\.id) == saved.map(\.id))
        #expect(replaced.map(\.name) == ["Letter", "same.txt 2"])
        #expect(replaced[0].enabled == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(replaced[0].path))) == Data("second".utf8))
        edit.entries = []
        _ = try edit.save(store: store, replacing: replaced + [NewFile.Template(name: "External", path: source.path)])
        for entry in replaced { let path = try #require(entry.path); #expect(!FileManager.default.fileExists(atPath: path)) }
        #expect(try Data(contentsOf: source) == Data("second".utf8))
    }

    @Test func restoreDefaultsDeletesSnapshotsAndRestoresBlankWithoutTouchingSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let entry = try store.importFile(source)
        var file = NewFile.txt
        file.templates = [entry, .init(name: "External", path: source.path)]
        file.blankEnabled = false
        let state = AppState()
        state.newFileTemplateStore = store
        state.newFiles = [file]
        state.sync()
        state.resetFiletypeItems()
        let path = try #require(entry.path)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(state.newFiles.allSatisfy { $0.usesBlank && $0.userTemplates.isEmpty })
        #expect(try Data(contentsOf: source) == Data("original".utf8))
    }

    @Test func importedLegacyBackupTemplateCanBeReplacedInTheSheet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: source)
        let backup = SettingsBackup.FileTemplate(id: "custom", ext: ".txt", name: "Custom", enabled: true,
            idx: 0, icon: "doc", openAppPath: nil, templatePath: source.path)
        let file = backup.toModel()
        var draft = TemplateDraft(file: file)
        let id = try #require(draft.entries.first?.id)
        try Data("replacement".utf8).write(to: source)
        try draft.replace(id: id, source: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let saved = try? draft.save(store: store, replacing: file.userTemplates)
        #expect(saved?.first?.id == id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(saved?.first?.path))) == Data("replacement".utf8))
        #expect(try Data(contentsOf: source) == Data("replacement".utf8))
    }

    @Test func removingAnEntryKeepsLegacyCopyUsedByAnotherType() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        try FileManager.default.createDirectory(at: store.baseURL, withIntermediateDirectories: true)
        let legacy = store.baseURL.appendingPathComponent("shared.txt")
        try Data("shared bytes".utf8).write(to: legacy)
        let entry = NewFile.Template(name: "Shared", path: legacy.path)
        let emptyDraft = TemplateDraft(file: .txt)
        _ = try emptyDraft.save(store: store, replacing: [entry], retaining: [entry])
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: legacy) == Data("shared bytes".utf8))
    }

    @Test func hostedStandardStoreNeverUsesApplicationSupport() {
        #expect(TestHost.isActive)
        let root = TemplateStore.standard.baseURL.standardizedFileURL.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(root.hasPrefix(temp + "/"))
        #expect(!root.contains("/Library/Application Support/"))
        #expect(TemplateStore.standard.baseURL == TemplateStore.standard.baseURL)
    }

    @Test func legacyDirectoryPathCannotAdoptOrRemoveAnotherEntriesSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.txt")
        try Data("owned bytes".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let victim = try store.importFile(source)
        let victimURL = URL(fileURLWithPath: try #require(victim.path))
        let directory = victimURL.deletingLastPathComponent()
        #expect(!store.owns(directory))
        let backup = SettingsBackup.FileTemplate(id: "other", ext: ".txt", name: "Other", enabled: true,
            idx: 0, icon: "doc", openAppPath: nil, templatePath: directory.path)
        let imported = backup.toModel(templateStore: store)
        #expect(imported.userTemplates.first?.isMissing == true)
        try store.remove(NewFile.Template(name: "Invalid", path: directory.path))
        #expect(FileManager.default.fileExists(atPath: victimURL.path))
        // A different entry must not be able to delete the victim's actual file either.
        try store.remove(NewFile.Template(name: "Wrong ID", path: victimURL.path))
        #expect(FileManager.default.fileExists(atPath: victimURL.path))
        let legacy = store.baseURL.appendingPathComponent("legacy.txt")
        try Data("legacy".utf8).write(to: legacy)
        #expect(store.owns(legacy))
        #expect(!store.owns(store.baseURL))
        #expect(!store.owns(source))
        #expect(!store.owns(store.baseURL.appendingPathComponent("../source.txt")))
        let link = store.baseURL.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        #expect(!store.owns(link.appendingPathComponent("source.txt")))
        try store.remove(victim)
        #expect(!FileManager.default.fileExists(atPath: victimURL.path))
        #expect(try Data(contentsOf: source) == Data("owned bytes".utf8))
    }

}
