import AppKit
import Foundation
import XCTest
@testable import RClick

@MainActor
final class CutIPCIntegrationTests: XCTestCase {
    func testSignedSenderPreservesEveryConfigPropertyInGuardedSnapshot() throws {
        let center = NotificationCenter()
        let clock = TestIPCClock(wall: 100, monotonic: 200)
        let provider = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: provider, clock: clock)
        let ext = Messager(isExtension: true, center: center, keyProvider: provider, clock: clock)
        let delivery = IPCExtensionDelivery(messager: ext)
        let input = MenuConfigPayload(
            version: 999,
            actions: [ActionMenuItem(id: "cut", name: "Cut & Paste", icon: "scissors", tag: 6)],
            apps: [AppMenuItem(id: "app", name: "Example", icon: "app", tag: 7,
                               appURL: "/Applications/Example.app", opensNewInstance: true,
                               showInToolbar: false, showInContextMenu: false, opensContainingDir: true)],
            newFiles: [NewFileMenuItem(id: "text", name: "Text", ext: "txt", icon: "doc")],
            commonDirs: [CommonDirMenuItem(id: "folder", name: "Folder", icon: "folder", url: "/tmp/example")],
            actionsCollapsed: true, appsCollapsed: true, newFilesCollapsed: false,
            commonDirsCollapsed: false, iconStyle: RCAppIconStyle.original.rawValue,
            cutChangeCount: 42, cutItemCount: 3
        )
        app.sendRunningNotification()
        app.sendMenuConfig(input)
        let snapshot = try XCTUnwrap(delivery.menuConfig(as: MenuConfigPayload.self))
        XCTAssertTrue(delivery.isHostAppRunning)
        XCTAssertEqual(ext.currentSession, app.currentSession)
        XCTAssertEqual(snapshot.cutChangeCount, 42)
        XCTAssertEqual(snapshot.cutItemCount, 3)

        // Each stored property has a non-default fixture and an explicit comparison.
        // A future stored property must extend this fixture and its assertions.
        XCTAssertEqual(Set(Mirror(reflecting: input).children.compactMap(\.label)), Set([
            "version", "actions", "apps", "newFiles", "commonDirs", "actionsCollapsed", "appsCollapsed",
            "newFilesCollapsed", "commonDirsCollapsed", "iconStyle", "cutChangeCount", "cutItemCount",
        ]))
        XCTAssertEqual(snapshot.version, 1, "the signed sender owns version normalization")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(snapshot.actions), try encoder.encode(input.actions))
        XCTAssertEqual(try encoder.encode(snapshot.apps), try encoder.encode(input.apps))
        XCTAssertEqual(try encoder.encode(snapshot.newFiles), try encoder.encode(input.newFiles))
        XCTAssertEqual(try encoder.encode(snapshot.commonDirs), try encoder.encode(input.commonDirs))
        XCTAssertEqual(snapshot.actionsCollapsed, input.actionsCollapsed)
        XCTAssertEqual(snapshot.appsCollapsed, input.appsCollapsed)
        XCTAssertEqual(snapshot.newFilesCollapsed, input.newFilesCollapsed)
        XCTAssertEqual(snapshot.commonDirsCollapsed, input.commonDirsCollapsed)
        XCTAssertEqual(snapshot.iconStyle, input.iconStyle)
        app.sendMenuConfig(input)
        XCTAssertEqual(delivery.menuConfig(as: MenuConfigPayload.self)?.version, 2)
    }
}
