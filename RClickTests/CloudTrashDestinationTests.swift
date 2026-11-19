import AppKit
import Testing
@testable import RClick

extension PasteActionServiceTests {
    @Test(arguments: ["icloud", "icloud-child", "arbitrary-dot", "arbitrary-dot-child", "arbitrary-trashes", "volume-trashes", "volume-child", "upper-dot", "provider-trash", "provider-child", "provider-dot"], [false, true])
    func cloudAndNestedTrashDestinationsRefuseLocalMoves(kind: String, viaLink: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let home = f.root.appendingPathComponent("home")
        let storage = home.appendingPathComponent("Library/CloudStorage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        f.operations.setAccountHome(home)
        let relative: String
        switch kind {
        case "icloud": relative = "home/Library/Mobile Documents/.Trash"
        case "icloud-child": relative = "home/Library/Mobile Documents/.Trash/sub/deeper"
        case "arbitrary-dot": relative = "ordinary/.Trash"
        case "arbitrary-dot-child": relative = "ordinary/.Trash/sub/deeper"
        case "arbitrary-trashes": relative = "ordinary/.Trashes"
        case "volume-trashes": relative = "volume/.Trashes"
        case "volume-child": relative = "volume/.Trashes/501/subfolder"
        case "upper-dot": relative = "ordinary/.TRASH"
        case "provider-trash": relative = "home/Library/CloudStorage/ExampleProvider/Trash"
        case "provider-child": relative = "home/Library/CloudStorage/ExampleProvider/Trash/sub/deeper"
        default: relative = "home/Library/CloudStorage/ExampleProvider/.Trash"
        }
        let destination = f.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if kind.hasPrefix("volume") {
            f.operations.setMoveFacts(MoveFacts(directory: true, mountPoint: true), for: f.root.appendingPathComponent("volume"))
        }
        if kind == "upper-dot" {
            f.operations.setMoveFacts(MoveFacts(directory: true, caseSensitiveNames: true), for: destination.deletingLastPathComponent())
        }
        let target: URL
        if viaLink {
            target = f.root.appendingPathComponent("trash-alias")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        } else { target = destination }
        // Resolve the Finder target exactly as ActionService does; no refusal double.
        #expect(try f.operations.readDestinationRefusal(target.resolvingSymlinksInPath()) == .trash)
        let source = try f.file()
        await f.cut([source]); await f.paste(target)
        #expect(f.operations.renameCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("notes.txt").path))
        #expect(f.service.pendingCut?.paths == [source.path])
        #expect(f.warnings.first?.contains("Use Finder’s Move to Trash") == true)
        #expect(f.leaser.balance == 0)
    }

    @Test(arguments: ["ordinary", "lookalike-cloud-storage"], [false, true])
    func ordinaryPlainTrashFolderRemainsAnAllowedDestination(kind: String, viaLink: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let home = f.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/CloudStorage"), withIntermediateDirectories: true)
        f.operations.setAccountHome(home)
        let destination = f.destination.appendingPathComponent(kind == "ordinary" ? "Trash" : "CloudStorage/Unrelated/Trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target: URL
        if viaLink {
            target = f.root.appendingPathComponent("ordinary-alias")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        } else { target = destination }
        #expect(try f.operations.readDestinationRefusal(target.resolvingSymlinksInPath()) == nil)
        let source = try f.file()
        await f.cut([source]); await f.paste(target)
        #expect(try Data(contentsOf: destination.appendingPathComponent("notes.txt")) == Data("original".utf8))
        #expect(f.operations.renameCalls == [source.path])
        #expect(f.warnings.isEmpty)
        #expect(f.leaser.balance == 0)
    }
}

extension PasteActionServiceTests {
    @Test(arguments: [false, true], [false, true])
    func systemReportedTrashIdentityRefusesAliasesAndDescendants(descendant: Bool, viaLink: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let trash = f.destination.appendingPathComponent("SystemRecycleDirectory")
        let destination = descendant ? trash.appendingPathComponent("sub/deeper") : trash
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // FileManager's system-directory result is injected, never the refusal.
        // The name deliberately matches none of the name-based policy branches.
        f.operations.setTrashDirectories([trash])
        let target: URL
        if viaLink {
            target = f.root.appendingPathComponent("system-trash-alias")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        } else { target = destination }
        #expect(try f.operations.readDestinationRefusal(target.resolvingSymlinksInPath()) == .trash)
        let source = try f.file()
        await f.cut([source]); await f.paste(target)
        #expect(f.operations.renameCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(f.warnings.first?.contains("Use Finder’s Move to Trash") == true)
        #expect(f.service.pendingCut?.paths == [source.path])
        #expect(f.leaser.balance == 0)
    }
}
