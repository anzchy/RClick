import AppKit
import Testing

@testable import RClick

/// Copy Path / Copy File Name 现在作用于全部选中项。这里钉住剪贴板的写入形状：
/// 文本是换行连接的完整列表，文件 URL 只给 Copy Path，且完整文本只挂在第一项上。
@MainActor
struct ClipboardTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("RClickTests-\(UUID().uuidString)"))
    }

    @Test func copyPathsWritesEveryPathAsTextAndFileURLs() {
        let pasteboard = makePasteboard()

        Clipboard.copyPaths(["/tmp/a.txt", "/tmp/b.txt"], to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "/tmp/a.txt\n/tmp/b.txt")
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items[0].string(forType: .fileURL) == "file:///tmp/a.txt")
        #expect(items[1].string(forType: .fileURL) == "file:///tmp/b.txt")
    }

    @Test func copyPathsPreservesRawPathsInTextAndFileURLs() {
        let pasteboard = makePasteboard()
        let paths = [
            "/tmp/%2544ocuments", "/tmp/%41.txt", "/tmp/100%25 done.txt",
            "/tmp/a%20b.txt", "/tmp/a b.txt", "/tmp/文档 & #?.txt",
        ]
        let expectedText = "/tmp/%2544ocuments\n/tmp/%41.txt\n/tmp/100%25 done.txt\n/tmp/a%20b.txt\n/tmp/a b.txt\n/tmp/文档 & #?.txt"

        for path in paths {
            Clipboard.copyPaths([path], to: pasteboard)
            #expect(pasteboard.string(forType: .string) == path)
            let fileURL = pasteboard.pasteboardItems?.first?.string(forType: .fileURL)
            #expect(fileURL.flatMap(URL.init(string:))?.path == path)
        }

        Clipboard.copyPaths(paths, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == expectedText)
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == paths.count)
        #expect(items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.path } == paths)
        #expect(items.dropFirst().allSatisfy { $0.string(forType: .string) == nil })
    }

    @Test func copyFileNamesWritesOneNamePerLineAndNoFileURLs() {
        let pasteboard = makePasteboard()

        Clipboard.copyFileNames(["/tmp/a.txt", "/tmp/folder/b%20c.md"], to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "a.txt\nb c.md")
        #expect(pasteboard.pasteboardItems?.contains { $0.string(forType: .fileURL) != nil } == false)
    }

    @Test func emptySelectionLeavesThePasteboardUntouched() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)

        Clipboard.copyPaths([], to: pasteboard)
        Clipboard.copyFileNames([], to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "keep")
    }
}
