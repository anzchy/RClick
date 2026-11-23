import Foundation
import Testing
import SwiftData
import Synchronization

@testable import RClick

/// `BookmarkManager.covers` 决定一个已授权的目录是否覆盖某条路径。
///
/// 它原先用字符串前缀做匹配，于是悄悄坏掉了用户在"怎么授权都不管用"时最会去试的
/// 那一个目录：`/`。`dirPath + "/"` 对根目录拼出 `"//"`，没有任何路径以它开头，
/// 所以把 `/` 加进授权列表等于什么都没加 —— 用户越授权越用不了（Issue #155）。
///
/// 入参约定是"已解析符号链接"的路径（调用点负责），所以这里直接喂普通路径即可。
struct BookmarkAccessTests {
    private func at(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func rootCoversEverything() {
        #expect(BookmarkManager.covers(at("/"), at("/Users/test/Desktop")))
        #expect(BookmarkManager.covers(at("/"), at("/Volumes/Installer")))
        #expect(BookmarkManager.covers(at("/"), at("/")))
    }

    @Test func folderCoversItselfAndItsDescendants() {
        #expect(BookmarkManager.covers(at("/Users/test"), at("/Users/test")))
        #expect(BookmarkManager.covers(at("/Users/test"), at("/Users/test/Desktop")))
        #expect(BookmarkManager.covers(at("/Users/test/Desktop"), at("/Users/test/Desktop/a.txt")))
    }

    @Test func folderDoesNotCoverSiblingsOrAncestors() {
        #expect(!BookmarkManager.covers(at("/Users/test/Desktop"), at("/Users/test/Movies")))
        #expect(!BookmarkManager.covers(at("/Users/test/Desktop"), at("/Users/test")))
        #expect(!BookmarkManager.covers(at("/Users/test/Desktop"), at("/")))
    }

    /// 按分量比较不能比原来按字符串比较更松：共享前缀的兄弟目录必须仍然不覆盖。
    @Test func siblingSharingAPrefixIsNotCovered() {
        #expect(!BookmarkManager.covers(at("/Users/test"), at("/Users/test2")))
        #expect(!BookmarkManager.covers(at("/Volumes/Disk"), at("/Volumes/Disk2/file")))
    }
}


@MainActor
struct BookmarkLoggingTests {
    nonisolated final class Recorder: Sendable {
        let lines = Mutex<[String]>([])
        func record(_ line: String) { lines.withLock { $0.append(line) } }
    }

    @Test(arguments: ["save", "restore", "stale", "remove", "saveFailure", "restoreFailure"])
    func bookmarkLogsExcludeFolder(operation: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SECRET-dir-%41-ü-\(UUID())")
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let recorder = Recorder()
        let manager = BookmarkManager(logSink: { recorder.record($0) })
        let container = try ModelContainer(for: BookmarkEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        switch operation {
        case "save", "remove":
            manager.saveBookmark(for: root)
            #expect(manager.hasAccess(to: root))
            manager.removeDirectory(root)
            #expect(!manager.hasAccess(to: root))
        case "restore", "stale":
            let data = try root.bookmarkData(options: .withSecurityScope)
            if operation == "stale" {
                try FileManager.default.moveItem(at: root, to: moved)
                var stale = false
                _ = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                try #require(stale, "The fixture must exercise stale refresh")
            }
            context.insert(BookmarkEntity(bookmarkData: data, pathString: root.path))
            try context.save()
            manager.restoreBookmarks(context: context)
            #expect(manager.hasAccess(to: operation == "stale" ? moved : root))
            for url in manager.authorizedDirectories { url.stopAccessingSecurityScopedResource() }
        case "saveFailure":
            manager.saveBookmark(for: root.appendingPathComponent("missing/SECRET-dir-%41-ü"))
            #expect(manager.authorizedDirectories.isEmpty)
        case "restoreFailure":
            context.insert(BookmarkEntity(bookmarkData: Data(), pathString: root.path))
            try context.save()
            manager.restoreBookmarks(context: context)
            #expect(manager.authorizedDirectories.isEmpty)
        default: Issue.record("Unknown bookmark operation")
        }
        let lines = recorder.lines.withLock { $0 }
        #expect(!lines.isEmpty, "A disconnected bookmark sink must fail")
        let known = ["save": "Bookmark saved; count=1", "remove": "Bookmark removed; count=1",
            "restore": "Bookmark restored; count=1", "stale": "Bookmark restored; count=1",
            "saveFailure": "Bookmark save failed;", "restoreFailure": "Bookmark restore failed;"][operation]!
        #expect(lines.contains { $0.contains(known) }, "A known bookmark outcome must reach the sink")
        for secret in [root.path, root.lastPathComponent, "%41", "SECRET-", "ü"] {
            #expect(!lines.contains { $0.contains(secret) }, "Folder text reached the bookmark log sink")
        }
    }
}
