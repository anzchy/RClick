import Foundation
import XCTest
import Synchronization
@testable import RClick

@MainActor
final class IPCAuthenticationTests: XCTestCase {
    func testCapturedMACCannotAuthorizeDifferentPayload() throws {
        let key = Data(repeating: 0x42, count: 32)
        let original = ClickEventPayload(itemId: "delete", itemType: .action, target: ["/tmp/selected"], trigger: .contextualItems, optionKeyPressed: false)
        let envelope = IPCEnvelope(direction: .toMain, action: "click", id: "click", session: "session", timestamp: Date().timeIntervalSince1970,
                                   nonce: Data(repeating: 1, count: 16), payload: try JSONEncoder().encode(original))
        var captured = MessageSecurity.sign(envelope, key: key)
        captured.payload = try JSONEncoder().encode(ClickEventPayload(itemId: "delete", itemType: .action, target: ["/tmp/other"], trigger: .contextualItems, optionKeyPressed: true))
        XCTAssertThrowsError(try IPCReceiver(direction: .toMain).receive(captured.wireString(), key: key))
    }
    func testPayloadFreeMessagesRequireAuthentication() throws {
        let center = NotificationCenter()
        let key = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: key)
        let ext = Messager(isExtension: true, center: center, keyProvider: key)
        let dispatches = Mutex(0)
        for action in [MainToExtensionAction.quit, .actionAck] { ext.onMainMessage(action) { _ in dispatches.withLock { $0 += 1 } } }
        for action in [ExtensionToMainAction.heartbeat, .requestConfig] { app.onExtensionMessage(action) { _ in dispatches.withLock { $0 += 1 } } }
        for action in ["quit", "action-ack", "heartbeat", "request-config"] {
            let name = ["quit", "action-ack"].contains(action) ? Messager.mainToExtensionNotification : Messager.extensionToMainNotification
            center.post(name: Notification.Name(name), object: "{\"id\":\"legacy\",\"action\":\"\(action)\"}")
            let envelope = IPCEnvelope(direction: name == Messager.mainToExtensionNotification ? .toExtension : .toMain,
                                       action: action, id: UUID().uuidString, session: "session", timestamp: Date().timeIntervalSince1970,
                                       nonce: Data(repeating: 1, count: 16), mac: Data(repeating: 0, count: 32))
            center.post(name: Notification.Name(name), object: envelope.wireString())
        }
        XCTAssertEqual(dispatches.withLock { $0 }, 0)
    }
    func testEveryEnvelopeFieldIsAuthenticatedAndWrongKeyRejected() throws {
        let key = Data(repeating: 0x42, count: 32)
        let original = MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "click", id: "click", inReplyTo: "reply", session: "session",
                                                       timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16), payload: Data("{}".utf8)), key: key)
        var variants: [IPCEnvelope] = []
        var changed = original; changed.direction = .toExtension; variants.append(changed)
        changed = original; changed.action = "heartbeat"; variants.append(changed)
        changed = original; changed.id = "other"; variants.append(changed)
        changed = original; changed.inReplyTo = "other"; variants.append(changed)
        changed = original; changed.session = "other"; variants.append(changed)
        changed = original; changed.timestamp += 1; variants.append(changed)
        changed = original; changed.nonce[0] ^= 1; variants.append(changed)
        changed = original; changed.payload = Data("null".utf8); variants.append(changed)
        for envelope in variants {
            XCTAssertThrowsError(try IPCReceiver(direction: .toMain).receive(envelope.wireString(), key: key))
        }
        XCTAssertThrowsError(try IPCReceiver(direction: .toMain).receive(original.wireString(), key: Data(repeating: 7, count: 32)))
    }

    func testReplayIsRejectedAtomically() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = IPCReceiver(direction: .toMain)
        let wire = MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "heartbeat", id: "id", session: "",
                                                   timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16)), key: key).wireString()
        let accepted = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if (try? receiver.receive(wire, key: key)) != nil { accepted.withLock { $0 += 1 } }
        }
        XCTAssertEqual(accepted.withLock { $0 }, 1)
    }

    func testFullNonceCacheRejectsWithoutEvictingOldest() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = IPCReceiver(direction: .toMain, capacity: 2)
        func wire(_ n: UInt8) -> String {
            MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "heartbeat", id: "id", session: "",
                                              timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: n, count: 16)), key: key).wireString()
        }
        let oldest = wire(1)
        XCTAssertNoThrow(try receiver.receive(oldest, key: key))
        XCTAssertNoThrow(try receiver.receive(wire(2), key: key))
        XCTAssertThrowsError(try receiver.receive(wire(3), key: key))
        XCTAssertThrowsError(try receiver.receive(oldest, key: key))
    }

    func testFreshnessRejectsStaleAndFutureButAcceptsBoundaries() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = IPCReceiver(direction: .toMain, clock: TestIPCClock(wall: 100, monotonic: 200))
        func wire(_ time: Double, _ nonce: UInt8) -> String {
            MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "heartbeat", id: "id", session: "",
                                              timestamp: time, nonce: Data(repeating: nonce, count: 16)), key: key).wireString()
        }
        XCTAssertThrowsError(try receiver.receive(wire(94.999, 1), key: key))
        XCTAssertThrowsError(try receiver.receive(wire(101.001, 2), key: key))
        XCTAssertNoThrow(try receiver.receive(wire(95, 3), key: key))
        XCTAssertNoThrow(try receiver.receive(wire(101, 4), key: key))
    }

    func testMainBindsClicksToLaunchSessionAndAllowsOnlyBootstrapWithoutSession() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = IPCReceiver(direction: .toMain, session: "current")
        func wire(_ session: String, _ action: String) -> String {
            MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: action, id: UUID().uuidString, session: session,
                                              timestamp: Date().timeIntervalSince1970, nonce: Data(UUID().uuidString.utf8.prefix(16))), key: key).wireString()
        }
        XCTAssertThrowsError(try receiver.receive(wire("previous", "click"), key: key))
        XCTAssertThrowsError(try receiver.receive(wire("", "click"), key: key))
        XCTAssertNoThrow(try receiver.receive(wire("current", "click"), key: key))
        XCTAssertNoThrow(try receiver.receive(wire("", "heartbeat"), key: key))
        XCTAssertNoThrow(try receiver.receive(wire("", "request-config"), key: key))
        XCTAssertThrowsError(try receiver.receive(wire("previous", "heartbeat"), key: key))
    }

    func testExtensionLearnsAndEchoesAuthenticatedSession() {
        let center = NotificationCenter()
        let key = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: key)
        let ext = Messager(isExtension: true, center: center, keyProvider: key)
        let accepted = Mutex(0)
        app.onExtensionMessage(.click) { _ in accepted.withLock { $0 += 1 } }
        let click = ClickEventPayload(itemId: "test", itemType: .action, trigger: .contextualItems)
        ext.sendClickEvent(click)
        XCTAssertEqual(accepted.withLock { $0 }, 0)
        app.sendRunningNotification()
        ext.sendClickEvent(click)
        XCTAssertEqual(accepted.withLock { $0 }, 1)
    }

    func testMenuConfigCannotMoveBackwardWithinSession() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = IPCReceiver(direction: .toExtension)
        func wire(_ revision: Int, _ session: String) throws -> String {
            MessageSecurity.sign(IPCEnvelope(direction: .toExtension, action: "menu-config", id: UUID().uuidString, session: session,
                                              timestamp: Date().timeIntervalSince1970, nonce: Data(UUID().uuidString.utf8.prefix(16)),
                                              payload: try JSONEncoder().encode(MenuConfigPayload(version: revision))), key: key).wireString()
        }
        XCTAssertNoThrow(try receiver.receive(wire(10, "first"), key: key))
        XCTAssertThrowsError(try receiver.receive(wire(9, "first"), key: key))
        XCTAssertNoThrow(try receiver.receive(wire(10, "first"), key: key))
        XCTAssertNoThrow(try receiver.receive(wire(1, "second"), key: key))
    }

}


nonisolated final class TestIPCClock: IPCClock {
    private let time: Mutex<(Double, Double)>
    init(wall: Double, monotonic: Double) { time = Mutex((wall, monotonic)) }
    var wallTime: TimeInterval { time.withLock { $0.0 } }
    var monotonicTime: TimeInterval { time.withLock { $0.1 } }
    func advance(_ seconds: Double) { time.withLock { $0.0 += seconds; $0.1 += seconds } }
}
