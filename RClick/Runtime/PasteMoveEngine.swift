import Foundation
import Darwin

nonisolated enum PasteMoveError: Error {
    case changed, invalidDestination, crossVolume, insideSource, mountPoint, cloud, timeout
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
    nonisolated func exclusiveRename(from source: URL, to destination: URL) throws {
        try SystemFileOperations().exclusiveRename(from: source, to: destination)
    }
    nonisolated func coordinatedExclusiveMove(from source: URL, to destination: URL, expected: FileIdentity) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: (any Error)?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            do {
                guard try fileIdentity(of: from) == expected else { throw PasteMoveError.changed }
                try exclusiveRename(from: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }
}
