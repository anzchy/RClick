import Foundation
import SwiftData
import Testing
@testable import RClick

@MainActor
struct NewFileMigrationTests {
    @Test func oldDefaultsArePrunedWithoutLosingUserTemplatesAndLoadIsIdempotent() throws {
        let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
            CommonDirEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for id in ["txt", "md", "json", "docx", "pptx", "xlsx", "pages", "key", "numbers"] {
            context.insert(NewFileTypeEntity(id: id, fileExtension: "." + id, name: id, sortOrder: 0))
        }
        try context.save()
        let service = ConfigService(modelContext: context)
        #expect(Set(service.load().newFiles.map(\.id)) == Set(["txt", "md", "json", "docx", "pptx", "xlsx"]))
        context.insert(NewFileTypeEntity(id: "pages", fileExtension: ".pages", name: "My Pages",
            templatePath: "/tmp/my-template.pages"))
        context.insert(NewFileTypeEntity(id: "custom", fileExtension: ".key", name: "Custom Keynote"))
        try context.save()
        let first = service.load().newFiles
        #expect(first.first { $0.id == "pages" }?.template?.path == "/tmp/my-template.pages")
        #expect(first.contains { $0.id == "custom" })
        #expect(service.load().newFiles.map(\.id) == first.map(\.id))
        #expect(try context.fetchCount(FetchDescriptor<NewFileTypeEntity>()) == 8)
    }
}
