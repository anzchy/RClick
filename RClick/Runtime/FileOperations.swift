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
        throw CocoaError(.featureUnsupported)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        throw CocoaError(.featureUnsupported)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func volumeIdentity(of url: URL) throws -> VolumeIdentity {
        throw CocoaError(.featureUnsupported)
    }

    func fileIdentity(of url: URL) throws -> FileIdentity {
        throw CocoaError(.featureUnsupported)
    }

    func isWritable(_ url: URL) -> Bool {
        false
    }

    func coordinatedTransfer(_ kind: FileTransferKind, from source: URL, to destination: URL) throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// 一次文件动作的结果：哪些路径做成了，哪些失败了以及原因。
nonisolated struct FileActionResult: Sendable {
    var completed: [String] = []
    var failures: [FileActionFailure] = []
}

nonisolated struct FileActionFailure: Sendable {
    let path: String
    let error: any Error
}
