import AppKit
import Testing
@testable import RClick

extension PasteActionServiceTests {
    @Test(arguments: ["desktop-subfolder", "outside", "other-provider", "unknown-root"])
    func ubiquitousMovesRespectDestinationSyncState(_ kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = try f.file()
        let root = f.source
        let destination = kind == "desktop-subfolder" ? root.appendingPathComponent("subfolder") : f.destination
        if kind == "desktop-subfolder" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        f.operations.setMoveFacts(MoveFacts(ubiquitous: true, providerContainer: kind == "other-provider" ? root : nil), for: item)
        f.operations.setMoveFacts(MoveFacts(directory: true, ubiquitous: kind != "outside", providerContainer: kind == "other-provider" ? destination : nil), for: destination)
        await f.cut([item]); await f.paste(destination)
        let allowed = kind == "desktop-subfolder" || kind == "unknown-root"
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(item.lastPathComponent).path) == allowed)
        #expect(f.operations.renameCalls.count == (allowed ? 1 : 0))
        #expect(f.warnings.isEmpty == allowed)
    }
}
