import AppKit
import Testing
@testable import RClick

@MainActor
struct PendingCutTests {
    private final class ObservedPasteboard: CutPasteboard {
        let board: NSPasteboard
        var options: NSPasteboard.ContentsOptions?
        init(_ board: NSPasteboard) { self.board = board }
        var changeCount: Int { board.changeCount }
        var types: [NSPasteboard.PasteboardType]? { board.types }
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            self.options = options
            return board.prepareForNewContents(with: options)
        }
        func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool { board.writeObjects(objects) }
    }

    @Test func writesHostOnlyFileURLsMarkerAndSourceAndReturnsVerifiedCount() throws {
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        let observed = ObservedPasteboard(board)
        let helper = PendingCut(pasteboard: observed)
        let count = try #require(helper.writeCut(["/tmp/a%20b.txt", "/tmp/other.txt"]))
        #expect(count == board.changeCount)
        let items = try #require(board.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .fileURL) == "file:///tmp/a%2520b.txt")
        #expect(items[1].string(forType: .fileURL) == "file:///tmp/other.txt")
        #expect(board.types?.contains(PendingCut.markerType) == true)
        #expect(board.string(forType: PendingCut.sourceType) == "cn.anzchy.RClick")
        #expect(observed.options == .currentHostOnly)
    }
}
