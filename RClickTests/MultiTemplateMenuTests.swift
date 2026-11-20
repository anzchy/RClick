import Foundation
import Testing
import AppKit
@testable import RClick

@MainActor
struct MultiTemplateMenuTests {
    @Test func zeroOneAndManyEntriesProduceDirectOrSubmenuInBothLayouts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("letter.txt")
        try Data("letter".utf8).write(to: path)
        let state = AppState()
        var type = NewFile.txt
        type.templates = []
        type.blankEnabled = false
        state.newFiles = [type]
        for folded in [false, true] {
            #expect(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.isEmpty)
            type.blankEnabled = true
            state.newFiles = [type]
            let blank = try #require(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.first)
            #expect(blank.entries?.map(\.name) == [AppLocalization.localized("Blank")])
            #expect(blank.entries?.first?.id == NewFile.blankTemplateID)
            #expect(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFilesCollapsed == folded)
            #expect(blank.submenuEntries == nil)
            #expect(blank.directTemplateId == NewFile.blankTemplateID)
            type.templates = [.init(id: "letter", name: "Letter", path: path.path),
                .init(id: "disabled", name: "Disabled", enabled: false, path: path.path),
                .init(id: "missing", name: "Missing", path: dir.appendingPathComponent("gone").path)]
            state.newFiles = [type]
            let many = try #require(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.first)
            #expect(many.entries?.map(\.name) == [AppLocalization.localized("Blank"), "Letter"])
            #expect(many.submenuEntries?.map(\.id) == [NewFile.blankTemplateID, "letter"])
            type.blankEnabled = false
            state.newFiles = [type]
            #expect(MenuService().buildConfig(from: state, newFilesCollapsed: folded).newFiles.first?.entries?.map(\.id) == ["letter"])
            type.templates = []
            state.newFiles = [type]
        }
    }
    @Test func finderPreservedTagsResolveEveryDirectAndSubmenuLeafAfterPayloadRoundTrip() throws {
        var items = [NewFileMenuItem(id: "legacy", name: "Legacy", ext: ".txt", icon: "doc")]
        for n in 0..<100 {
            items.append(NewFileMenuItem(id: "type_\(n)", name: "Type", ext: ".txt", icon: "doc",
                entries: (0..<(n % 4 + 1)).map { .init(id: "type_\($0)", name: "Template") }))
        }
        // Ambiguous underscore concatenation and nil/empty must remain distinct.
        items += [.init(id: "a_b", name: "A", ext: ".txt", icon: "doc", entries: [.init(id: "c", name: "C")]),
                  .init(id: "a", name: "A", ext: ".txt", icon: "doc", entries: [.init(id: "b_c", name: "BC")])]
        let config = MenuConfigPayload(version: 1, newFiles: items)
        let decoded = try JSONDecoder().decode(MenuConfigPayload.self, from: JSONEncoder().encode(config))
        var tags = Set<Int>()
        let reserved = Set((0..<100).flatMap { ["app_type_\($0)".hash, "commondir_type_\($0)".hash, "action_type_\($0)".hash] }
            + RCAction.all.map { "action_\($0.id)".hash })
        for item in decoded.newFiles {
            let ids: [String?] = item.entries?.map { Optional($0.id) } ?? [nil]
            for id in ids {
                let leaf = NSMenuItem(title: "Leaf", action: nil, keyEquivalent: "")
                leaf.tag = NewFileMenuItem.leafTag(typeId: item.id, templateId: id)
                // Build the delivered item using only FinderSync-preserved properties.
                let delivered = NSMenuItem(title: leaf.title, action: leaf.action, keyEquivalent: "")
                delivered.tag = leaf.tag
                delivered.image = leaf.image
                delivered.isEnabled = leaf.isEnabled
                delivered.state = leaf.state
                delivered.indentationLevel = leaf.indentationLevel
                #expect(delivered.representedObject == nil)
                #expect(tags.insert(delivered.tag).inserted)
                #expect(!reserved.contains(delivered.tag))
                #expect(NewFileMenuItem.selection(forTag: delivered.tag, in: decoded.newFiles)
                    == .init(typeId: item.id, templateId: id))
            }
        }
        let unknown = (0...).first { !tags.contains($0) }!
        #expect(NewFileMenuItem.selection(forTag: unknown, in: decoded.newFiles) == nil)
    }

}
