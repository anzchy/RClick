//
//  MenuService.swift
//  RClick
//
//  菜单配置构建服务：从 AppState 生成发往 Finder Extension 的 MenuConfigPayload。
//  版本号在这里维护，用于防重复和防乱序。
//

import Foundation

@MainActor
final class MenuService {
    private let undoAvailable: @MainActor () -> Bool

    init(undoAvailable: @escaping @MainActor () -> Bool = { RCRuntime.shared.actionService.undoMoveAvailable }) {
        self.undoAvailable = undoAvailable
    }

    /// 菜单版本号（防重复 / 防乱序）
    private var menuVersion = 0

    /// 从 AppState 实时构建菜单配置
    func buildConfig(from state: AppState, cutChangeCount: Int? = nil, cutItemCount: Int = 0, newFilesCollapsed: Bool? = nil) -> MenuConfigPayload {
        menuVersion += 1
        return MenuConfigPayload(
            version: menuVersion,
            actions: state.actions.filter(\.enabled).map { $0.toActionMenuItem() },
            apps: state.apps.map { $0.toAppMenuItem() },
            // Old backups can restore builtin rows into memory after load-time repair.
            newFiles: state.newFiles.filter {
                $0.enabled && !NewFile.isRetiredBuiltin(id: $0.id, ext: $0.ext, hasTemplate: !$0.userTemplates.isEmpty)
            }.compactMap { file in
                var entries: [NewFileMenuItem.Entry] = []
                if file.usesBlank && file.supportsBlank() { entries.append(.init(id: NewFile.blankTemplateID, name: AppLocalization.localized("Blank"))) }
                entries += file.userTemplates.filter { $0.enabled && !$0.isMissing }.map { .init(id: $0.id, name: $0.name) }
                guard !entries.isEmpty else { return nil }
                return NewFileMenuItem(id: file.id, name: file.displayName, ext: file.ext, icon: file.icon, entries: entries)
            },
            commonDirs: state.showCommonDirs ? state.cdirs.map {
                CommonDirMenuItem(id: $0.id, name: $0.displayName, icon: $0.icon, url: $0.url.path)
            } : [],
            actionsCollapsed: state.foldActionsMenu,
            appsCollapsed: state.foldAppsMenu,
            newFilesCollapsed: newFilesCollapsed ?? state.foldNewFileMenu,
            commonDirsCollapsed: state.foldCommonDirMenu,
            iconStyle: state.appIconStyle,
            cutChangeCount: cutChangeCount,
            cutItemCount: cutItemCount,
            undoMoveAvailable: undoAvailable()
        )
    }
}
