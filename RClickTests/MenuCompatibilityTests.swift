import Foundation
import Testing
import SwiftData
@testable import RClick

@MainActor
struct MenuCompatibilityTests {
    @Test func oldAppPayloadKeepsBothMenusVisible() throws {
        let json = #"{"id":"terminal","name":"Terminal","icon":"terminal","tag":0,"appURL":"/Applications/Terminal.app"}"#
        let app = try JSONDecoder().decode(AppMenuItem.self, from: Data(json.utf8))
        #expect(app.showInToolbar)
        #expect(app.showInContextMenu)
        #expect(!app.opensNewInstance)
        #expect(app.opensContainingDir == nil)
    }

    @Test(arguments: [nil, true, false] as [Bool?], [false, true])
    func appOptionsSurvivePersistenceAndIPC(explicit: Bool?, toolbarVisible: Bool) throws {
        let container = try SwiftData.ModelContainer(
            for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self, CommonDirEntity.self,
            configurations: SwiftData.ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = ConfigService(modelContext: ModelContext(container))
        var app = OpenWithApp(appURL: URL(fileURLWithPath: "/Applications/Terminal.app"))
        app.opensContainingDir = explicit
        app.showInToolbar = toolbarVisible
        app.showInContextMenu = !toolbarVisible
        app.opensNewInstance = true
        try service.save(AppConfigData(apps: [app]))

        // Reload through the production mapping in a fresh context, so missing
        // ConfigService.load fields cannot be hidden by the original app value.
        let restored = try #require(ConfigService(modelContext: ModelContext(container)).load().apps.first)
        #expect(restored.id == app.id)
        #expect(restored.opensContainingDir == explicit)
        #expect(restored.showInToolbar == toolbarVisible)
        #expect(restored.showInContextMenu == !toolbarVisible)
        #expect(restored.opensNewInstance)
        let data = try JSONEncoder().encode(restored.toAppMenuItem())
        let decoded = try JSONDecoder().decode(AppMenuItem.self, from: data)
        #expect(decoded.opensContainingDir == explicit)
        #expect(decoded.showInToolbar == toolbarVisible)
        #expect(decoded.showInContextMenu == !toolbarVisible)
        #expect(decoded.opensNewInstance)
        #expect(decoded.isVisible(for: .toolbar) == toolbarVisible)
        #expect(decoded.isVisible(for: .contextualItems) == !toolbarVisible)
        #expect(decoded.isVisible(for: .contextualContainer) == !toolbarVisible)
        #expect(decoded.isVisible(for: .contextualSidebar) == !toolbarVisible)
    }
    @Test func pendingCutFieldsRoundTripAndOldConfigsMeanNothingPending() throws {
        let old = Data(#"{"version":1,"actions":[],"apps":[],"newFiles":[],"commonDirs":[],"actionsCollapsed":false,"appsCollapsed":false,"newFilesCollapsed":true,"commonDirsCollapsed":true}"#.utf8)
        let legacy = try JSONDecoder().decode(MenuConfigPayload.self, from: old)
        #expect(legacy.cutChangeCount == nil)
        #expect(legacy.cutItemCount == 0)
        #expect(!legacy.undoMoveAvailable)
        let current = MenuConfigPayload(cutChangeCount: 42, cutItemCount: 3, undoMoveAvailable: true)
        let decoded = try JSONDecoder().decode(MenuConfigPayload.self, from: JSONEncoder().encode(current))
        #expect(decoded.cutChangeCount == 42)
        #expect(decoded.cutItemCount == 3)
        #expect(decoded.undoMoveAvailable)
        // Encoding includes both fields and preserves the existing version.
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(fields["cutChangeCount"] as? Int == 42)
        #expect(fields["cutItemCount"] as? Int == 3)
        #expect(fields["version"] as? Int == 1)
    }

}
