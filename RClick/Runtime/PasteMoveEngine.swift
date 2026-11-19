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

nonisolated struct MoveFacts: Sendable {
    var directory = false
    var package = false
    var mountPoint = false
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

    nonisolated func moveFacts(of url: URL) throws -> MoveFacts {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directory = attributes[.type] as? FileAttributeType == .typeDirectory
        let values = try url.resourceValues(forKeys: [.isPackageKey, .isVolumeKey, .isUbiquitousItemKey])
        var facts = MoveFacts(directory: directory, package: directory && values.isPackage == true,
                              mountPoint: directory && values.isVolume == true, ubiquitous: values.isUbiquitousItem == true)
        let home = Self.realUserHome
        for root in [home.appendingPathComponent("Library/Mobile Documents"), home.appendingPathComponent("Library/CloudStorage")] {
            guard FileManager.default.fileExists(atPath: root.path), try contains(root, url) else { continue }
            var container = url
            while container.path != "/" {
                let parent = container.deletingLastPathComponent()
                if try sameItem(parent, root) { break }
                container = parent
            }
            facts.providerContainer = container
            break
        }
        return facts
    }

    nonisolated static var realUserHome: URL {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated func destinationRefusal(_ url: URL) throws -> DestinationRefusal? {
        guard try moveFacts(of: url).directory else { return .notFolder }
        for path in ["/", "/System", "/Library", "/usr", "/bin", "/sbin"] {
            if try sameItem(url, URL(fileURLWithPath: path)) { return .systemRoot }
        }
        let knownTrash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
        var ancestor = url
        while true {
            if try moveFacts(of: ancestor).package { return .package }
            // Detect the well-known Trash entry by name plus its PARENT identity,
            // avoiding a traversal into a privacy-protected Trash just to classify it.
            let parent = ancestor.deletingLastPathComponent()
            if ancestor.lastPathComponent == ".Trash", try sameItem(parent, Self.realUserHome) { return .trash }
            if ancestor.lastPathComponent == ".Trashes", try moveFacts(of: parent).mountPoint { return .trash }
            for trash in knownTrash where FileManager.default.fileExists(atPath: trash.path) {
                if try sameItem(ancestor, trash) { return .trash }
            }
            if ancestor.path == "/" { break }
            ancestor = parent
        }
        return nil
    }
}
