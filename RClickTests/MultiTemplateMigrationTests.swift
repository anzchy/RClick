import Foundation
import SwiftData
import Testing
@testable import RClick

@MainActor
struct MultiTemplateMigrationTests {
    @Test func legacyTemplateDisablesBlankAndPersistsOnce() throws {
        for memory in [true, false] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("Original.txt")
            try Data("original bytes".utf8).write(to: source)
            let config = memory ? ModelConfiguration(isStoredInMemoryOnly: true) :
                ModelConfiguration(url: dir.appendingPathComponent("legacy.sqlite"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: AppEntity.self, ActionEntity.self,
                NewFileTypeEntity.self, CommonDirEntity.self, configurations: config)
            let context = ModelContext(container)
            context.insert(NewFileTypeEntity(id: "custom", fileExtension: ".txt", name: "Custom", templatePath: source.path))
            context.insert(NewFileTypeEntity(id: "txt", fileExtension: ".txt", name: "Text"))
            context.insert(NewFileTypeEntity(id: "missing", fileExtension: ".txt", name: "Missing", templatePath: dir.appendingPathComponent("gone.txt").path))
            try context.save()
            let first = ConfigService(modelContext: context).load().newFiles
            let migrated = try #require(first.first { $0.id == "custom" })
            #expect(migrated.blankEnabled == false)
            #expect(migrated.templates?.map(\.name) == ["Original.txt"])
            #expect(migrated.userTemplates.first?.path == source.path)
            #expect(first.first { $0.id == "txt" }?.blankEnabled == true)
            #expect(first.first { $0.id == "missing" }?.userTemplates.first?.isMissing == true)
            for _ in 0..<2 {
                let again = ConfigService(modelContext: ModelContext(container)).load().newFiles
                #expect(again.first { $0.id == "custom" }?.templates == migrated.templates)
                #expect(again.first { $0.id == "custom" }?.blankEnabled == false)
            }
            #expect(try Data(contentsOf: source) == Data("original bytes".utf8))
        }
    }
    @Test func sheetEditsPersistNamesOrderTogglesAndUserTemplatedBuiltinTypes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("same.pages")
        try Data("snapshot".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        var draft = TemplateDraft(file: .pages)
        draft.blankEnabled = false
        try draft.add(source, store: store)
        try draft.add(source, store: store)
        draft.entries.swapAt(0, 1)
        draft.rename(id: draft.entries[0].id, name: "Letter")
        draft.entries[1].enabled = false
        var file = NewFile.pages
        file.blankEnabled = draft.blankEnabled
        file.templates = try draft.save(store: store, replacing: [])
        let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
            CommonDirEntity.self, configurations: ModelConfiguration(url: dir.appendingPathComponent("edited.sqlite"), cloudKitDatabase: .none))
        let service = ConfigService(modelContext: ModelContext(container))
        try service.save(AppConfigData(newFiles: [file]), templateStore: store)
        let loaded = try #require(service.load().newFiles.first)
        #expect(loaded.userTemplates.map(\.id) == draft.entries.map(\.id))
        #expect(loaded.userTemplates.map(\.name) == ["Letter", "same.pages"])
        #expect(loaded.userTemplates.map(\.enabled) == [true, false])
        #expect(loaded.blankEnabled == false)
    }

    @Test func sqliteStoreWithTheActualOldSchemaUpgradesWithoutLosingTemplate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("old.txt")
        try Data("legacy bytes".utf8).write(to: path)
        let config = ModelConfiguration(url: dir.appendingPathComponent("actual-old.sqlite"), cloudKitDatabase: .none)
        do {
            let old = try ModelContainer(for: AppEntity.self, ActionEntity.self, LegacyFileTypes.NewFileTypeEntity.self,
                CommonDirEntity.self, BookmarkEntity.self, DataVersion.self, configurations: config)
            let context = ModelContext(old)
            context.insert(LegacyFileTypes.NewFileTypeEntity(templatePath: path.path))
            try context.save()
        }
        let current = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
            NewFileTemplateEntity.self, CommonDirEntity.self, BookmarkEntity.self, DataVersion.self, configurations: config)
        let service = ConfigService(modelContext: ModelContext(current))
        let file = try #require(service.load().newFiles.first)
        #expect(file.id == "legacy-custom")
        #expect(file.blankEnabled == false)
        #expect(file.userTemplates.map(\.name) == ["old.txt"])
        #expect(file.userTemplates.first?.path == path.path)
        try service.save(AppConfigData(newFiles: [file]))
        let again = try #require(ConfigService(modelContext: ModelContext(current)).load().newFiles.first)
        #expect(again.userTemplates.map(\.id) == file.userTemplates.map(\.id))
        #expect(try Data(contentsOf: path) == Data("legacy bytes".utf8))
    }

}


/// Literal pre-#49 persisted shape: no relationship and no blank migration marker.
private enum LegacyFileTypes {
    @Model final class NewFileTypeEntity {
        @Attribute(.unique) var id: String
        var fileExtension: String
        var name: String
        var icon: String
        var isEnabled: Bool
        var sortOrder: Int
        var templatePath: String?
        var openAppPath: String?
        var createdAt: Date
        var updatedAt: Date
        init(templatePath: String) {
            id = "legacy-custom"; fileExtension = ".txt"; name = "Legacy"
            icon = "doc"; isEnabled = true; sortOrder = 0
            self.templatePath = templatePath; openAppPath = nil
            createdAt = Date(); updatedAt = Date()
        }
    }
}
