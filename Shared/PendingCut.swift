import AppKit

/// Pasteboard system boundary, also usable with a private pasteboard in tests.
@MainActor
protocol CutPasteboard {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: CutPasteboard {}

/// Host-owned pending cut signal. The pasteboard is never a store of move state.
@MainActor
struct PendingCut {
    static let markerType = NSPasteboard.PasteboardType("cn.anzchy.RClick.cut")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    let pasteboard: any CutPasteboard

    init(pasteboard: any CutPasteboard = NSPasteboard.general) {
        self.pasteboard = pasteboard
    }

    func isStillPending(_ changeCount: Int) -> Bool { pasteboard.changeCount == changeCount }

    func writeCut(_ paths: [String]) -> Int? {
        guard !paths.isEmpty else { return nil }
        let items = paths.enumerated().map { index, path in
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            if index == 0 {
                item.setString("1", forType: Self.markerType)
                item.setString("cn.anzchy.RClick", forType: Self.sourceType)
            }
            return item
        }
        let count = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects(items),
              let types = pasteboard.types,
              types.contains(.fileURL), types.contains(Self.markerType), types.contains(Self.sourceType),
              pasteboard.changeCount == count else { return nil }
        return count
    }
    nonisolated struct MenuVisibility {
        let cut: Bool
        let cutEnabled: Bool
        // Reserved for the later move/undo slices; neither is offered yet.
        let paste = false
        let undo = false
    }

    /// Pure menu policy. The counter parameter is reserved for the Paste slice.
    nonisolated static func menuVisibility(
        config: MenuConfigPayload, menuKind: MenuTrigger?, selection: [String],
        currentChangeCount: Int, hostOnline: Bool
    ) -> MenuVisibility {
        let cut = config.actions.contains { $0.id == "cut" }
            && menuKind == .contextualItems && !selection.isEmpty
        return MenuVisibility(cut: cut, cutEnabled: cut && hostOnline)
    }

}
