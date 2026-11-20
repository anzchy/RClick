import Foundation
import SwiftData
import Testing
@testable import RClick

@MainActor
struct LegacyTemplateBackupTests {
    @Test func migratedLegacyFileSurvivesSameMacExportImport() throws {
        for insideStore in [true, false] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
            try FileManager.default.createDirectory(at: store.baseURL, withIntermediateDirectories: true)
            let source = (insideStore ? store.baseURL : dir).appendingPathComponent("Letter.txt")
            let bytes = Data("adopted legacy bytes".utf8)
            try bytes.write(to: source)
            let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
                CommonDirEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            context.insert(NewFileTypeEntity(id: "txt", fileExtension: ".txt", name: "Text", templatePath: source.path))
            try context.save()
            let service = ConfigService(modelContext: context)
            let migrated = try #require(service.load(templateStore: store).newFiles.first)
            #expect(migrated.blankEnabled == false)
            #expect(migrated.userTemplates.first?.path == source.path)
            #expect(migrated.userTemplates.first?.isMissing == false)
            let state = AppState()
            state.newFiles = [migrated]
            let before = MenuService().buildConfig(from: state).newFiles
            #expect(before.map(\.id) == ["txt"])
            let backup = try JSONDecoder().decode(SettingsBackup.self,
                from: JSONEncoder().encode(SettingsBackup(appState: state)))
            #expect(backup.newFiles.first?.templates?.first?.path == nil)
            // Match applyImport: the current entry's path is supplied before replacement.
            let imported = try #require(backup.newFiles.first).toModel(templateStore: store, existing: migrated.userTemplates)
            #expect(imported.userTemplates == migrated.userTemplates)
            #expect(imported.userTemplates.first?.path == source.path)
            #expect(imported.userTemplates.first?.isMissing == false)
            try service.save(AppConfigData(newFiles: [imported]), templateStore: store, preserveTemplateSnapshots: true)
            let loaded = try #require(service.load(templateStore: store).newFiles.first)
            #expect(loaded.userTemplates == migrated.userTemplates)
            #expect(loaded.blankEnabled == false)
            state.newFiles = [loaded]
            let after = MenuService().buildConfig(from: state).newFiles
            #expect(after.map(\.id) == ["txt"])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(after) == encoder.encode(before))
            #expect(try Data(contentsOf: source) == bytes)
        }
    }
}
