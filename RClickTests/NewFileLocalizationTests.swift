import Foundation
import Testing

@testable import RClick

@MainActor
struct NewFileLocalizationTests {
    @Test func builtInNamesExistInEveryAppLocalization() throws {
        let keys = ["JSON", "TXT", "Markdown", "DOCX", "PPTX", "XLSX", "Pages", "Keynote", "Numbers"]
        for language in ["en", "zh-Hans", "ja", "es", "fr"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable")
                #expect(value != "__missing__", "Missing built-in name: \(key) in \(language)")
            }
        }
    }
}
