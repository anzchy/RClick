//
//  FileOperations.swift
//  RClick
//
//  动作代码依赖的文件操作层。生产实现包装 FileManager；
//  单测注入可按需失败的版本（删除失败、复制中途失败、重名、不同卷等）。
//  所有成员都是 nonisolated + Sendable：ActionService 会把它交给 ActionExecutor 在后台跑。
//

import Foundation

nonisolated protocol FileOperations: Sendable {
    func volumeUUID(of url: URL) throws -> String
    func accountHomeDirectory() throws -> URL
    func providerRootCandidates() throws -> [URL]
    func moveFacts(of url: URL) throws -> MoveFacts
    func destinationRefusal(_ url: URL) throws -> DestinationRefusal?
    func exclusiveRename(from source: URL, to destination: URL) throws
    func prepareCoordinatedMove(_ source: URL) throws
    func coordinatedExclusiveMove(from source: URL, to destination: URL, expected: FileIdentity, timeout: TimeInterval) throws
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    /// 条目所在的卷（不跟随末端符号链接）。同卷才能原子 rename。
    func volumeIdentity(of url: URL) throws -> VolumeIdentity
    /// 条目自身的身份（卷 + 文件号），用于确认「还是同一个文件」。
    func fileIdentity(of url: URL) throws -> FileIdentity
    func isWritable(_ url: URL) -> Bool
    /// 经 NSFileCoordinator 协调的移动或复制，让其他进程的 file presenter 得到通知。
    func coordinatedTransfer(_ kind: FileTransferKind, from source: URL, to destination: URL) throws
}

nonisolated enum FileTransferKind: Sendable {
    case move
    case copy
}

/// 卷身份：`stat` 的 `st_dev`。
nonisolated struct VolumeIdentity: Hashable, Sendable {
    let rawValue: UInt64
}

/// 文件身份：卷 + `st_ino`。
nonisolated struct FileIdentity: Hashable, Sendable {
    let volume: VolumeIdentity
    let fileNumber: UInt64
}

/// 生产实现：委托 `FileManager.default` 与 `NSFileCoordinator`。
nonisolated struct SystemFileOperations: FileOperations {
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func volumeIdentity(of url: URL) throws -> VolumeIdentity {
        try fileIdentity(of: url).volume
    }

    func fileIdentity(of url: URL) throws -> FileIdentity {
        // attributesOfItem 走 lstat：符号链接报告链接自身，而不是它指向的文件。
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileIdentity(
            volume: VolumeIdentity(rawValue: device.uint64Value),
            fileNumber: inode.uint64Value
        )
    }

    func isWritable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.path)
    }

    func coordinatedTransfer(_ kind: FileTransferKind, from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: (any Error)?

        switch kind {
        case .move:
            coordinator.coordinate(
                writingItemAt: source, options: .forMoving,
                writingItemAt: destination, options: .forReplacing,
                error: &coordinationError
            ) { from, to in
                do {
                    coordinator.item(at: from, willMoveTo: to)
                    try FileManager.default.moveItem(at: from, to: to)
                    coordinator.item(at: from, didMoveTo: to)
                } catch {
                    operationError = error
                }
            }
        case .copy:
            coordinator.coordinate(
                readingItemAt: source, options: [],
                writingItemAt: destination, options: .forReplacing,
                error: &coordinationError
            ) { from, to in
                do {
                    try FileManager.default.copyItem(at: from, to: to)
                } catch {
                    operationError = error
                }
            }
        }

        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}

/// 一次文件动作的结果：哪些路径做成了，哪些失败了以及原因。
nonisolated struct FileActionResult: Sendable {
    var journalNeedsRecovery = false
    var completed: [String] = []
    var failures: [FileActionFailure] = []
}

nonisolated struct FileActionFailure: Sendable {
    let path: String
    let error: any Error
}
