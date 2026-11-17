import Foundation
import XCTest
@testable import RClick

final class AppGroupEntitlementsTests: XCTestCase {
    func testAllTargetsDeclareTheForkAppGroup() throws {
        // Xcode copies the repository entitlement files into this test bundle.
        // Reading them here avoids asking a new app identity for Documents access.
        let resources = Bundle(for: Self.self)
        let expectedGroup = "group.cn.anzchy.RClick"
        XCTAssertEqual(SharedAppGroup.identifier, expectedGroup)

        for path in [
            "RClick/RClick.entitlements",
            "RClick/RClickDebug.entitlements",
            "FinderSyncExt/FinderSyncExt.entitlements",
        ] {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let url = try XCTUnwrap(resources.url(forResource: name, withExtension: "entitlements"), path)
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            let groups = try XCTUnwrap(plist["com.apple.security.application-groups"] as? [String], path)
            XCTAssertEqual(groups, [expectedGroup], path)
            XCTAssertEqual(groups, [SharedAppGroup.identifier], path)
        }
    }
}
