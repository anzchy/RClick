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
}
