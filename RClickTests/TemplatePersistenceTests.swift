import Foundation
import SwiftData
import Testing
@testable import RClick

@MainActor
struct TemplatePersistenceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
            CommonDirEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func failedPersistenceKeepsReplacedAndRemovedSnapshotsIntact() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("letter.txt")
        try Data("original".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let old = try [store.importFile(source), store.importFile(source)]
        var file = NewFile.txt
        file.templates = old
        let database = try container()
        let context = ModelContext(database)
        try ConfigService(modelContext: context).save(AppConfigData(newFiles: [file]), templateStore: store)
        var draft = TemplateDraft(file: file)
        draft.entries.removeLast()
        try Data("replacement".utf8).write(to: source)
        try draft.replace(id: old[0].id, source: source)
        file.templates = try draft.save(store: store, replacing: old)
        let failing = ConfigService(modelContext: context, persistContext: { throw CocoaError(.fileWriteUnknown) })
        var didFail = false
        do { try failing.save(AppConfigData(newFiles: [file]), templateStore: store) }
        catch { didFail = true }
        #expect(didFail)
        for entry in old {
            let url = URL(fileURLWithPath: try #require(entry.path))
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect((try? Data(contentsOf: url)) == Data("original".utf8))
        }
        let loaded = ConfigService(modelContext: ModelContext(database)).load(templateStore: store)
        #expect(loaded.newFiles.first?.userTemplates == old)
    }

    @Test func failedLoadThenSaveNeverDeletesSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("letter.txt")
        try Data("original".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let entry = try store.importFile(source)
        var file = NewFile.txt
        file.templates = [entry]
        let database = try container()
        let context = ModelContext(database)
        try ConfigService(modelContext: context).save(AppConfigData(newFiles: [file]), templateStore: store)
        var failNextRead = true
        let service = ConfigService(modelContext: context, fetchNewFiles: {
            if failNextRead { failNextRead = false; throw CocoaError(.fileReadUnknown) }
            return try context.fetch(FetchDescriptor<NewFileTypeEntity>())
        })
        let failedLoad = service.load(templateStore: store)
        #expect(failedLoad.newFiles.isEmpty)
        try service.save(failedLoad, templateStore: store)
        #expect(FileManager.default.fileExists(atPath: try #require(entry.path)))
    }
}
