import Foundation

public class Utils {
    public static func isProtectedFolder(_ path: String) -> Bool {
        isProtectedFolder(path, homeDirectory: getRealHomeDir())
    }

    static func isProtectedFolder(_ path: String, homeDirectory: String) -> Bool {
        let candidate = URL(fileURLWithPath: path.removingPercentEncoding ?? path).standardizedFileURL.path
        return Constants.protectedDirs(homeDirectory: homeDirectory).contains { protectedPath in
            candidate == URL(fileURLWithPath: protectedPath).standardizedFileURL.path
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
