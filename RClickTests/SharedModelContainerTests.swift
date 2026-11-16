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
}
