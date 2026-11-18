import Foundation
import XCTest
import Synchronization
@testable import RClick

@MainActor
final class MessagerIsolationTests: XCTestCase {
    func testForkAndLegacyChannelsAreIsolatedInBothDirections() throws {
        let center = NotificationCenter()
        let key = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: key)
        let ext = Messager(isExtension: true, center: center, keyProvider: key)
        let legacyMain = "RClick.MainToExtension"
        let legacyExtension = "RClick.ExtensionToMain"
        XCTAssertEqual(Messager.mainToExtensionNotification, "cn.anzchy.RClick.MainToExtension")
        XCTAssertEqual(Messager.extensionToMainNotification, "cn.anzchy.RClick.ExtensionToMain")
        let clicks = Mutex<[String]>([])
        let directories = Mutex<[[String]]>([])
        let acknowledgements = Mutex(0)
        app.onExtensionMessage(.click) { [weak app] data in
            guard let app else { return }
            if let event = app.decodeSignedData(data, as: ClickEventPayload.self) {
                clicks.withLock { $0.append(event.itemId) }
                app.sendActionAck(inReplyTo: data.id)
            }
        }
        ext.onMainMessage(.running) { [weak ext] data in
            guard let ext else { return }
            if let running = ext.decodeSignedData(data, as: RunningPayload.self) {
                directories.withLock { $0.append(running.directories) }
            }
        }
        ext.onMainMessage(.actionAck) { _ in acknowledgements.withLock { $0 += 1 } }
        let event = ClickEventPayload(itemId: "test-click", itemType: .newFile, trigger: .contextualItems)
        // Fully valid v2 envelopes on legacy names must still stay isolated.
        let legacyClick = MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "click", id: "legacy-click", session: app.currentSession,
                                                            timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16),
                                                            payload: try JSONEncoder().encode(event)), key: Data(repeating: 0x42, count: 32)).wireString()
        let legacyRunning = MessageSecurity.sign(IPCEnvelope(direction: .toExtension, action: "running", id: "legacy-running", session: app.currentSession,
                                                              timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 2, count: 16),
                                                              payload: try JSONEncoder().encode(RunningPayload(directories: ["legacy"]))), key: Data(repeating: 0x42, count: 32)).wireString()
        center.post(name: Notification.Name(legacyExtension), object: legacyClick)
        center.post(name: Notification.Name(legacyMain), object: legacyRunning)
        XCTAssertEqual(clicks.withLock { $0 }, [])
        XCTAssertEqual(directories.withLock { $0 }, [])
        XCTAssertEqual(acknowledgements.withLock { $0 }, 0)
        let oldMain = center.addObserver(forName: Notification.Name(legacyMain), object: nil, queue: nil) { _ in XCTFail("Fork app reached a legacy extension") }
        let oldExtension = center.addObserver(forName: Notification.Name(legacyExtension), object: nil, queue: nil) { _ in XCTFail("Fork extension reached a legacy app") }
        defer { center.removeObserver(oldMain); center.removeObserver(oldExtension) }
        app.sendRunningNotification(directories: ["fork"])
        ext.sendClickEvent(event)
        XCTAssertEqual(clicks.withLock { $0 }, ["test-click"])
        XCTAssertEqual(directories.withLock { $0 }, [["fork"]])
        XCTAssertEqual(acknowledgements.withLock { $0 }, 1)
    }

    func testSignedPayloadRejectsTamperingAndUnsignedData() throws {
        let key = Data(repeating: 0x42, count: 32)
        let envelope = IPCEnvelope(direction: .toExtension, action: "running", id: "id", session: "session",
                                   timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16),
                                   payload: try JSONEncoder().encode(RunningPayload(directories: ["original"])))
        let signed = MessageSecurity.sign(envelope, key: key)
        let receiver = IPCReceiver(direction: .toExtension)
        XCTAssertEqual(try receiver.receive(signed.wireString(), key: key).decode(RunningPayload.self)?.directories, ["original"])
        var tampered = signed
        tampered.mac = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try IPCReceiver(direction: .toExtension).receive(tampered.wireString(), key: key))
        XCTAssertThrowsError(try receiver.receive(String(decoding: JSONEncoder().encode(RunningPayload()), as: UTF8.self), key: key))
    }
}
