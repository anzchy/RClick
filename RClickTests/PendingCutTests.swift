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
    @Test func pendingEndsAfterAnyOtherWriteWithoutReadingContents() throws {
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        let helper = PendingCut(pasteboard: board)
        let count = try #require(helper.writeCut(["/tmp/a.txt"]))
        #expect(helper.isStillPending(count))
        board.clearContents()
        board.setString("another copy", forType: .string)
        #expect(!helper.isStillPending(count))
        let next = try #require(helper.writeCut(["/tmp/b.txt"]))
        #expect(helper.isStillPending(next))
        board.clearContents()
        #expect(!helper.isStillPending(next))
    }

    @Test func emptyCutLeavesExistingClipboardAndCounterUntouched() {
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let before = board.changeCount
        #expect(PendingCut(pasteboard: board).writeCut([]) == nil)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "keep")
    }

}
