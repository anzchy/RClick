import Foundation
import Darwin

public class Utils {
    public static func isProtectedFolder(_ path: String) -> Bool {
        isProtectedFolder(path, homeDirectory: getRealHomeDir())
    }

    /// Accept an already-decoded filesystem path, exactly as used by the file operation.
    static func isProtectedFolder(_ path: String, homeDirectory: String) -> Bool {
        guard path.hasPrefix("/") else { return true }
        let rawURL = URL(fileURLWithPath: path)
        // A directory traversal suffix acts on the target of a leaf directory link.
        let traversesLeaf = path.hasSuffix("/") || path.hasSuffix("/.")
        // Foundation silently returns an unresolved path on error. Missing paths
        // retain lexical matching, but denied traversal and other errors must refuse.
        let parentPath = traversesLeaf ? path : rawURL.deletingLastPathComponent().path
        if let resolved = realpath(parentPath, nil) {
            free(resolved)
        } else if errno != ENOENT {
            return true
        }
        let url = (traversesLeaf ? rawURL.resolvingSymlinksInPath() : rawURL).standardizedFileURL
        // Resolve only the parent: acting on a leaf symlink must act on the link itself.
        let candidate = url.path == "/" ? "/" : url.deletingLastPathComponent()
            .resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        // Darwin standardization also folds /private/var to /var; fold case first so
        // that aliases with case variants receive the same lexical normalization.
        func comparisonKey(_ value: String) -> String {
            URL(fileURLWithPath: value.lowercased()).standardizedFileURL.path.precomposedStringWithCanonicalMapping
        }
        return Constants.protectedDirs(homeDirectory: homeDirectory).contains { protectedPath in
            let protectedURL = URL(fileURLWithPath: protectedPath).standardizedFileURL
            // Some protected entries (such as /var) are themselves system symlinks.
            return comparisonKey(candidate) == comparisonKey(protectedURL.path)
                || comparisonKey(candidate) == comparisonKey(protectedURL.resolvingSymlinksInPath().path)
        }
    }
    // MARK: 
    public static func getRealHomeDir() -> String {
        // The account record retains relocated homes and avoids the sandbox container.
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return String(cString: directory)
        }
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
