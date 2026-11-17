//
//  FaultInjectingFileOperations.swift
//  RClickTests
//
//  测试替身：默认把每个操作交给真实的 SystemFileOperations，
//  按需注入失败（删除失败等），让测试能在 ActionService 的接缝上观察失败如何传到动作结果。
//

import Foundation
import Synchronization
@testable import RClick

final class FaultInjectingFileOperations: FileOperations {
    /// 替身主动抛出的错误，测试据此确认失败来自注入点而不是真实文件系统。
    struct InjectedFault: Error, Equatable {
        let operation: String
        let path: String
    }

    private struct Faults {
        var failRemoving: Set<String> = []
        var removeCalls: [String] = []
        var copyFailsHalfwayTo: Set<String> = []
        var nameExistsAt: Set<String> = []
        var otherVolumePrefixes: [String] = []
    }

    private let base: any FileOperations
    private let faults = Mutex(Faults())

    init(base: any FileOperations = SystemFileOperations()) {
        self.base = base
    }

    /// 让该路径的删除失败（原件保留），模拟「原件无法删除」。
    func failRemoving(_ path: String) {
        faults.withLock { _ = $0.failRemoving.insert(path) }
    }

    var removeCalls: [String] { faults.withLock { $0.removeCalls } }

    /// 复制到该目标时只写一半就失败：目标处留下残缺副本，原件不动。
    func failCopyHalfway(to destination: String) {
        faults.withLock { _ = $0.copyFailsHalfwayTo.insert(destination) }
    }

    /// 移动或复制到该目标时报「名字已存在」，即使磁盘上并没有这个文件。
    func reportNameExists(at destination: String) {
        faults.withLock { _ = $0.nameExistsAt.insert(destination) }
    }

    /// 该前缀下的条目报告一个与真实卷不同的卷身份。
    func placeOnOtherVolume(_ pathPrefix: String) {
        faults.withLock { $0.otherVolumePrefixes.append(pathPrefix) }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func volumeIdentity(of url: URL) throws -> VolumeIdentity {
        try base.volumeIdentity(of: url)
    }

    func fileIdentity(of url: URL) throws -> FileIdentity {
        try base.fileIdentity(of: url)
    }

    func isWritable(_ url: URL) -> Bool {
        base.isWritable(url)
    }

    func coordinatedTransfer(_ kind: FileTransferKind, from source: URL, to destination: URL) throws {
        try base.coordinatedTransfer(kind, from: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        let shouldFail = faults.withLock {
            $0.removeCalls.append(url.path)
            return $0.failRemoving.contains(url.path)
        }
        if shouldFail { throw InjectedFault(operation: "remove", path: url.path) }
        try base.removeItem(at: url)
    }
}
