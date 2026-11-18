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
        XCTAssertThrowsError(try IPCReceiver(direction: .toMain, session: "session").receive(captured.wireString(), key: key))
    }
    func testPayloadFreeMessagesRequireAuthentication() throws {
        let center = NotificationCenter()
        let key = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: key)
        let ext = Messager(isExtension: true, center: center, keyProvider: key)
        let dispatches = Mutex(0)
        for action in [MainToExtensionAction.quit, .actionAck] { ext.onMainMessage(action) { _ in dispatches.withLock { $0 += 1 } } }
        for action in [ExtensionToMainAction.heartbeat, .requestConfig] { app.onExtensionMessage(action) { _ in dispatches.withLock { $0 += 1 } } }
        app.sendRunningNotification()
        for (index, action) in ["quit", "action-ack", "heartbeat", "request-config"].enumerated() {
            let name = ["quit", "action-ack"].contains(action) ? Messager.mainToExtensionNotification : Messager.extensionToMainNotification
            center.post(name: Notification.Name(name), object: "{\"id\":\"legacy\",\"action\":\"\(action)\"}")
            let envelope = IPCEnvelope(direction: name == Messager.mainToExtensionNotification ? .toExtension : .toMain,
                                       action: action, id: UUID().uuidString, inReplyTo: "pending-click", session: app.currentSession, timestamp: Date().timeIntervalSince1970,
                                       nonce: Data(repeating: UInt8(index + 1), count: 16), mac: Data(repeating: 0, count: 32))
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
            XCTAssertFalse(MessageSecurity.verify(envelope, key: key))
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

    func testWrongAckDoesNotCancelAnyOtherClickDeadline() {
        var pending = PendingClicks()
        pending.register("first")
        pending.register("second")
        pending.acknowledge("unrelated")
        pending.acknowledge("second")
        XCTAssertTrue(pending.expire("first"))
        XCTAssertFalse(pending.expire("second"))
        XCTAssertFalse(pending.expire("first"))
    }

    func testFailurePolicyLimitsLogsAndShowsOnlyOneNotice() {
        var policy = IPCFailurePolicy()
        var logs = 0, notices = 0
        for _ in 0..<1000 {
            let decision = policy.reject(now: 0)
            if decision.log { logs += 1 }
            if decision.notice { notices += 1 }
        }
        XCTAssertEqual(logs, 1)
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(policy.rejectedCount, 1000)
        XCTAssertFalse(policy.reject(now: 9).log)
        XCTAssertTrue(policy.reject(now: 10).log)
        XCTAssertFalse(policy.reject(now: 20).notice)
    }

    func testIPCLogsNeverContainBodiesPathsSignaturesOrHashes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Shared/MessageSecurity.swift", "Shared/Messager.swift", "FinderSyncExt/FinderSyncExt.swift", "RClick/RClickApp.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let markers = ["event.", "itemPaths", "url.path", "bundlePath", "payload.", "signature", "hash(", "sender.title", "action.name", "app.name", "newFile.name", "commonDir.name", "optionPressed", "menuOptionPressed", "optionKeySnapshot", "localizedDescription"]
            for line in source.split(separator: "\n") where line.contains("logger.") {
                XCTAssertFalse(markers.contains { line.contains($0) }, "Sensitive IPC log in \(file): \(line)")
            }
        }
    }

    func testNoReadableKeyKeepsExtensionOfflineAndDropsMessages() throws {
        let center = NotificationCenter()
        let ext = Messager(isExtension: true, center: center, keyProvider: InMemoryKeyProvider(data: nil))
        let app = Messager(isExtension: false, center: center, keyProvider: InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32)))
        let received = Mutex(0)
        ext.onMainMessage(.running) { _ in received.withLock { $0 += 1 } }
        app.sendRunningNotification()
        XCTAssertFalse(ext.hasReadableKey)
        XCTAssertFalse(ext.canUseCachedMenus)
        XCTAssertEqual(received.withLock { $0 }, 0)
    }

    func testValidMACOnWrongChannelIsRejected() {
        let key = Data(repeating: 0x42, count: 32)
        let wire = MessageSecurity.sign(IPCEnvelope(direction: .toExtension, action: "heartbeat", id: "id", session: "",
                                                   timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16)), key: key).wireString()
        XCTAssertThrowsError(try IPCReceiver(direction: .toMain).receive(wire, key: key))
    }
    func testInvalidMACDoesNotConsumeNonceAndExpiryUsesTimeOnly() throws {
        let key = Data(repeating: 0x42, count: 32)
        let clock = TestIPCClock(wall: 100, monotonic: 200)
        let receiver = IPCReceiver(direction: .toMain, clock: clock, capacity: 1)
        func signed(_ n: UInt8) -> IPCEnvelope {
            MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "heartbeat", id: "id", session: "",
                                              timestamp: clock.wallTime, nonce: Data(repeating: n, count: 16)), key: key)
        }
        var invalid = signed(1)
        invalid.mac = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try receiver.receive(invalid.wireString(), key: key))
        XCTAssertNoThrow(try receiver.receive(signed(1).wireString(), key: key))
        clock.advance(14)
        XCTAssertThrowsError(try receiver.receive(signed(2).wireString(), key: key))
        clock.advance(1)
        XCTAssertNoThrow(try receiver.receive(signed(2).wireString(), key: key))
    }
    func testOptionFlagCannotChangeWithoutInvalidatingMAC() throws {
        let key = Data(repeating: 0x42, count: 32)
        var signed = MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "click", id: "id", session: "session",
                                                      timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16),
                                                      payload: try JSONEncoder().encode(ClickEventPayload(itemId: "delete", itemType: .action, target: ["/tmp/selection"], trigger: .contextualItems, optionKeyPressed: false))), key: key)
        signed.payload = try JSONEncoder().encode(ClickEventPayload(itemId: "delete", itemType: .action, target: ["/tmp/selection"], trigger: .contextualItems, optionKeyPressed: true))
        XCTAssertFalse(MessageSecurity.verify(signed, key: key))
        XCTAssertThrowsError(try IPCReceiver(direction: .toMain, session: "session").receive(signed.wireString(), key: key))
    }
    func testLargeMenuFitsAndOversizeRejectedBeforeParsing() throws {
        let key = Data(repeating: 0x42, count: 32)
        let apps = (0..<250).map { index in
            AppMenuItem(id: "application-\(index)", name: "Example Productivity Application \(index)", icon: "app", tag: index,
                        appURL: "/Applications/Example Productivity Application \(index).app")
        }
        let payload = try JSONEncoder().encode(MenuConfigPayload(version: 1, apps: apps))
        let large = MessageSecurity.sign(IPCEnvelope(direction: .toExtension, action: "menu-config", id: "id", session: "session",
                                                     timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16), payload: payload), key: key).wireString()
        print("IPC_SIZE apps=250 payload=\(payload.count) wire=\(large.utf8.count) cap=\(IPCEnvelope.maximumWireBytes)")
        XCTAssertLessThan(large.utf8.count, IPCEnvelope.maximumWireBytes)
        XCTAssertEqual(try IPCReceiver(direction: .toExtension).receive(large, key: key).decode(MenuConfigPayload.self)?.apps.count, 250)
        let oversized = MessageSecurity.sign(IPCEnvelope(direction: .toMain, action: "heartbeat", id: "id", session: "",
                                                         timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: 1, count: 16),
                                                         payload: Data(repeating: 0x61, count: 256 * 1024)), key: key).wireString()
        // A valid, correctly MACed and otherwise admissible message: removing
        // the pre-parse cap makes both assertions fail.
        XCTAssertThrowsError(try IPCEnvelope.parse(oversized))
        XCTAssertThrowsError(try IPCReceiver(direction: .toMain).receive(oversized, key: key))
        XCTAssertThrowsError(try IPCEnvelope.parse("{\"action\":\"quit\"}"))
    }
    func testPayloadFreeMessagesAreAcceptedWhenAuthenticated() {
        let center = NotificationCenter()
        let key = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: key)
        let ext = Messager(isExtension: true, center: center, keyProvider: key)
        let actions = Mutex<[String]>([])
        ext.onMainMessage(.quit) { message in actions.withLock { $0.append(message.action) } }
        ext.onMainMessage(.actionAck) { message in actions.withLock { $0.append(message.inReplyTo) } }
        app.onExtensionMessage(.heartbeat) { message in actions.withLock { $0.append(message.action) } }
        app.onExtensionMessage(.requestConfig) { message in actions.withLock { $0.append(message.action) } }
        app.sendRunningNotification()
        app.sendQuitNotification()
        app.sendActionAck(inReplyTo: "click-id")
        ext.sendHeartbeat()
        ext.requestMenuConfig()
        XCTAssertEqual(actions.withLock { $0 }, ["quit", "click-id", "heartbeat", "request-config"])
    }
    func testSenderVersionsConfigMonotonically() {
        let center = NotificationCenter()
        let key = InMemoryKeyProvider(data: Data(repeating: 0x42, count: 32))
        let app = Messager(isExtension: false, center: center, keyProvider: key)
        let ext = Messager(isExtension: true, center: center, keyProvider: key)
        let messages = Mutex<[VerifiedMessage]>([])
        ext.onMainMessage(.menuConfig) { message in messages.withLock { $0.append(message) } }
        app.sendMenuConfig(MenuConfigPayload(version: 100))
        app.sendMenuConfig(MenuConfigPayload(version: 100))
        XCTAssertEqual(messages.withLock { $0 }.compactMap { $0.decode(MenuConfigPayload.self)?.version }, [1, 2])
    }
    func testConstantTimeAPIAndKeychainAttributesRemainRequired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let security = try String(contentsOf: root.appendingPathComponent("Shared/MessageSecurity.swift"), encoding: .utf8)
        let provider = try String(contentsOf: root.appendingPathComponent("Shared/IPCKeyProvider.swift"), encoding: .utf8)
        XCTAssertTrue(security.contains("HMAC<SHA256>.isValidAuthenticationCode"))
        XCTAssertFalse(security.contains("elementsEqual"))
        XCTAssertFalse(security.contains("RClick_IPC_SharedKey"))
        XCTAssertTrue(provider.contains("kSecUseDataProtectionKeychain as String: true"))
        XCTAssertTrue(provider.contains("kSecAttrAccessGroup as String: SharedAppGroup.identifier"))
        XCTAssertTrue(provider.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"))
    }

    func testRendererRejectsReorderedVerifiedCallbacksAndRetiredSessions() {
        var delivery = MenuConfigDeliveryOrder()
        XCTAssertTrue(delivery.accepts(session: "current", version: 3, currentSession: "current"))
        XCTAssertFalse(delivery.accepts(session: "current", version: 2, currentSession: "current"))
        XCTAssertFalse(delivery.accepts(session: "old", version: 100, currentSession: "current"))
        XCTAssertTrue(delivery.accepts(session: "next", version: 1, currentSession: "next"))
    }

    func testOversizedNotificationDoesNotRetryUnavailableKeyProvider() {
        let center = NotificationCenter()
        let provider = UnavailableCountingKeyProvider()
        let ext = Messager(isExtension: true, center: center, keyProvider: provider)
        XCTAssertFalse(ext.hasReadableKey)
        XCTAssertEqual(provider.calls.withLock { $0 }, 1)
        center.post(name: Notification.Name(Messager.mainToExtensionNotification), object: String(repeating: "A", count: IPCEnvelope.maximumWireBytes + 4))
        XCTAssertEqual(provider.calls.withLock { $0 }, 1)
    }

    func testExtensionRejectsQuitAndAckFromAnotherSessionEvenWithValidMAC() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = IPCReceiver(direction: .toExtension)
        func wire(_ action: String, _ session: String, _ nonce: UInt8) throws -> String {
            MessageSecurity.sign(IPCEnvelope(direction: .toExtension, action: action, id: "id", inReplyTo: "pending-click", session: session,
                                              timestamp: Date().timeIntervalSince1970, nonce: Data(repeating: nonce, count: 16),
                                              payload: action == "running" ? try JSONEncoder().encode(RunningPayload()) : Data()), key: key).wireString()
        }
        XCTAssertNoThrow(try receiver.receive(wire("running", "current", 1), key: key))
        XCTAssertThrowsError(try receiver.receive(wire("quit", "previous", 2), key: key))
        XCTAssertThrowsError(try receiver.receive(wire("action-ack", "previous", 3), key: key))
        XCTAssertNoThrow(try receiver.receive(wire("action-ack", "current", 4), key: key))
    }

}


nonisolated final class TestIPCClock: IPCClock {
    private let time: Mutex<(Double, Double)>
    init(wall: Double, monotonic: Double) { time = Mutex((wall, monotonic)) }
    var wallTime: TimeInterval { time.withLock { $0.0 } }
    var monotonicTime: TimeInterval { time.withLock { $0.1 } }
    func advance(_ seconds: Double) { time.withLock { $0.0 += seconds; $0.1 += seconds } }
}

nonisolated final class UnavailableCountingKeyProvider: KeyProvider {
    let calls = Mutex(0)
    func key(createIfMissing: Bool) throws -> Data {
        calls.withLock { $0 += 1 }
        throw IPCSecurityError.noKey
    }
}
