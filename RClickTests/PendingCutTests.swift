import AppKit
import Testing
@testable import RClick

@MainActor
struct PendingCutTests {
    private final class ObservedPasteboard: CutPasteboard {
        let board: NSPasteboard
        var options: NSPasteboard.ContentsOptions?
        var failure: String?
        init(_ board: NSPasteboard) { self.board = board }
        var changeCount: Int { board.changeCount }
        var types: [NSPasteboard.PasteboardType]? {
            let snapshot = board.types
            if failure == "replaced" {
                board.clearContents()
                board.setString("another owner", forType: .string)
            }
            return failure == "missing-marker" ? snapshot?.filter { $0 != PendingCut.markerType } : snapshot
        }
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            self.options = options
            return board.prepareForNewContents(with: options)
        }
        func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
            failure == "write-rejected" ? false : board.writeObjects(objects)
        }
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

    @Test func menuVisibilityTableIncludesOfflineAndLegacyConfigs() throws {
        let old = Data(#"{"version":1,"actions":[],"apps":[],"newFiles":[],"commonDirs":[],"actionsCollapsed":false,"appsCollapsed":false,"newFilesCollapsed":true,"commonDirsCollapsed":true}"#.utf8)
        let legacy = try JSONDecoder().decode(MenuConfigPayload.self, from: old)
        let action = ActionMenuItem(id: "cut", name: "Cut & Paste", icon: "scissors", tag: 6)
        // Literal policy rows from #8; expected visibility is not derived from the implementation.
        let rows: [(MenuTrigger?, [String], Bool)] = [
            (.contextualItems, [], false), (.contextualItems, ["/tmp/a"], true),
            (.contextualItems, ["/tmp/a", "/tmp/b"], true),
            (.contextualContainer, [], false), (.contextualContainer, ["/tmp/a"], false),
            (.contextualContainer, ["/tmp/a", "/tmp/b"], false),
            (.contextualSidebar, [], false), (.contextualSidebar, ["/tmp/a"], false),
            (.contextualSidebar, ["/tmp/a", "/tmp/b"], false),
            (.toolbar, [], false), (.toolbar, ["/tmp/a"], false),
            (.toolbar, ["/tmp/a", "/tmp/b"], false),
            (nil, [], false), (nil, ["/tmp/a"], false), (nil, ["/tmp/a", "/tmp/b"], false),
        ]
        for (kind, selection, eligible) in rows {
            for enabled in [false, true] {
                for online in [false, true] {
                    for count in [41, 42] {
                        let configs: [(MenuConfigPayload, Bool, Bool)] = [
                            (legacy, false, false),
                            (MenuConfigPayload(actions: enabled ? [action] : []), enabled, false),
                            (MenuConfigPayload(actions: enabled ? [action] : [], cutChangeCount: 42, cutItemCount: 2), enabled, true),
                        ]
                        for (config, actionEnabled, hasCut) in configs {
                            let result = PendingCut.menuVisibility(config: config, menuKind: kind,
                                selection: selection, currentChangeCount: count, hostOnline: online)
                            #expect(result.cut == (eligible && actionEnabled))
                            #expect(result.cutEnabled == (eligible && actionEnabled && online))
                            let pasteEligible = kind == .contextualContainer || (kind == .contextualItems && selection.count == 1)
                            #expect(result.paste == (actionEnabled && hasCut && count == 42 && pasteEligible))
                            #expect(!result.undo)
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: ["write-rejected", "missing-marker", "replaced"])
    func unverifiedWriteNeverReturnsAPendingCounter(failure: String) {
        let board = NSPasteboard(name: .init("RClickTests-cut-\(UUID())"))
        defer { board.releaseGlobally() }
        let observed = ObservedPasteboard(board)
        observed.failure = failure
        #expect(PendingCut(pasteboard: observed).writeCut(["/tmp/a.txt"]) == nil)
        if failure == "replaced" {
            #expect(board.string(forType: .string) == "another owner")
        }
    }

    @Test func pasteTargetsRequireTheClickedContainerOrExactlyOneItem() {
        #expect(PendingCut.targetsForPaste(menuKind: .contextualContainer, selection: ["/selected-folder"], targetedPath: nil) == [])
        #expect(PendingCut.targetsForPaste(menuKind: .contextualContainer, selection: ["/selected-folder"], targetedPath: "/clicked-folder") == ["/clicked-folder"])
        #expect(PendingCut.targetsForPaste(menuKind: .contextualItems, selection: ["/selected-folder"], targetedPath: "/parent") == ["/selected-folder"])
        #expect(PendingCut.targetsForPaste(menuKind: .contextualItems, selection: ["/a", "/b"], targetedPath: "/parent") == [])
        #expect(PendingCut.targetsForPaste(menuKind: .contextualItems, selection: [], targetedPath: "/parent") == [])
        for kind: MenuTrigger? in [.contextualSidebar, .toolbar, nil] {
            #expect(PendingCut.targetsForPaste(menuKind: kind, selection: ["/selected-folder"], targetedPath: "/parent") == [])
        }
    }

}
