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
    func removeItem(at url: URL) throws
}

/// 生产实现：直接委托 `FileManager.default`。
nonisolated struct SystemFileOperations: FileOperations {
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
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
