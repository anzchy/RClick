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
                             folder.replacingOccurrences(of: "/", with: "//")]
            for path in spellings {
                #expect(Utils.isProtectedFolder(path, homeDirectory: home), "Must protect \(path)")
            }
            // Decode transport encoding once, as item-action callers do.
            let encoded = folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let callerPath = encoded.removingPercentEncoding!
            #expect(Utils.isProtectedFolder(callerPath, homeDirectory: home), "Must protect decoded \(encoded)")
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

    @Test func directoryLinkSuffixesCannotDeleteProtectedTargets() throws {
        let fm = FileManager.default
        for suffix in ["", "/", "/."] {
            let root = fm.temporaryDirectory.appendingPathComponent("protected-link-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let home = root.appendingPathComponent("Home")
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let marker = home.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: marker)
            let link = root.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: home)
            let path = link.path + suffix
            let protected = Utils.isProtectedFolder(path, homeDirectory: home.path)
            #expect(protected == !suffix.isEmpty, "Directory traversal suffix: \(suffix)")
            if !protected { try fm.removeItem(atPath: path) }
            #expect(fm.fileExists(atPath: home.path))
            #expect(fm.fileExists(atPath: marker.path))
        }
    }


    @Test func filesystemPathsPreserveLiteralPercentNames() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("protected-percent-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("Percent%41Home")
        let documents = home.appendingPathComponent("Documents")
        let lookalike = home.appendingPathComponent("%44ocuments")
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try fm.createDirectory(at: lookalike, withIntermediateDirectories: true)
        let ordinaryHome = root.appendingPathComponent("Home")
        try fm.createDirectory(at: ordinaryHome.appendingPathComponent("%44ocuments"), withIntermediateDirectories: true)
        #expect(!Utils.isProtectedFolder(ordinaryHome.path + "/%44ocuments", homeDirectory: ordinaryHome.path))
        // Hide-contents uses URL.path directly.
        #expect(Utils.isProtectedFolder(home.path, homeDirectory: home.path))
        #expect(Utils.isProtectedFolder(documents.path, homeDirectory: home.path))
        #expect(!Utils.isProtectedFolder(lookalike.path, homeDirectory: home.path))
        // Item actions decode once before checking and acting on the same path.
        for url in [home, documents] {
            let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let callerPath = try #require(encoded.removingPercentEncoding)
            #expect(Utils.isProtectedFolder(callerPath, homeDirectory: home.path))
        }
        let encodedLookalike = lookalike.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let callerPath = try #require(encodedLookalike.removingPercentEncoding)
        #expect(!Utils.isProtectedFolder(callerPath, homeDirectory: home.path))
    }


    @Test func refusesUnresolvedParentsButAllowsMissingChildren() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("protected-denied-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("locked")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        let home = root.appendingPathComponent("Home")
        try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let alias = locked.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: home)
        let protectedPath = alias.path + "/Documents"
        let child = alias.path + "/Documents/missing"
        #expect(Utils.isProtectedFolder(protectedPath, homeDirectory: home.path))
        #expect(!Utils.isProtectedFolder(child, homeDirectory: home.path))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(Utils.isProtectedFolder(protectedPath, homeDirectory: home.path))
        #expect(Utils.isProtectedFolder(child, homeDirectory: home.path))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        #expect(Utils.isProtectedFolder(protectedPath, homeDirectory: home.path))
        #expect(!Utils.isProtectedFolder(child, homeDirectory: home.path))
        #expect(!Utils.isProtectedFolder(home.path + "/Documents/nonexistent", homeDirectory: home.path))
        #expect(Utils.isProtectedFolder("", homeDirectory: home.path))
        #expect(Utils.isProtectedFolder("relative/Documents", homeDirectory: home.path))
    }


    @Test func productionEntryPointProtectsRealHomeAndSystemFolders() {
        #expect(Utils.isProtectedFolder("/Applications"))
        #expect(Utils.isProtectedFolder(Utils.getRealHomeDir() + "/Documents"))
        #expect(!Utils.isProtectedFolder(Utils.getRealHomeDir() + "/Documents/rclick-nonexistent"))
    }

}
