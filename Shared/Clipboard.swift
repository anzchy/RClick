import AppKit

/// 剪贴板写入。App 与 Finder Sync 扩展共用，保证在线/离线两条路径语义一致。
enum Clipboard {
    /// Copies the selection as one plain-text item, one path per line, preserving literal characters.
    /// The sandboxed FinderSync extension cannot publish `public.file-url` for these paths.
    /// Finder's Command-C copies files; RClick's Cut + Paste moves them.
    nonisolated static func copyPaths(_ paths: [String], to pasteboard: NSPasteboard = .general) {
        guard !paths.isEmpty else { return }
        // Embedded newlines in filenames remain literal in this line-separated text.
        let text = paths.joined(separator: "\n")

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 复制多个文件名（不含路径），一行一个。只写文本——写成文件 URL 会让
    /// 粘到 Finder 的行为变成复制文件，与「复制文件名」的语义不符。
    nonisolated static func copyFileNames(_ paths: [String], to pasteboard: NSPasteboard = .general) {
        let names = paths
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return }

        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
    }
}
