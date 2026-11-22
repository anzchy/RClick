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

extension PasteLocalizationTests {
    @Test func undoTitleAndAlertsExistInBothTargetsAndAllLanguages() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let extensionBundle = try #require(Bundle(url: plugins.appendingPathComponent("FinderSyncExt.appex")))
        for target in [Bundle.main, extensionBundle] {
            for (language, expected) in [
                ("en", "Undo last move"), ("zh-Hans", "撤销上次移动"),
                ("ja", "最後の移動を取り消す"), ("es", "Deshacer el último movimiento"),
                ("fr", "Annuler le dernier déplacement")
            ] {
                let resources = try #require(target.url(forResource: language, withExtension: "lproj"))
                let bundle = try #require(Bundle(url: resources))
                #expect(bundle.localizedString(forKey: "Undo last move", value: "<missing>", table: "Localizable") == expected)
                for key in ["There is no move to undo", "Undo requires access to both folders",
                    "Some items could not be restored:\n%@", "The moved item is missing or has changed",
                    "The original folder is missing or unavailable", "A move is already in progress"] {
                    #expect(bundle.localizedString(forKey: key, value: "<missing>", table: "Localizable") != "<missing>")
                }
            }
        }
    }
}
