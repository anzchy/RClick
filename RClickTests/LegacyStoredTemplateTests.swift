import Foundation
import SwiftData
import Testing
@testable import RClick

@MainActor
struct LegacyStoredTemplateTests {
    @Test func inStoreLegacyPackageSurvivesLoadAndCreatesDirectory() async throws {
        try await checkPackage(fromBackup: false)
    }

    @Test func inStoreLegacyPackageSurvivesOldBackupAndCreatesDirectory() async throws {
        try await checkPackage(fromBackup: true)
    }

    private func checkPackage(fromBackup: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let source = store.baseURL.appendingPathComponent("Report.pages")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let bytes = Data("legacy package bytes".utf8)
        try bytes.write(to: source.appendingPathComponent("Contents/document"))
        let output = dir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
            CommonDirEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let service = ConfigService(modelContext: context)
        let file: NewFile
        if fromBackup {
            // Literal old backup shape, with no multi-template fields.
            let json = try JSONSerialization.data(withJSONObject: ["id": "pages", "ext": ".pages",
                "name": "Pages", "enabled": true, "idx": 0, "icon": "doc", "templatePath": source.path])
            file = try JSONDecoder().decode(SettingsBackup.FileTemplate.self, from: json).toModel(templateStore: store)
        } else {
            context.insert(NewFileTypeEntity(id: "pages", fileExtension: ".pages", name: "Pages", templatePath: source.path))
            try context.save()
            file = try #require(service.load(templateStore: store).newFiles.first)
        }
        #expect(file.blankEnabled == false)
        #expect(file.userTemplates.first?.path == source.path)
        #expect(file.userTemplates.first?.isMissing == false)
        // Also prove the next sync cannot persist an erased path.
        try service.save(AppConfigData(newFiles: [file]), templateStore: store)
        let loaded = try #require(service.load(templateStore: store).newFiles.first)
        #expect(loaded.userTemplates == file.userTemplates)
        let state = AppState()
        state.newFiles = [loaded]
        for collapsed in [false, true] {
            let menu = MenuService().buildConfig(from: state, newFilesCollapsed: collapsed).newFiles
            #expect(menu.map(\.id) == ["pages"])
            #expect(menu.first?.entries?.map(\.id) == loaded.userTemplates.map(\.id))
        }
        let actions = NewFileCreationTests.State()
        actions.newFiles = [loaded]
        var copies: [URL] = []
        var warnings: [String] = []
        let action = ActionService(state: actions, permission: NewFileCreationTests.Permission(),
            confirmation: NewFileCreationTests.Confirmation(), revealNewFile: { copies.append($0) })
        await action.createFile(rid: "pages", target: [output.path], templateWarning: { warnings.append($0) })
        #expect(warnings.isEmpty)
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(try copy.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try Data(contentsOf: copy.appendingPathComponent("Contents/document")) == bytes)
        #expect(try Data(contentsOf: source.appendingPathComponent("Contents/document")) == bytes)
    }
}
