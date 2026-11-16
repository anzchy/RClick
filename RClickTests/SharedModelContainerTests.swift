import Foundation
import SwiftData
import Testing

@testable import RClick

@MainActor
struct SharedModelContainerTests {
    @Test func testHostUsesMemoryWithoutResolvingAppGroup() throws {
        var resolvedGroup = false
        let container = try SharedDataManager.makeSharedModelContainer(isTestHost: true) {
            resolvedGroup = true
            return nil
        }

        #expect(container.configurations.count == 1)
        let configuration = try #require(container.configurations.first)
        #expect(configuration.isStoredInMemoryOnly)
        #expect(!resolvedGroup)
        let hostConfiguration = try #require(SharedDataManager.sharedModelContainer.configurations.first)
        #expect(hostConfiguration.isStoredInMemoryOnly)
    }

    @Test func normalLaunchUsesTheInjectedGroupStore() throws {
        let group = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-group-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: group) }

        let container = try SharedDataManager.makeSharedModelContainer(isTestHost: false) { group }
        let configuration = try #require(container.configurations.first)
        #expect(!configuration.isStoredInMemoryOnly)
        #expect(configuration.url == group.appendingPathComponent("RClickDatabase.sqlite"))
    }

}
