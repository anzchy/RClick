import Foundation
import XCTest
@testable import RClick

@MainActor
final class IPCAuthenticationTests: XCTestCase {
    func testCapturedMACCannotAuthorizeDifferentPayload() throws {
        let receiver = Messager(isExtension: false, center: NotificationCenter())
        let original = ClickEventPayload(itemId: "delete", itemType: .action, target: ["/tmp/selected"], trigger: .contextualItems, optionKeyPressed: false)
        let captured = try MessageSecurity.sign(original)
        let forged = SignedPayload(payload: ClickEventPayload(itemId: "delete", itemType: .action, target: ["/tmp/other"], trigger: .contextualItems, optionKeyPressed: true), signature: captured.signature, jsonData: captured.jsonData)
        XCTAssertNil(receiver.decodeSignedData(try JSONEncoder().encode(forged), as: ClickEventPayload.self))
    }
}
