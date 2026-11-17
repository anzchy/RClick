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

    @Test func resolvesParentsButPreservesLeafSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real")
        let home = realParent.appendingPathComponent("Home")
        try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: realParent)
        let leaf = root.appendingPathComponent("home-link")
        try fm.createSymbolicLink(at: leaf, withDestinationURL: home)

        #expect(Utils.isProtectedFolder(alias.appendingPathComponent("Home").path, homeDirectory: home.path))
        #expect(Utils.isProtectedFolder(alias.appendingPathComponent("Home/Documents").path, homeDirectory: home.path))
        #expect(Utils.isProtectedFolder(home.path, homeDirectory: alias.appendingPathComponent("Home").path))
        #expect(!Utils.isProtectedFolder(leaf.path, homeDirectory: home.path))
        let systemLink = root.appendingPathComponent("applications-link")
        try fm.createSymbolicLink(at: systemLink, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        #expect(!Utils.isProtectedFolder(systemLink.path, homeDirectory: home.path))
        #expect(Utils.isProtectedFolder("/private/var", homeDirectory: home.path))
        #expect(Utils.isProtectedFolder("/var", homeDirectory: home.path))
    }

    @Test func protectsCaseVariants() {
        let home = "/nonexistent/Protected Home"
        for path in ["/applications", "/SYSTEM/", "/uSr", "/PRIVATE/VAR",
                     home.uppercased(), home.lowercased() + "/dOcUmEnTs"] {
            #expect(Utils.isProtectedFolder(path, homeDirectory: home), "Must protect \(path)")
        }
        #expect(!Utils.isProtectedFolder("/APPLICATIONSX", homeDirectory: home))
        #expect(!Utils.isProtectedFolder(home.uppercased() + "/DOCUMENTS/child", homeDirectory: home))
    }

    @Test func protectsCanonicallyEquivalentUnicodeNames() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("protected-unicode-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("Caf\u{00E9}")
        try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        // Cover a nonexistent spelling as well as the real temporary home.
        let missingHome = root.path + "/Missing Caf\u{00E9}"
        #expect(Utils.isProtectedFolder(root.path + "/Missing Cafe\u{0301}", homeDirectory: missingHome))
        #expect(!Utils.isProtectedFolder(root.path + "/Cafe", homeDirectory: home.path))
        let decomposedHome = root.path + "/Cafe\u{0301}"
        #expect(Utils.isProtectedFolder(decomposedHome, homeDirectory: home.path))
        #expect(Utils.isProtectedFolder(decomposedHome + "/Documents", homeDirectory: home.path))
        #expect(!Utils.isProtectedFolder(decomposedHome + "/Documents/child", homeDirectory: home.path))
    }

    @Test func protectsNonexistentPathsWithoutThrowing() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-created-\(UUID().uuidString)").path
        #expect(!FileManager.default.fileExists(atPath: home))
        #expect(Utils.isProtectedFolder(home + "/Documents/child/..", homeDirectory: home))
        #expect(Utils.isProtectedFolder(home + "/Library/", homeDirectory: home))
        #expect(!Utils.isProtectedFolder(home + "/Documents/missing", homeDirectory: home))
    }
}
