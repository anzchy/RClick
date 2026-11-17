import Foundation

public class Utils {
    public static func isProtectedFolder(_ path: String) -> Bool {
        isProtectedFolder(path, homeDirectory: getRealHomeDir())
    }

    static func isProtectedFolder(_ path: String, homeDirectory: String) -> Bool {
        let url = URL(fileURLWithPath: path.removingPercentEncoding ?? path).standardizedFileURL
        // Resolve only the parent: acting on a leaf symlink must act on the link itself.
        let candidate = url.path == "/" ? "/" : url.deletingLastPathComponent()
            .resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        return Constants.protectedDirs(homeDirectory: homeDirectory).contains { protectedPath in
            let protectedURL = URL(fileURLWithPath: protectedPath).standardizedFileURL
            // Some protected entries (such as /var) are themselves system symlinks.
            return candidate == protectedURL.path || candidate == protectedURL.resolvingSymlinksInPath().path
        }
    }
    // MARK: 
    public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
