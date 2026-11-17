import Foundation
import XCTest
@testable import RClick

@MainActor
final class MessagerIsolationTests: XCTestCase {
    func testForkAndLegacyChannelsAreIsolatedInBothDirections() throws {
        // A private center is mandatory: the installed app must never see test clicks.
        let center = NotificationCenter()
        let app = Messager(isExtension: false, center: center)
        let ext = Messager(isExtension: true, center: center)
        let legacyMain = "RClick.MainToExtension"
        let legacyExtension = "RClick.ExtensionToMain"
        XCTAssertEqual(Messager.mainToExtensionNotification, "cn.anzchy.RClick.MainToExtension")
        XCTAssertEqual(Messager.extensionToMainNotification, "cn.anzchy.RClick.ExtensionToMain")
        var clicks: [String] = []
        var directories: [[String]] = []
        var acknowledgements = 0
        app.onExtensionMessage(.click) { [weak app] data in
            guard let app else { return }
            if let event = app.decodeSignedData(data, as: ClickEventPayload.self) {
                clicks.append(event.itemId)
                app.sendActionAck()
            }
        }
        ext.onMainMessage(.running) { [weak ext] data in
            guard let ext else { return }
            if let running = ext.decodeSignedData(data, as: RunningPayload.self) {
                directories.append(running.directories)
            }
        }
        ext.onMainMessage(.actionAck) { _ in acknowledgements += 1 }
        let event = ClickEventPayload(itemId: "test-click", itemType: .newFile, trigger: .contextualItems)
        let legacyClick = try JSONEncoder().encode(ExtensionToMainMessage(action: .click, data: event))
        let legacyRunning = try JSONEncoder().encode(MainToExtensionMessage(action: .running, data: RunningPayload(directories: ["legacy"])))
        center.post(name: Notification.Name(legacyExtension), object: String(decoding: legacyClick, as: UTF8.self))
        center.post(name: Notification.Name(legacyMain), object: String(decoding: legacyRunning, as: UTF8.self))
        XCTAssertEqual(clicks, [])
        XCTAssertEqual(directories, [])
        XCTAssertEqual(acknowledgements, 0)

        // Reject any fork traffic at legacy observers, including the click's ack.
        let oldMain = center.addObserver(forName: Notification.Name(legacyMain), object: nil, queue: nil) { _ in
            XCTFail("Fork app reached a legacy extension")
        }
        let oldExtension = center.addObserver(forName: Notification.Name(legacyExtension), object: nil, queue: nil) { _ in
            XCTFail("Fork extension reached a legacy app")
        }
        defer { center.removeObserver(oldMain); center.removeObserver(oldExtension) }
        ext.sendClickEvent(event)
        app.sendRunningNotification(directories: ["fork"])
        XCTAssertEqual(clicks, ["test-click"])
        XCTAssertEqual(directories, [["fork"]])
        XCTAssertEqual(acknowledgements, 1)
    }

    func testSignedPayloadRejectsTamperingAndUnsignedData() throws {
        let messager = Messager(isExtension: false, center: NotificationCenter())
        let message = MainToExtensionMessage(action: .running, data: RunningPayload(directories: ["original"]))
        let signed = try XCTUnwrap(message.signedData)
        XCTAssertEqual(messager.decodeSignedData(signed, as: RunningPayload.self)?.directories, ["original"])
        let envelope = try JSONDecoder().decode(SignedPayload<RunningPayload>.self, from: signed)
        let tampered = try JSONEncoder().encode(SignedPayload(
            payload: envelope.payload, signature: Data(repeating: 0, count: 32).base64EncodedString(),
            jsonData: envelope.jsonData
        ))
        XCTAssertNil(messager.decodeSignedData(tampered, as: RunningPayload.self))
        XCTAssertNil(messager.decodeSignedData(try JSONEncoder().encode(RunningPayload()), as: RunningPayload.self))
    }
}
