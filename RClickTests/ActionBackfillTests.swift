import Foundation
import SwiftData
import Testing

@testable import RClick

/// `SharedDataManager.initializeDefaultData` used to seed actions only when the
/// table was empty. A built-in action added in a later release therefore never
/// reached an existing install. These tests pin the backfill: missing defaults
/// are inserted at their declared position, existing rows keep their order, and
/// running the backfill again is a no-op.
@MainActor
struct ActionBackfillTests {
    private func makeContext() throws -> ModelContext {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-actions-\(UUID()).sqlite")
        let configuration = ModelConfiguration(url: url, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: AppEntity.self,
            ActionEntity.self,
            NewFileTypeEntity.self,
            CommonDirEntity.self,
            BookmarkEntity.self,
            DataVersion.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func fetchActions(_ context: ModelContext) throws -> [ActionEntity] {
        try context.fetch(FetchDescriptor<ActionEntity>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    @Test func freshStoreSeedsCopyFileNameAfterCopyPath() async throws {
        let context = try makeContext()

        await SharedDataManager.initializeDefaultData(context: context)

        let actions = try fetchActions(context)
        #expect(actions.map(\.id) == [
            "copy-path", "copy-file-name", "delete-direct", "hide", "unhide", "airdrop", "cut",
        ])
        #expect(actions.map(\.sortOrder) == Array(0..<7))
    }

    @Test func upgradeInsertsMissingActionWithoutDisturbingExistingOrder() async throws {
        let context = try makeContext()
        // The five actions shipped before Copy File Name existed.
        for (id, order) in [
            ("copy-path", 0), ("delete-direct", 1), ("hide", 2), ("unhide", 3), ("airdrop", 4),
        ] {
            context.insert(ActionEntity(id: id, name: id, icon: "doc", isEnabled: true, sortOrder: order))
        }
        try context.save()

        await SharedDataManager.initializeDefaultData(context: context)

        let actions = try fetchActions(context)
        #expect(actions.map(\.id) == [
            "copy-path", "copy-file-name", "delete-direct", "hide", "unhide", "airdrop", "cut",
        ])
        #expect(actions.map(\.sortOrder) == Array(0..<7))
    }

    @Test func builtInActionIconsFollowTheCurrentDefaults() async throws {
        let context = try makeContext()
        context.insert(ActionEntity(id: "copy-file-name", name: "Copy File Name",
                                    icon: "textformat", isEnabled: true, sortOrder: 1))
        try context.save()

        await SharedDataManager.initializeDefaultData(context: context)

        let action = try fetchActions(context).first { $0.id == "copy-file-name" }
        #expect(action?.icon == "doc.text")
    }

    @Test func runningBackfillTwiceDoesNotDuplicateActions() async throws {
        let context = try makeContext()

        await SharedDataManager.initializeDefaultData(context: context)
        await SharedDataManager.initializeDefaultData(context: context)

        let count = try context.fetchCount(FetchDescriptor<ActionEntity>())
        #expect(count == 7)
    }
    @Test func cutBackfillsOffWithoutChangingExistingOrderOrToggles() async throws {
        let context = try makeContext()
        let ids = ["airdrop", "unhide", "copy-path", "hide", "delete-direct", "copy-file-name"]
        let toggles = [true, false, false, true, false, true]
        for (index, id) in ids.enumerated() {
            context.insert(ActionEntity(id: id, name: id, icon: "doc", isEnabled: toggles[index], sortOrder: index))
        }
        try context.save()
        await SharedDataManager.initializeDefaultData(context: context)
        let actions = try fetchActions(context)
        #expect(actions.map(\.id) == ids + ["cut"])
        #expect(Array(actions.prefix(6)).map(\.isEnabled) == toggles)
        #expect(actions.map(\.sortOrder) == Array(0..<7))
        let cut = try #require(actions.last)
        #expect(cut.id == "cut")
        #expect(!cut.isEnabled)
        let catalogCut = try #require(RCAction.all.first { $0.id == "cut" })
        #expect(!catalogCut.enabled)
        #expect(catalogCut.name == "Cut & Paste")
    }

}
