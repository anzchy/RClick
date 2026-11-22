import Foundation
import Testing

struct PasteLocalizationTests {
    @Test func extensionPasteTitleExistsInEveryTargetLanguage() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let extensionBundle = try #require(Bundle(url: plugins.appendingPathComponent("FinderSyncExt.appex")))
        for (language, expected) in [
            ("en", "Paste (move here)"), ("zh-Hans", "粘贴（移动到此处）"),
            ("ja", "ペースト（ここに移動）"), ("es", "Pegar (mover aquí)"),
            ("fr", "Coller (déplacer ici)")
        ] {
            let resources = try #require(extensionBundle.url(forResource: language, withExtension: "lproj"))
            let localizedBundle = try #require(Bundle(url: resources))
            #expect(localizedBundle.localizedString(forKey: "Paste (move here)", value: "<missing>", table: "Localizable") == expected)
        }
    }
}


extension PasteLocalizationTests {
    @Test func changedSinceCutExistsInBothCatalogsAndAllLanguages() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let extensionBundle = try #require(Bundle(url: plugins.appendingPathComponent("FinderSyncExt.appex")))
        for target in [Bundle.main, extensionBundle] {
            for (language, expected) in [
                ("en", "Changed since cut"), ("zh-Hans", "项目在剪切后已更改"),
                ("ja", "カット後に変更されました"), ("es", "Modificado desde que se cortó"),
                ("fr", "Modifié depuis la coupe")
            ] {
                let resources = try #require(target.url(forResource: language, withExtension: "lproj"))
                let bundle = try #require(Bundle(url: resources))
                #expect(bundle.localizedString(forKey: "Changed since cut", value: "<missing>", table: "Localizable") == expected)
            }
        }
    }
}
