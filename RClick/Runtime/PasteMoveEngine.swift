import Foundation
import Darwin
import Synchronization

nonisolated enum MoveNotification: String, Sendable { case willMoveTo, didMoveTo }

nonisolated enum PasteMoveError: Error {
    case changed, destinationChanged, invalidDestination, crossVolume, insideSource, mountPoint, cloud, timeout
}

extension SystemFileOperations {
    /// The kernel, not a preflight existence check, enforces no-overwrite.
    nonisolated func exclusiveRename(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

extension FileOperations {
    nonisolated func openMoveDirectory(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }
    nonisolated func closeMoveDirectory(_ descriptor: Int32) { _ = close(descriptor) }
    nonisolated func directoryIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw PasteMoveError.destinationChanged
        }
        return FileIdentity(volume: VolumeIdentity(rawValue: UInt64(UInt32(bitPattern: info.st_dev))), fileNumber: info.st_ino)
    }
    nonisolated func directoryPath(_ descriptor: Int32) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).standardizedFileURL
    }
    nonisolated func exclusiveRename(from source: URL, to destination: URL, directory: Int32) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.lastPathComponent.withCString { name in
                renameatx_np(AT_FDCWD, from, directory, name, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    nonisolated func notifyMove(_ notification: MoveNotification, using coordinator: NSFileCoordinator, from source: URL, to destination: URL) {
        switch notification {
        case .willMoveTo: coordinator.item(at: source, willMoveTo: destination)
        case .didMoveTo: coordinator.item(at: source, didMoveTo: destination)
        }
    }
    nonisolated func exclusiveRename(from source: URL, to destination: URL) throws {
        try SystemFileOperations().exclusiveRename(from: source, to: destination)
    }
    nonisolated func waitForCoordination(_ completion: DispatchSemaphore, timeout: TimeInterval) -> DispatchTimeoutResult {
        completion.wait(timeout: .now() + max(0, timeout))
    }
    nonisolated func prepareCoordinatedMove(_ source: URL) throws {}
    nonisolated func coordinatedExclusiveMove(from source: URL, to destination: URL, expected: FileIdentity, expectedDestination: FileIdentity, timeout: TimeInterval) throws {
        let job = MoveCoordinationJob()
        let done = DispatchSemaphore(value: 0)
        // A dedicated Foundation thread keeps blocking file presenters off both
        // the cooperative executor and libdispatch's shared worker pool.
        let worker = Thread {
            var coordinationError: NSError?
            job.coordinator.coordinate(writingItemAt: source, options: .forMoving,
                writingItemAt: destination, options: [], error: &coordinationError) { from, to in
                do {
                    try prepareCoordinatedMove(from)
                    let moved = try job.state.withLock { state in
                        guard !state.cancelled else { throw PasteMoveError.timeout }
                        guard try fileIdentity(of: from) == expected else { throw PasteMoveError.changed }
                        notifyMove(.willMoveTo, using: job.coordinator, from: from, to: to)
                        // Pin the directory, classify the kernel's path for that open
                        // object, then rename relative to it. A replaced ancestor must
                        // never redirect the write through the lexical destination.
                        let directory: Int32
                        do { directory = try openMoveDirectory(to.deletingLastPathComponent()) }
                        catch { throw PasteMoveError.destinationChanged }
                        defer { closeMoveDirectory(directory) }
                        do {
                            let identity = try directoryIdentity(directory)
                            let folder = try directoryPath(directory)
                            guard identity == expectedDestination,
                                  identity.volume == expected.volume,
                                  try volumeIdentity(of: folder) == expected.volume,
                                  try destinationRefusal(folder) == nil,
                                  try !sameItem(from.deletingLastPathComponent(), folder),
                                  try directoryPath(directory) == folder else {
                                throw PasteMoveError.destinationChanged
                            }
                        } catch { throw PasteMoveError.destinationChanged }
                        try exclusiveRename(from: from, to: to, directory: directory)
                        state.moved = true
                        return true
                    }
                    if moved { notifyMove(.didMoveTo, using: job.coordinator, from: from, to: to) }
                } catch {
                    job.state.withLock { $0.error = error }
                }
            }
            job.state.withLock { state in
                if !state.moved, state.error == nil { state.error = coordinationError }
            }
            done.signal()
        }
        worker.qualityOfService = .userInitiated
        worker.name = "RClick.PasteCoordinator"
        worker.start()
        if waitForCoordination(done, timeout: timeout) == .timedOut {
            let moved = job.state.withLock { state in
                state.cancelled = true // A late accessor can no longer rename.
                return state.moved
            }
            job.coordinator.cancel()
            if moved { return }
            throw PasteMoveError.timeout
        }
        try job.state.withLock { state in
            if let error = state.error { throw error }
            guard state.moved else { throw PasteMoveError.timeout }
        }
    }
}

nonisolated struct MoveFacts: Sendable {
    var directory = false
    var package = false
    var mountPoint = false
    var caseSensitiveNames = false
    var ubiquitous = false
    var providerContainer: URL?
}

nonisolated enum DestinationRefusal: String, Error {
    case systemRoot, trash, package, notFolder
}

extension FileOperations {
    nonisolated func sameItem(_ lhs: URL, _ rhs: URL) throws -> Bool {
        try fileIdentity(of: lhs) == fileIdentity(of: rhs)
    }

    nonisolated func contains(_ root: URL, _ item: URL) throws -> Bool {
        if try sameItem(root, item) { return true }
        var relationship: FileManager.URLRelationship = .other
        try FileManager.default.getRelationship(&relationship, ofDirectoryAt: root, toItemAt: item)
        return relationship == .contains
    }

    nonisolated func providerRootCandidates() throws -> [URL] {
        try readProviderRootCandidates()
    }
    nonisolated func readProviderRootCandidates() throws -> [URL] {
        let home = try accountHomeDirectory()
        return [home.appendingPathComponent("Library/Mobile Documents"), home.appendingPathComponent("Library/CloudStorage")]
    }
    nonisolated func moveFacts(of url: URL) throws -> MoveFacts { try readMoveFacts(of: url) }
    nonisolated func readMoveFacts(of url: URL) throws -> MoveFacts {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directory = attributes[.type] as? FileAttributeType == .typeDirectory
        let values = try url.resourceValues(forKeys: [.isPackageKey, .isVolumeKey, .isUbiquitousItemKey, .volumeSupportsCaseSensitiveNamesKey])
        var facts = MoveFacts(directory: directory, package: directory && values.isPackage == true,
                              mountPoint: directory && values.isVolume == true,
                              caseSensitiveNames: values.volumeSupportsCaseSensitiveNames == true,
                              ubiquitous: values.isUbiquitousItem == true)
        // Walk canonical ancestors. Do not treat an inaccessible provider root
        // as absent: once its name is encountered, identity errors fail closed.
        for root in try providerRootCandidates() {
            if url.lastPathComponent.caseInsensitiveCompare(root.lastPathComponent) == .orderedSame, try sameItem(url, root) {
                facts.providerContainer = root
                break
            }
            var ancestor = url.deletingLastPathComponent().standardizedFileURL
            var container = url
            while true {
                if ancestor.lastPathComponent.caseInsensitiveCompare(root.lastPathComponent) == .orderedSame,
                   try sameItem(ancestor, root) {
                    facts.providerContainer = container
                    break
                }
                if ancestor.path == "/" { break }
                container = ancestor
                ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
            }
            if facts.providerContainer != nil { break }
        }
        if facts.ubiquitous, facts.providerContainer == nil {
            // Resource values identify relocated iCloud Desktop/Documents too.
            // Walk the contiguous ubiquitous ancestors to find their sync root.
            var ancestor = directory ? url : url.deletingLastPathComponent()
            while true {
                let values = try ancestor.resourceValues(forKeys: [.isUbiquitousItemKey])
                guard values.isUbiquitousItem == true else { break }
                facts.providerContainer = ancestor
                if ancestor.path == "/" { break }
                ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
            }
        }
        return facts
    }

    nonisolated func accountHomeDirectory() throws -> URL {
        // NSHomeDirectory APIs can describe the sandbox container. Query the
        // account record with caller-owned storage, safe across coordinator threads.
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 16384)
        return try storage.withUnsafeMutableBufferPointer { buffer in
            let code = getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result)
            guard code == 0, result != nil, let directory = record.pw_dir else {
                throw CocoaError(.fileReadUnknown)
            }
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true).resolvingSymlinksInPath()
        }
    }

    nonisolated func trashDirectories() -> [URL] {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
    }
    nonisolated func destinationRefusal(_ url: URL) throws -> DestinationRefusal? { try readDestinationRefusal(url) }
    nonisolated func readDestinationRefusal(_ url: URL) throws -> DestinationRefusal? {
        guard try moveFacts(of: url).directory else { return .notFolder }
        for path in ["/", "/System", "/Library", "/usr", "/bin", "/sbin"] {
            if try sameItem(url, URL(fileURLWithPath: path)) { return .systemRoot }
        }
        let knownTrash = trashDirectories()
        var ancestor = url
        while true {
            if try moveFacts(of: ancestor).package { return .package }
            // Be conservative: dotted Trash names anywhere in the ancestry
            // include iCloud Drive and providers, not just home/volume Trash.
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            if ancestor.lastPathComponent.caseInsensitiveCompare(".Trash") == .orderedSame { return .trash }
            if ancestor.lastPathComponent.caseInsensitiveCompare(".Trashes") == .orderedSame { return .trash }
            // Plain Trash is reserved only immediately inside a CloudStorage
            // provider root. Ordinary folders with that name remain allowed.
            if ancestor.lastPathComponent.caseInsensitiveCompare("Trash") == .orderedSame {
                let storage = parent.deletingLastPathComponent().standardizedFileURL
                if storage.lastPathComponent.caseInsensitiveCompare("CloudStorage") == .orderedSame,
                   try sameItem(storage, accountHomeDirectory().appendingPathComponent("Library/CloudStorage")) {
                    return .trash
                }
            }
            for trash in knownTrash where FileManager.default.fileExists(atPath: trash.path) {
                if try sameItem(ancestor, trash) { return .trash }
            }
            if ancestor.path == "/" { break }
            ancestor = parent
        }
        return nil
    }
}

/// NSFileCoordinator is used on one worker, with cancel() invoked by the waiter.
/// Foundation does not annotate that supported cross-thread cancellation pattern
/// as Sendable. Every mutable result/rename gate is protected by Mutex.
nonisolated private final class MoveCoordinationJob: @unchecked Sendable {
    struct State {
        var cancelled = false
        var moved = false
        var error: (any Error)?
    }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let state = Mutex(State())
}
