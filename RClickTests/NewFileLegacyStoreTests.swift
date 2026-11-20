import Foundation
import SwiftData
import Testing
@testable import RClick

@MainActor
struct NewFileLegacyStoreTests {
    @Test func editedBuiltinExtensionsSurviveLoadAndRemainInMenu() throws {
        for inMemory in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let configuration = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true) :
                ModelConfiguration(url: directory.appendingPathComponent("edited.sqlite"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
                CommonDirEntity.self, configurations: configuration)
            let context = ModelContext(container)
            let rows = [
                NewFileTypeEntity(id: "pages", fileExtension: ".xlsx", name: "Edited Pages", sortOrder: 0),
                NewFileTypeEntity(id: "key", fileExtension: ".docx", name: "Edited Key", sortOrder: 1),
                NewFileTypeEntity(id: "custom", fileExtension: ".key", name: "Custom", sortOrder: 3),
                NewFileTypeEntity(id: "numbers", fileExtension: ".numbers", name: "Empty Path", sortOrder: 4, templatePath: ""),
            ]
            for row in rows { context.insert(row) }
            try context.save()
            let service = ConfigService(modelContext: context)
            let expected = ["Edited Pages", "Edited Key", "Custom", "Empty Path"]
            for _ in 0..<2 {
                let loaded = service.load().newFiles
                #expect(loaded.map(\.name) == expected)
                let state = AppState()
                state.newFiles = loaded
                #expect(MenuService().buildConfig(from: state).newFiles.map(\.ext) == [".xlsx", ".docx", ".key"])
            }
            let reloaded = ConfigService(modelContext: ModelContext(container)).load().newFiles
            #expect(reloaded.map(\.name) == expected)
            #expect(try context.fetchCount(FetchDescriptor<NewFileTypeEntity>()) == 4)
            // Restoring the canonical pair makes this row eligible for retirement.
            rows[0].fileExtension = ".pages"
            try context.save()
            #expect(service.load().newFiles.map(\.name) == ["Edited Key", "Custom", "Empty Path"])
            #expect(ConfigService(modelContext: ModelContext(container)).load().newFiles.map(\.name)
                == ["Edited Key", "Custom", "Empty Path"])
            #expect(try context.fetchCount(FetchDescriptor<NewFileTypeEntity>()) == 3)
        }
    }

    @Test func oldDefaultsArePrunedWithoutLosingUserTemplatesAndLoadIsIdempotent() throws {
        for inMemory in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let configuration = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true) :
                ModelConfiguration(url: directory.appendingPathComponent("old.sqlite"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
                CommonDirEntity.self, configurations: configuration)
            let context = ModelContext(container)
            // Literal pre-#24 seed: defaults must not be derived from the new factory.
            let oldDefaults = [
                ("txt", "TXT", "doc.text"), ("md", "Markdown", "doc.richtext"),
                ("json", "JSON", "curlybraces"), ("docx", "DOCX", "doc.richtext.fill"),
                ("pptx", "PPTX", "rectangle.on.rectangle.fill"), ("xlsx", "XLSX", "tablecells"),
                ("pages", "Pages", "doc.richtext"), ("key", "Keynote", "rectangle.on.rectangle"),
                ("numbers", "Numbers", "tablecells"),
            ]
            for (order, item) in oldDefaults.enumerated() {
                context.insert(NewFileTypeEntity(id: item.0, fileExtension: "." + item.0, name: item.1,
                    icon: item.2, isEnabled: item.0 != "json", sortOrder: order))
            }
            try context.save()
            let service = ConfigService(modelContext: context)
            let loaded = service.load().newFiles
            #expect(loaded.map(\.id) == ["txt", "md", "json", "docx", "pptx", "xlsx"])
            #expect(loaded.map(\.idx) == [0, 1, 2, 3, 4, 5])
            #expect(loaded.map(\.enabled) == [true, true, false, true, true, true])
            #expect(loaded.map(\.name) == ["TXT", "Markdown", "JSON", "DOCX", "PPTX", "XLSX"])
            let state = AppState()
            state.newFiles = loaded
            #expect(MenuService().buildConfig(from: state).newFiles.map(\.id) == ["txt", "md", "docx", "pptx", "xlsx"])
            for (order, id) in ["pages", "key", "numbers"].enumerated() {
                context.insert(NewFileTypeEntity(id: id, fileExtension: "." + id, name: "My " + id,
                    isEnabled: order != 1, sortOrder: 6 + order, templatePath: "/tmp/user." + id,
                    openAppPath: "/Applications/User.app"))
            }
            context.insert(NewFileTypeEntity(id: "custom", fileExtension: ".key", name: "Custom Keynote", sortOrder: 9))
            try context.save()
            let first = service.load().newFiles
            for (order, id) in ["pages", "key", "numbers"].enumerated() {
                let kept = try #require(first.first { $0.id == id })
                #expect(kept.template?.path == "/tmp/user." + id)
                #expect(kept.openApp?.path == "/Applications/User.app")
                #expect(kept.name == "My " + id)
                #expect(kept.enabled == (order != 1))
                #expect(kept.idx == 6 + order)
            }
            #expect(first.contains { $0.id == "custom" })
            #expect(service.load().newFiles.map(\.id) == first.map(\.id))
            // A new context proves the repair was persisted, not just filtered in memory.
            let reloaded = ConfigService(modelContext: ModelContext(container)).load().newFiles
            #expect(reloaded.map(\.id) == first.map(\.id))
            #expect(try context.fetchCount(FetchDescriptor<NewFileTypeEntity>()) == 10)
        }
    }
}
