import Foundation
import Testing
@testable import RClick

@MainActor
struct NewFileDefaultsTests {
    @Test func freshAndResetDefaultsOnlyOfferSupportedTypes() {
        let supported: Set<String> = ["txt", "md", "json", "docx", "pptx", "xlsx"]
        #expect(Set(NewFileTypeEntity.createDefaultFileTypes().map(\.id)) == supported)
        #expect(Set(NewFile.all.map(\.id)) == supported)
        let state = AppState()
        state.resetFiletypeItems()
        #expect(Set(state.newFiles.map(\.id)) == supported)
        #expect(Set(MenuService().buildConfig(from: state).newFiles.map(\.id)) == supported.subtracting(["json"]))
    }
    @Test func staleUnsupportedRowsStayOutOfMenuButUserTemplatesRemain() {
        let state = AppState()
        state.newFiles = [.pages, .key, .numbers,
            NewFile(ext: ".pages", name: "Custom", idx: 9, id: "custom")]
        let menu = MenuService()
        #expect(menu.buildConfig(from: state).newFiles.map(\.id) == ["custom"])
        state.newFiles[0].template = URL(fileURLWithPath: "/tmp/user.pages")
        #expect(menu.buildConfig(from: state).newFiles.map(\.id) == ["pages", "custom"])
    }

}
