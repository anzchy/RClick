import Foundation
import Testing
@testable import RClick

@MainActor
struct TemplateStoreTests {
    @Test func sameNamedImportsNeverAliasOrOverwriteOriginals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a/same.txt")
        let b = dir.appendingPathComponent("b/same.txt")
        for url in [a, b] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let one = try store.importFile(a)
        let two = try store.importFile(b)
        #expect(one.path != two.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(one.path))) == Data("first".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(two.path))) == Data("second".utf8))
        #expect(try Data(contentsOf: a) == Data("first".utf8))
    }
    @Test func cancellingDraftLeavesNoCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.txt")
        try Data("snapshot".utf8).write(to: source)
        let root = dir.appendingPathComponent("Templates")
        let store = TemplateStore(baseURL: root)
        var draft = TemplateDraft(file: .txt)
        try draft.add(source, store: store)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(draft.entries.map(\.name) == ["source.txt"])
    }

}
