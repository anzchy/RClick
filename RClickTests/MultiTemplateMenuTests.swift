import Foundation
import Testing
@testable import RClick

@MainActor
struct MultiTemplateMenuTests {
    @Test func zeroOneAndManyEntriesProduceDirectOrSubmenuInBothLayouts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("letter.txt")
        try Data("letter".utf8).write(to: path)
        let state = AppState()
        var type = NewFile.txt
        type.templates = []
        type.blankEnabled = false
        state.newFiles = [type]
        for folded in [false, true] {
            #expect(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.isEmpty)
            type.blankEnabled = true
            state.newFiles = [type]
            let blank = try #require(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.first)
            #expect(blank.entries?.map(\.name) == [AppLocalization.localized("Blank")])
            #expect(blank.entries?.first?.id == NewFile.blankTemplateID)
            #expect(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFilesCollapsed == folded)
            #expect(blank.submenuEntries == nil)
            #expect(blank.directTemplateId == NewFile.blankTemplateID)
            type.templates = [.init(id: "letter", name: "Letter", path: path.path),
                .init(id: "disabled", name: "Disabled", enabled: false, path: path.path),
                .init(id: "missing", name: "Missing", path: dir.appendingPathComponent("gone").path)]
            state.newFiles = [type]
            let many = try #require(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.first)
            #expect(many.entries?.map(\.name) == [AppLocalization.localized("Blank"), "Letter"])
            #expect(many.submenuEntries?.map(\.id) == [NewFile.blankTemplateID, "letter"])
            type.blankEnabled = false
            state.newFiles = [type]
            #expect(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.first?.entries?.map(\.id) == ["letter"])
            type.templates = []
            state.newFiles = [type]
        }
    }
}
