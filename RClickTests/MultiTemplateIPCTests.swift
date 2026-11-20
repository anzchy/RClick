import Foundation
import Synchronization
import Testing
@testable import RClick

@MainActor
struct MultiTemplateIPCTests {
    @Test func signedMenuAndClickCarrySelectionAndOldJSONStillDecodes() throws {
        let oldClick = Data(#"{"itemId":"txt","itemType":"new-file","target":["/tmp/destination"],"trigger":"contextualItems"}"#.utf8)
        // Use the enum's existing wire spelling, independently of added fields.
        var oldObject = try #require(JSONSerialization.jsonObject(with: oldClick) as? [String: Any])
        oldObject["trigger"] = MenuTrigger.contextualItems.rawValue
        let old = try JSONDecoder().decode(ClickEventPayload.self, from: JSONSerialization.data(withJSONObject: oldObject))
        #expect(old.templateId == nil)
        let oldItem = try JSONDecoder().decode(NewFileMenuItem.self, from: Data(#"{"id":"txt","name":"Text","ext":".txt","icon":"doc"}"#.utf8))
        #expect(oldItem.entries == nil)
        let center = NotificationCenter()
        let clock = TestIPCClock(wall: 100, monotonic: 200)
        let key = Data(repeating: 0x42, count: 32)
        let app = Messager(isExtension: false, center: center, keyProvider: InMemoryKeyProvider(data: key), clock: clock)
        let ext = Messager(isExtension: true, center: center, keyProvider: InMemoryKeyProvider(data: key), clock: clock)
        let delivery = IPCExtensionDelivery(messager: ext)
        let clicks = Mutex<[ClickEventPayload]>([])
        app.onExtensionMessage(.click) { message in
            if let event = message.decode(ClickEventPayload.self) { clicks.withLock { $0.append(event) } }
        }
        app.sendRunningNotification()
        app.sendMenuConfig(MenuConfigPayload(newFiles: [NewFileMenuItem(id: "txt", name: "Text", ext: ".txt", icon: "doc",
            entries: [.init(id: "letter", name: "Letter"), .init(id: "memo", name: "Memo")])]))
        let received = try #require(delivery.menuConfig(as: MenuConfigPayload.self))
        #expect(received.newFiles.first?.entries?.map(\.name) == ["Letter", "Memo"])
        let event = ClickEventPayload(itemId: "txt", itemType: .newFile, trigger: .contextualItems, templateId: "memo")
        ext.sendClickEvent(event)
        #expect(clicks.withLock { $0.last?.templateId } == "memo")
        var signed = MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "click", id: "test", session: app.currentSession,
            timestamp: 100, nonce: Data(repeating: 9, count: 16), payload: try JSONEncoder().encode(event)), key: key)
        #expect(MessageSecurity.verify(signed, key: key))
        signed.payload = try JSONEncoder().encode(old)
        #expect(!MessageSecurity.verify(signed, key: key))
        center.post(name: Notification.Name(Messager.extensionToMainNotification), object: signed.wireString())
        #expect(clicks.withLock { $0.count } == 1)
    }
}
