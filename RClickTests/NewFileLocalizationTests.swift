import Foundation
import Testing

@testable import RClick

@MainActor
struct NewFileLocalizationTests {
    @Test func builtInNamesExistInEveryAppLocalization() throws {
        let keys = NewFile.all.map(\.displayName)
        for language in ["en", "zh-Hans", "ja", "es", "fr"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable")
                #expect(value != "__missing__", "Missing built-in name: \(key) in \(language)")
            }
        }
    }

    @Test func appleProductNamesUseSimplifiedChineseWording() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Pages", value: "__missing__", table: "Localizable") == "Pages 文稿")
        #expect(bundle.localizedString(forKey: "Keynote", value: "__missing__", table: "Localizable") == "Keynote 讲演")
        #expect(bundle.localizedString(forKey: "Numbers", value: "__missing__", table: "Localizable") == "Numbers 表格")
    }
}
