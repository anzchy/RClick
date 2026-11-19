import AppKit
import Foundation
import Synchronization
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
    func testCapabilityLostAfterSnapshotDisablesNativeCutInBothLayouts() throws {
        for collapsed in [false, true] {
            let center = NotificationCenter()
            let clock = TestIPCClock(wall: 100, monotonic: 200)
            let app = Messager(isExtension: false, center: center,
                               keyProvider: InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32)), clock: clock)
            let provider = MutableIPCKeyProvider()
            let ext = Messager(isExtension: true, center: center, keyProvider: provider, clock: clock)
            let delivery = IPCExtensionDelivery(messager: ext)
            app.sendRunningNotification()
            app.sendMenuConfig(MenuConfigPayload(
                actions: [ActionMenuItem(id: "cut", name: "Cut & Paste", icon: "scissors", tag: 6)],
                actionsCollapsed: collapsed, cutChangeCount: 42, cutItemCount: 1))
            var cache: (id: String, value: MenuConfigPayload)?
            let snapshot = try XCTUnwrap(delivery.menuConfig(as: MenuConfigPayload.self, cached: &cache))
            let captured = PendingCut.menuVisibility(config: snapshot, menuKind: .contextualItems,
                selection: ["/tmp/selected-file"], currentChangeCount: 42, hostOnline: delivery.isHostAppRunning)
            XCTAssertTrue(captured.cut)
            XCTAssertTrue(captured.cutEnabled)
            let menu = NSMenu(title: "RClick")
            menu.autoenablesItems = false
            let cut = NSMenuItem(title: "Cut", action: nil, keyEquivalent: "")
            if snapshot.actionsCollapsed {
                let actions = NSMenu(title: "Actions")
                actions.autoenablesItems = false
                actions.addItem(cut)
                let parent = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
                parent.submenu = actions
                menu.addItem(parent)
            } else {
                menu.addItem(cut)
            }
            PendingCut.renderCutEnablement(on: cut, snapshotEnabled: captured.cutEnabled, delivery: delivery)
            XCTAssertTrue(cut.isEnabled)

            // Lose real controller capability after snapshot, before rendering the item again.
            provider.data.withLock { $0 = nil }
            clock.advance(10)
            ext.sendHeartbeat()
            XCTAssertFalse(ext.canUseCachedMenus)
            XCTAssertFalse(delivery.isHostAppRunning)
            XCTAssertNil(delivery.menuConfig(as: MenuConfigPayload.self, cached: &cache))
            XCTAssertNil(cache)
            PendingCut.renderCutEnablement(on: cut, snapshotEnabled: captured.cutEnabled, delivery: delivery)
            let rendered = try XCTUnwrap(collapsed ? menu.items.first?.submenu?.items.first : menu.items.first)
            XCTAssertFalse(rendered.isEnabled, "a captured online flag cannot outlive authenticated capability")
        }
    }

}
