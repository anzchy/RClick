//
//  BookmarkAccessLeaserTests.swift
//  RClickTests
//
//  生产租约：从存好的书签里挑出覆盖目标目录的那些，为它们开启访问。
//

import Foundation
import Testing
@testable import RClick

@MainActor
struct BookmarkAccessLeaserTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @Test func leaseOpensAccessOnlyForBookmarksCoveringTheTargets() throws {
        let granted = try makeTempDir()
        let unrelated = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: granted)
            try? FileManager.default.removeItem(at: unrelated)
        }
        let target = granted.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let stored = [try bookmark(unrelated), Data("not a bookmark".utf8), try bookmark(granted)]
        let leaser = BookmarkAccessLeaser(loadBookmarks: { stored })

        let lease = leaser.beginAccess(covering: [target])
        defer { lease.end() }

        #expect(lease.directories.map { $0.resolvingSymlinksInPath().path }
                == [granted.resolvingSymlinksInPath().path])
    }

    @Test func noTargetsOpensNothing() throws {
        let granted = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: granted) }
        let stored = [try bookmark(granted)]
        let leaser = BookmarkAccessLeaser(loadBookmarks: { stored })

        let lease = leaser.beginAccess(covering: [])
        defer { lease.end() }

        #expect(lease.directories.isEmpty)
    }
}
