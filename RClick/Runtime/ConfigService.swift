//
//  ConfigService.swift
//  RClick
//
//  配置持久化服务：负责配置数据的读取、保存（SwiftData）。
//  与 AppState 分离：AppState 持有运行时状态（内存数组），ConfigService 负责持久化。
//

import Foundation
import SwiftData
import os.log

/// 配置数据快照（AppState 持有的内存配置）
struct AppConfigData {
    var apps: [OpenWithApp] = []
    var actions: [RCAction] = []
    var newFiles: [NewFile] = []
    var commonDirs: [CommonDir] = []
}

@MainActor
final class ConfigService {
    @AppLog(category: "ConfigService")
    private var logger

    let modelContext: ModelContext

    private var newFileReadFailed = false
    private let fetchNewFiles: () throws -> [NewFileTypeEntity]
    private let persistContext: () throws -> Void

    init(modelContext: ModelContext? = nil,
         fetchNewFiles: (() throws -> [NewFileTypeEntity])? = nil,
         persistContext: (() throws -> Void)? = nil) {
        let context = modelContext ?? ModelContext(SharedDataManager.sharedModelContainer)
        self.modelContext = context
        self.fetchNewFiles = fetchNewFiles ?? {
            try context.fetch(FetchDescriptor<NewFileTypeEntity>(sortBy: [SortDescriptor(\.sortOrder)]))
        }
        self.persistContext = persistContext ?? { try context.save() }
    }

    /// 从 SwiftData 读取全部配置
    func load(templateStore: TemplateStore = .standard) -> AppConfigData {
        var data = AppConfigData()

        // Apps
        let appDescriptor = FetchDescriptor<AppEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        data.apps = (try? modelContext.fetch(appDescriptor))?.map { entity in
            var app = OpenWithApp(id: entity.id, appURL: entity.url)
            app.itemName = entity.itemName
            app.inheritFromGlobalArguments = entity.inheritFromGlobalArguments
            app.inheritFromGlobalEnvironment = entity.inheritFromGlobalEnvironment
            app.arguments = entity.arguments
            app.environment = entity.environment
            app.opensNewInstance = entity.opensNewInstance
            app.showInToolbar = entity.showInToolbar
            app.showInContextMenu = entity.showInContextMenu
            app.opensContainingDir = entity.opensContainingDir
            return app
        } ?? []

        // Actions
        let actionDescriptor = FetchDescriptor<ActionEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        data.actions = (try? modelContext.fetch(actionDescriptor))?.map { entity in
            RCAction(
                id: entity.id,
                name: entity.name,
                enabled: entity.isEnabled,
                idx: entity.sortOrder,
                icon: entity.icon
            )
        } ?? []

        // NewFiles
        // Idempotent load-time repair, like the common-directory icon repair below.
        // No schema change: remove only unsupported builtin rows, never user templates.
        let storedNewFiles: [NewFileTypeEntity]
        do {
            storedNewFiles = try fetchNewFiles()
            newFileReadFailed = false
        } catch {
            storedNewFiles = []
            newFileReadFailed = true
            logger.error("New File load failed; snapshot cleanup suspended")
        }
        let retired = storedNewFiles.filter {
            NewFile.isRetiredBuiltin(id: $0.id, ext: $0.fileExtension, hasTemplate: $0.templatePath != nil || !($0.templates ?? []).isEmpty)
        }
        for entity in retired { modelContext.delete(entity) }
        if !retired.isEmpty {
            do { try modelContext.save() }
            catch { logger.error("New File migration save failed; reason=persistence") }
        }
        data.newFiles = storedNewFiles.filter {
            !NewFile.isRetiredBuiltin(id: $0.id, ext: $0.fileExtension, hasTemplate: $0.templatePath != nil || !($0.templates ?? []).isEmpty)
        }.map { entity in
            var file = NewFile(
                ext: entity.fileExtension,
                name: entity.name,
                enabled: entity.isEnabled,
                idx: entity.sortOrder,
                icon: entity.icon,
                id: entity.id
            )
            // One-time additive migration. Adopt, never move or overwrite, the legacy file.
            if entity.blankEnabled == nil {
                entity.blankEnabled = entity.templatePath == nil
                entity.templates = entity.templatePath.map { path in
                    [NewFileTemplateEntity(template: NewFile.Template(
                        name: URL(fileURLWithPath: path).lastPathComponent, path: path), sortOrder: 0)]
                } ?? []
            }
            file.template = entity.templatePath.map { URL(fileURLWithPath: $0) }
            file.blankEnabled = entity.blankEnabled ?? true
            file.templates = (entity.templates ?? []).sorted { $0.sortOrder < $1.sortOrder }.map {
                var entry = $0.value
                if let path = entry.path {
                    let url = URL(fileURLWithPath: path)
                    if templateStore.contains(url), !templateStore.owns(url, id: entry.id) { entry.path = nil }
                }
                return entry
            }
            file.openApp = entity.openAppPath.map { URL(fileURLWithPath: $0) }
            return file
        }

        do { try modelContext.save() }
        catch { logger.error("New File template migration save failed; reason=persistence") }

        // CommonDirs（含旧图标自动修复）
        let commonDirDescriptor = FetchDescriptor<CommonDirEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        var needSaveCommonDirs = false
        data.commonDirs = (try? modelContext.fetch(commonDirDescriptor))?.map { entity in
            let resolvedIcon: String
            if entity.icon == "folder" || entity.icon.isEmpty {
                let newIcon = iconForDirectory(url: entity.path)
                entity.icon = newIcon
                needSaveCommonDirs = true
                resolvedIcon = newIcon
            } else {
                resolvedIcon = entity.icon
            }
            return CommonDir(
                id: entity.id,
                name: entity.name,
                url: entity.path,
                icon: resolvedIcon
            )
        } ?? []
        if needSaveCommonDirs {
            try? modelContext.save()
        }

        logger.debug("Load from SwiftData: \(data.apps.count) apps, \(data.actions.count) actions, \(data.newFiles.count) newFiles, \(data.commonDirs.count) commonDirs")
        return data
    }

    /// 将配置数据写回 SwiftData（全量替换）
    func save(_ data: AppConfigData, templateStore: TemplateStore = .standard, preserveTemplateSnapshots: Bool = false) throws {
        let priorTemplates = try fetchNewFiles().flatMap { entity in
            if let templates = entity.templates { return templates.map(\.value) }
            return entity.templatePath.map { [NewFile.Template(name: "", path: $0)] } ?? []
        }
        // Apps
        for entity in try modelContext.fetch(FetchDescriptor<AppEntity>()) { modelContext.delete(entity) }
        for (index, app) in data.apps.enumerated() {
            modelContext.insert(AppEntity(from: app, sortOrder: index))
        }

        // Actions
        for entity in try modelContext.fetch(FetchDescriptor<ActionEntity>()) { modelContext.delete(entity) }
        for action in data.actions {
            modelContext.insert(ActionEntity(from: action))
        }

        // NewFiles
        for entity in try modelContext.fetch(FetchDescriptor<NewFileTemplateEntity>()) { modelContext.delete(entity) }
        for entity in try modelContext.fetch(FetchDescriptor<NewFileTypeEntity>()) { modelContext.delete(entity) }
        for newFile in data.newFiles {
            modelContext.insert(NewFileTypeEntity(from: newFile))
        }

        // CommonDirs
        for entity in try modelContext.fetch(FetchDescriptor<CommonDirEntity>()) { modelContext.delete(entity) }
        for commonDir in data.commonDirs {
            modelContext.insert(CommonDirEntity(from: commonDir))
        }

        do { try persistContext() }
        catch { modelContext.rollback(); throw error }
        // Only after persistence succeeds: a failed load/save must never erase snapshots.
        guard !preserveTemplateSnapshots, !newFileReadFailed else { return }
        let retained = Set(data.newFiles.flatMap { $0.userTemplates.compactMap(\.path) })
        for entry in priorTemplates where !(entry.path.map { retained.contains($0) } ?? false) {
            try templateStore.remove(entry)
        }
    }
}
