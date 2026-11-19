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
    /// Apply the captured Cut policy to a native item at the delivery/render boundary.
    nonisolated static func renderCutEnablement(
        on item: NSMenuItem, snapshotEnabled: Bool, delivery: IPCExtensionDelivery
    ) {
        item.isEnabled = snapshotEnabled && delivery.isHostAppRunning
    }

    nonisolated struct MenuVisibility {
        let cut: Bool
        let cutEnabled: Bool
        let paste: Bool
        let undo = false
    }

    /// Finder context boundary: a container click must never borrow a selection.
    nonisolated static func targetsForPaste(menuKind: MenuTrigger?, selection: [String], targetedPath: String?) -> [String] {
        switch menuKind {
        case .contextualContainer: return targetedPath.map { [$0] } ?? []
        case .contextualItems: return selection.count == 1 ? selection : []
        default: return []
        }
    }

    /// Pure menu policy; counters are hints checked against the live pasteboard count.
    nonisolated static func menuVisibility(
        config: MenuConfigPayload, menuKind: MenuTrigger?, selection: [String],
        currentChangeCount: Int, hostOnline: Bool
    ) -> MenuVisibility {
        let cut = config.actions.contains { $0.id == "cut" }
            && menuKind == .contextualItems && !selection.isEmpty
        let paste = config.actions.contains { $0.id == "cut" }
            && config.cutChangeCount == currentChangeCount && config.cutItemCount > 0
            && (menuKind == .contextualContainer || (menuKind == .contextualItems && selection.count == 1))
        return MenuVisibility(cut: cut, cutEnabled: cut && hostOnline, paste: paste)
    }

}
