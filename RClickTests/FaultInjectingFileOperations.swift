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
        var descriptorPath: URL?
        var renameHook: (@Sendable () throws -> Void)?
        var reportedTrash: [URL]?
        var accountHome: URL?
        var volumeUUIDs: [String: String] = [:]
        var renameErrors: [String: POSIXErrorCode] = [:]
        var providerRoots: [URL]?
        var coordinationWait: (@Sendable (DispatchSemaphore, TimeInterval) -> DispatchTimeoutResult)?
        var coordinationHook: (@Sendable (URL) throws -> Void)?
        var destinationRefusals: [String: DestinationRefusal] = [:]
        var facts: [String: MoveFacts] = [:]
        var renames: [String] = []
        var moveEvents: [String] = []
        var createClash: Set<String> = []
        var failRemoving: Set<String> = []
        var unwritable: Set<String> = []
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
        try throwIfNameExists(at: destination)
        try base.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try throwIfNameExists(at: destination)
        try failHalfwayIfAsked(from: source, to: destination)
        try base.copyItem(at: source, to: destination)
    }

    func volumeIdentity(of url: URL) throws -> VolumeIdentity {
        try adjustedVolume(try base.volumeIdentity(of: url), for: url)
    }

    func fileIdentity(of url: URL) throws -> FileIdentity {
        let identity = try base.fileIdentity(of: url)
        return FileIdentity(volume: adjustedVolume(identity.volume, for: url), fileNumber: identity.fileNumber)
    }

    func reportUnwritable(_ url: URL) {
        faults.withLock { _ = $0.unwritable.insert(url.path) }
    }

    func isWritable(_ url: URL) -> Bool {
        !faults.withLock { $0.unwritable.contains(url.path) } && base.isWritable(url)
    }

    func coordinatedTransfer(_ kind: FileTransferKind, from source: URL, to destination: URL) throws {
        try throwIfNameExists(at: destination)
        if kind == .copy { try failHalfwayIfAsked(from: source, to: destination) }
        try base.coordinatedTransfer(kind, from: source, to: destination)
    }

    func setVolumeUUID(_ uuid: String, for url: URL) { faults.withLock { $0.volumeUUIDs[url.path] = uuid } }
    func volumeUUID(of url: URL) throws -> String {
        if let uuid = faults.withLock({ $0.volumeUUIDs[url.path] }) { return uuid }
        return try base.volumeUUID(of: url)
    }
    func failRename(_ source: URL, with code: POSIXErrorCode) { faults.withLock { $0.renameErrors[source.path] = code } }
    func onNextCoordinationWait(_ wait: @escaping @Sendable (DispatchSemaphore, TimeInterval) -> DispatchTimeoutResult) {
        faults.withLock { $0.coordinationWait = wait }
    }
    func waitForCoordination(_ completion: DispatchSemaphore, timeout: TimeInterval) -> DispatchTimeoutResult {
        let hook = faults.withLock { state in
            let wait = state.coordinationWait
            state.coordinationWait = nil
            return wait
        }
        return hook?(completion, timeout) ?? base.waitForCoordination(completion, timeout: timeout)
    }

    func onNextCoordination(_ action: @escaping @Sendable (URL) throws -> Void) {
        faults.withLock { $0.coordinationHook = action }
    }
    func prepareCoordinatedMove(_ source: URL) throws {
        let hook = faults.withLock { state in
            let value = state.coordinationHook
            state.coordinationHook = nil
            return value
        }
        try hook?(source)
    }

    var moveEvents: [String] { faults.withLock { $0.moveEvents } }
    func notifyMove(_ notification: MoveNotification, using coordinator: NSFileCoordinator, from source: URL, to destination: URL) {
        faults.withLock { $0.moveEvents.append(notification.rawValue) }
        base.notifyMove(notification, using: coordinator, from: source, to: destination)
    }
    var renameCalls: [String] { faults.withLock { $0.renames } }
    func setTrashDirectories(_ directories: [URL]) { faults.withLock { $0.reportedTrash = directories } }
    func trashDirectories() -> [URL] { faults.withLock { $0.reportedTrash } ?? base.trashDirectories() }
    func refuseDestination(_ url: URL, reason: DestinationRefusal) {
        faults.withLock { $0.destinationRefusals[url.path] = reason }
    }
    func setMoveFacts(_ facts: MoveFacts, for url: URL) {
        self.faults.withLock { $0.facts[url.path] = facts }
    }
    func setProviderRoots(_ roots: [URL]) { faults.withLock { $0.providerRoots = roots } }
    func accountHomeDirectory() throws -> URL {
        try faults.withLock { $0.accountHome } ?? base.accountHomeDirectory()
    }
    func setAccountHome(_ home: URL) { faults.withLock { $0.accountHome = home } }
    func providerRootCandidates() throws -> [URL] {
        if let roots = faults.withLock({ $0.providerRoots }) { return roots }
        return try readProviderRootCandidates()
    }
    func moveFacts(of url: URL) throws -> MoveFacts {
        if let value = faults.withLock({ $0.facts[url.path] }) { return value }
        return try readMoveFacts(of: url)
    }
    func destinationRefusal(_ url: URL) throws -> DestinationRefusal? {
        if let value = faults.withLock({ $0.destinationRefusals[url.path] }) { return value }
        return try readDestinationRefusal(url)
    }

    func createClashAtRename(_ url: URL) {
        faults.withLock { _ = $0.createClash.insert(url.path) }
    }

    func reportDescriptorPath(_ path: URL) { faults.withLock { $0.descriptorPath = path } }
    func directoryPath(_ descriptor: Int32) throws -> URL {
        try faults.withLock { $0.descriptorPath } ?? base.directoryPath(descriptor)
    }
    func onNextRename(_ hook: @escaping @Sendable () throws -> Void) { faults.withLock { $0.renameHook = hook } }
    func directoryIdentity(_ descriptor: Int32) throws -> FileIdentity {
        let identity = try base.directoryIdentity(descriptor)
        let path = try base.directoryPath(descriptor)
        return FileIdentity(volume: adjustedVolume(identity.volume, for: path), fileNumber: identity.fileNumber)
    }
    func exclusiveRename(from source: URL, to destination: URL, directory: Int32) throws {
        try recordRename(from: source, to: destination)
        try base.exclusiveRename(from: source, to: destination, directory: directory)
    }

    func exclusiveRename(from source: URL, to destination: URL) throws {
        try recordRename(from: source, to: destination)
        try base.exclusiveRename(from: source, to: destination)
    }

    private func recordRename(from source: URL, to destination: URL) throws {
        let hook = faults.withLock { state in
            let hook = state.renameHook
            state.renameHook = nil
            return hook
        }
        try hook?()
        faults.withLock { $0.renames.append(source.path); $0.moveEvents.append("rename") }
        if let code = faults.withLock({ $0.renameErrors[source.path] }) { throw POSIXError(code) }
        if faults.withLock({ $0.createClash.remove(destination.path) != nil }) {
            try Data("racing owner".utf8).write(to: destination, options: .withoutOverwriting)
        }
    }

    private func throwIfNameExists(at destination: URL) throws {
        guard faults.withLock({ $0.nameExistsAt.contains(destination.path) }) else { return }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
    }

    /// 只写源文件的前一半字节到目标，然后抛错，模拟复制到一半中断。
    private func failHalfwayIfAsked(from source: URL, to destination: URL) throws {
        guard faults.withLock({ $0.copyFailsHalfwayTo.contains(destination.path) }) else { return }
        let data = try Data(contentsOf: source)
        try data.prefix(data.count / 2).write(to: destination)
        throw InjectedFault(operation: "copy", path: destination.path)
    }

    private func adjustedVolume(_ volume: VolumeIdentity, for url: URL) -> VolumeIdentity {
        let elsewhere = faults.withLock { $0.otherVolumePrefixes.contains { url.path.hasPrefix($0) } }
        return elsewhere ? VolumeIdentity(rawValue: ~volume.rawValue) : volume
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
