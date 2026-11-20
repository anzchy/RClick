import AppKit
import Testing

@testable import RClick

/// Copy Path / Copy File Name 现在作用于全部选中项。这里钉住剪贴板的写入形状：
/// 文本是换行连接的完整列表，Copy Path 只写一个纯文本 item，不写文件 URL。
@MainActor
struct ClipboardTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("RClickTests-\(UUID().uuidString)"))
    }

    @Test func copyPathsWritesSingleAndMultiplePathsAsOneTextOnlyItem() {
        let pasteboard = makePasteboard()

        for (paths, expectedText) in [
            (["/tmp/a.txt"], "/tmp/a.txt"),
            (["/tmp/b.txt", "/tmp/a.txt"], "/tmp/b.txt\n/tmp/a.txt"),
        ] {
            Clipboard.copyPaths(paths, to: pasteboard)

            #expect(pasteboard.string(forType: .string) == expectedText)
            let items = pasteboard.pasteboardItems ?? []
            #expect(items.count == 1)
            #expect(items.first?.types == [.string])
            #expect(items.first?.string(forType: .string) == expectedText)
        }
    }

    @Test func copyPathsPreservesLiteralBytesInOneTextOnlyItem() {
        let pasteboard = makePasteboard()
        let paths = [
            "/tmp/%2544ocuments", "/tmp/%41.txt", "/tmp/100%25 done.txt",
            "/tmp/a%20b.txt", "/tmp/a b.txt", "/tmp/文档 & #?.txt",
            "/tmp/trailing ", "/tmp/line\nbreak.txt", "/tmp/cafe\u{301}.txt",
        ]
        let expectedText = "/tmp/%2544ocuments\n/tmp/%41.txt\n/tmp/100%25 done.txt\n/tmp/a%20b.txt\n/tmp/a b.txt\n/tmp/文档 & #?.txt\n/tmp/trailing \n/tmp/line\nbreak.txt\n/tmp/cafe\u{301}.txt"

        for path in paths {
            Clipboard.copyPaths([path], to: pasteboard)
            #expect(pasteboard.string(forType: .string) == path)
            let text = pasteboard.string(forType: .string)
            #expect(text.map { Array($0.utf8) } == Array(path.utf8))
            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(pasteboard.pasteboardItems?.first?.types == [.string])
        }

        Clipboard.copyPaths(paths, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == expectedText)
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(items.first?.types == [.string])
        #expect(items.first?.string(forType: .string).map { Array($0.utf8) } == Array(expectedText.utf8))
    }

    @Test func copyFileNamesWritesOneNamePerLineAndNoFileURLs() {
        let pasteboard = makePasteboard()
        let paths = [
            "/tmp/%2544ocuments", "/tmp/%41.txt", "/tmp/100%25 done.txt",
            "/tmp/a%20b.txt", "/tmp/a b.txt", "/tmp/文档 & #?.txt",
        ]
        let names = ["%2544ocuments", "%41.txt", "100%25 done.txt", "a%20b.txt", "a b.txt", "文档 & #?.txt"]

        for (path, name) in zip(paths, names) {
            Clipboard.copyFileNames([path], to: pasteboard)
            #expect(pasteboard.string(forType: .string) == name)
            #expect(pasteboard.pasteboardItems?.contains { $0.string(forType: .fileURL) != nil } == false)
        }

        Clipboard.copyFileNames(paths, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "%2544ocuments\n%41.txt\n100%25 done.txt\na%20b.txt\na b.txt\n文档 & #?.txt")
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
