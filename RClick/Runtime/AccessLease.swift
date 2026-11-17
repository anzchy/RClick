//
//  AccessLease.swift
//  RClick
//
//  一次文件操作期间持有的目录访问租约。
//  删除在 ActionExecutor 上跑时主线程是空闲的，用户可以在设置页撤销文件夹授权
//  （BookmarkManager.removeDirectory → stopAccessingSecurityScopedResource）。
//  租约为覆盖目标目录的书签另开一份 security-scoped 访问，直到操作结束；
//  撤销只停掉 BookmarkManager 自己那一份，进行中的批次不会删到一半失去权限。
//

import Foundation
import SwiftData

/// 为一次文件操作开启目录访问。
@MainActor
protocol ScopedAccessLeasing: AnyObject {
    /// 为覆盖这些目录的授权各开一份访问，直到返回的租约 `end()`。
    func beginAccess(covering directories: [URL]) -> ScopedAccessLease
}

/// 一次操作持有的访问；`end()` 恰好调用一次，与开启的访问一一配对。
struct ScopedAccessLease: Sendable {
    /// 本租约开启了访问的授权目录（书签解析出的 URL）。
    let directories: [URL]
    private let endAccess: @Sendable () -> Void

    init(directories: [URL] = [], end: @escaping @Sendable () -> Void = {}) {
        self.directories = directories
        self.endAccess = end
    }

    func end() {
        endAccess()
    }
}

/// 生产实现：从 SwiftData 读出已存的书签，为覆盖目标目录的那些各 startAccessing 一次。
@MainActor
final class BookmarkAccessLeaser: ScopedAccessLeasing {
    private let loadBookmarks: @MainActor () -> [Data]

    init(loadBookmarks: @escaping @MainActor () -> [Data] = BookmarkAccessLeaser.storedBookmarks) {
        self.loadBookmarks = loadBookmarks
    }

    static func storedBookmarks() -> [Data] {
        let context = ModelContext(SharedDataManager.sharedModelContainer)
        let entities = (try? context.fetch(FetchDescriptor<BookmarkEntity>())) ?? []
        return entities.map(\.bookmarkData)
    }

    func beginAccess(covering directories: [URL]) -> ScopedAccessLease {
        let targets = directories.map { $0.resolvingSymlinksInPath() }
        guard !targets.isEmpty else { return ScopedAccessLease() }

        var opened: [URL] = []
        for data in loadBookmarks() {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            let root = url.resolvingSymlinksInPath()
            guard targets.contains(where: { BookmarkManager.covers(root, $0) }) else { continue }
            // 与 BookmarkManager 的那份访问互不影响：每次 startAccessing 都要有自己的 stop。
            if url.startAccessingSecurityScopedResource() {
                opened.append(url)
            }
        }
        let leased = opened
        return ScopedAccessLease(directories: leased) {
            for url in leased {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
