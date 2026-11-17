import Foundation
import Testing
@testable import RClick

@MainActor
struct ProtectedFolderTests {
    @Test func protectsExactFoldersAcrossLexicalSpellings() {
        let home = "/nonexistent/Protected Home 中文"
        let folders = [home, home + "/Desktop", home + "/Documents", home + "/Library",
                       home + "/Applications", "/", "/Applications", "/System", "/Library",
                       "/Users", "/usr", "/bin", "/sbin", "/var"]
        for folder in folders {
            let spellings = [folder, folder + "/", folder + "/.", folder + "/child/..",
                             folder.replacingOccurrences(of: "/", with: "//"),
                             folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!]
            for path in spellings {
                #expect(Utils.isProtectedFolder(path, homeDirectory: home), "Must protect \(path)")
            }
        }
        for path in ["/ApplicationsX", "/Applications/Foo.app", home + "/Documents/x", home + "/Desktop/danger"] {
            #expect(!Utils.isProtectedFolder(path, homeDirectory: home), "Must allow \(path)")
        }
    }
}
