import Foundation
import Testing
import SwiftData
import Synchronization

@testable import RClick

@MainActor
struct SettingsBackupTests {
    @Test func backupRoundTripsThroughJSON() throws {
        let appPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-app-\(UUID().uuidString).app")
        FileManager.default.createFile(atPath: appPath.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: appPath) }

        let backup = SettingsBackup(
            schemaVersion: SettingsBackup.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            apps: [SettingsBackup.App(
                id: "app",
                path: appPath.path,
                itemName: "Test",
                inheritFromGlobalArguments: false,
                inheritFromGlobalEnvironment: true,
                arguments: ["-a"],
                environment: ["K": "V"],
                opensNewInstance: true,
                showInToolbar: false,
                showInContextMenu: true,
                opensContainingDir: true
            )],
            actions: [SettingsBackup.Action(id: "copy-path", enabled: false, idx: 0)],
            newFiles: [SettingsBackup.FileTemplate(
                id: "txt", ext: ".txt", name: "TXT", enabled: true, idx: 0,
                icon: "doc.text", openAppPath: nil, templatePath: nil
            )],
            commonDirs: [SettingsBackup.CommonFolder(
                id: "home", name: "Home", path: "/Users/test", icon: "folder"
            )],
            preferences: SettingsBackup.Preferences(
                foldAppsMenu: true,
                foldActionsMenu: false,
                foldNewFileMenu: true,
                foldCommonDirMenu: false,
                showCommonDirs: true,
                appIconStyle: 2,
                showMenuBarExtra: false,
                launchAtLogin: true
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SettingsBackup.self, from: data)

        #expect(decoded.schemaVersion == SettingsBackup.currentSchemaVersion)
        #expect(decoded.apps.first?.path == appPath.path)
        #expect(decoded.apps.first?.arguments == ["-a"])
        #expect(decoded.actions.first?.enabled == false)
        #expect(decoded.preferences.appIconStyle == 2)
        #expect(decoded.preferences.launchAtLogin == true)
    }

    @Test func appThatIsNotInstalledIsSkipped() {
        let entry = SettingsBackup.App(
            id: "gone",
            path: "/tmp/rclick-missing-\(UUID().uuidString).app",
            itemName: "Gone",
            inheritFromGlobalArguments: true,
            inheritFromGlobalEnvironment: true,
            arguments: [],
            environment: [:],
            opensNewInstance: false,
            showInToolbar: true,
            showInContextMenu: true,
            opensContainingDir: nil
        )

        #expect(entry.toModel() == nil)
    }

    @Test func missingLegacyTemplateIsRetainedRatherThanSilentlyFallingBack() {
        let entry = SettingsBackup.FileTemplate(
            id: "custom",
            ext: ".docx",
            name: "Custom",
            enabled: true,
            idx: 0,
            icon: "doc.richtext",
            openAppPath: "/tmp/rclick-missing-\(UUID().uuidString).app",
            templatePath: "/tmp/rclick-missing-\(UUID().uuidString).docx"
        )

        let file = entry.toModel()
        #expect(file.userTemplates.count == 1)
        #expect(file.userTemplates.first?.isMissing == true)
        #expect(file.usesBlank == false)
        #expect(file.openApp == nil)
    }

    @Test func resolveActionsKeepsBackupOrderAndAddsNewBuiltIns() {
        let actions = SettingsBackup.resolveActions([
            SettingsBackup.Action(id: "delete-direct", enabled: false, idx: 0),
            SettingsBackup.Action(id: "copy-path", enabled: true, idx: 1),
            SettingsBackup.Action(id: "unknown-action", enabled: true, idx: 2),
        ])

        #expect(actions.first?.id == "delete-direct")
        #expect(actions.first?.enabled == false)
        #expect(Set(actions.map(\.id)) == Set(RCAction.all.map(\.id)))
        #expect(actions.map(\.idx) == Array(0..<actions.count))
    }
    @Test func exportOmitsSnapshotBytesAndPathsButImportKeepsEveryRowAndReportsCount() throws {
        let state = AppState()
        var file = NewFile.txt
        file.blankEnabled = false
        file.templates = [.init(id: "a", name: "Letter", enabled: false, path: "/tmp/private-snapshot"),
            .init(id: "b", name: "Memo", path: nil)]
        state.newFiles = [file]
        let backup = SettingsBackup(appState: state)
        let encoded = try JSONEncoder().encode(backup)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-snapshot"))
        let decoded = try JSONDecoder().decode(SettingsBackup.self, from: encoded)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.omittedTemplateCount == 2)
        #expect(decoded.templateOmissionNotice.contains("2"))
        let restored = try #require(decoded.newFiles.first).toModel()
        #expect(restored.userTemplates.map(\.name) == ["Letter", "Memo"])
        #expect(restored.userTemplates.map(\.enabled) == [false, true])
        #expect(restored.userTemplates.allSatisfy { $0.isMissing })
        #expect(restored.usesBlank == false)
    }

    @Test func sameMacImportKeepsSnapshotsAndPersistedMenu() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("letter.txt")
        try Data("letter bytes".utf8).write(to: source)
        let store = TemplateStore(baseURL: dir.appendingPathComponent("Templates"))
        let entries = try [store.importFile(source), store.importFile(source)]
        var file = NewFile.txt
        file.templates = entries
        file.blankEnabled = false
        let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
            CommonDirEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = ConfigService(modelContext: ModelContext(container))
        try service.save(AppConfigData(newFiles: [file]), templateStore: store)
        let metadata = try JSONDecoder().decode(SettingsBackup.FileTemplate.self,
            from: JSONEncoder().encode(SettingsBackup.FileTemplate(file)))
        let restored = metadata.toModel(templateStore: store)
        try service.save(AppConfigData(newFiles: [restored]), templateStore: store, preserveTemplateSnapshots: true)
        let loaded = try #require(service.load().newFiles.first)
        #expect(loaded.userTemplates == entries)
        #expect(loaded.userTemplates.allSatisfy { !$0.isMissing })
        let state = AppState()
        state.newFiles = [file]
        let before = MenuService().buildConfig(from: state).newFiles
        state.newFiles = [loaded]
        let menuEncoder = JSONEncoder()
        menuEncoder.outputFormatting = [.sortedKeys]
        let beforeJSON = try menuEncoder.encode(before)
        let afterJSON = try menuEncoder.encode(MenuService().buildConfig(from: state).newFiles)
        #expect(afterJSON == beforeJSON)
        let backup = SettingsBackup(appState: state)
        #expect(backup.importOmittedTemplateCount(templateStore: store) == 0)
        let foreign = TemplateStore(baseURL: dir.appendingPathComponent("OtherMac/Templates"))
        #expect(metadata.toModel(templateStore: foreign).userTemplates.allSatisfy { $0.isMissing })
        #expect(backup.importOmittedTemplateCount(templateStore: foreign) == 2)
        // A partial import must leave unrelated snapshots for normal-save cleanup.
        let unrelated = try store.importFile(source)
        try service.save(AppConfigData(newFiles: []), templateStore: store, preserveTemplateSnapshots: true)
        #expect(FileManager.default.fileExists(atPath: try #require(unrelated.path)))

        for entry in entries {
            #expect(FileManager.default.fileExists(atPath: try #require(entry.path)))
        }
    }

}


extension SettingsBackupTests {
    nonisolated final class Signals: Sendable { let count = Mutex(0) }

    @Test func importRestoresEveryExportedPreferenceAndRefreshesMenu() throws {
        let suite = "RClickTests-backup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(preferencesDefaults: defaults)
        state.foldAppsMenu = false; state.foldActionsMenu = false
        state.foldNewFileMenu = true; state.foldCommonDirMenu = true
        state.showCommonDirs = true; state.appIconStyle = 2
        defaults.set(false, forKey: Key.showMenuBarExtra)
        var login = false
        let before = SettingsBackup(appState: state, defaults: defaults, launchAtLogin: { login })
        state.foldAppsMenu = true; state.foldActionsMenu = true
        state.foldNewFileMenu = false; state.foldCommonDirMenu = false
        state.showCommonDirs = false; state.appIconStyle = 0
        defaults.set(true, forKey: Key.showMenuBarExtra); login = true
        let signals = Signals()
        let token = NotificationCenter.default.addObserver(forName: .menuConfigShouldUpdate, object: nil, queue: nil) { _ in
            signals.count.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let decoded = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(before))
        decoded.preferences.apply(to: state, defaults: defaults, setLaunchAtLogin: { login = $0 })
        var after = SettingsBackup(appState: state, defaults: defaults, launchAtLogin: { login })
        after.exportedAt = before.exportedAt
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(after) == encoder.encode(before))
        #expect(state.foldActionsMenu == false)
        #expect(signals.count.withLock { $0 } == 1)
        let menu = MenuService().buildConfig(from: state)
        #expect(menu.actionsCollapsed == false)
        #expect(menu.appsCollapsed == false)
        #expect(menu.newFilesCollapsed == true)
        #expect(menu.commonDirsCollapsed == true)
        #expect(menu.iconStyle == 2)
    }

    @Test func oldBackupWithMissingPreferencesKeepsCurrentValues() throws {
        let suite = "RClickTests-old-backup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(preferencesDefaults: defaults)
        state.foldAppsMenu = true; state.foldActionsMenu = true
        state.foldNewFileMenu = false; state.foldCommonDirMenu = false
        state.showCommonDirs = true; state.appIconStyle = 2
        defaults.set(false, forKey: Key.showMenuBarExtra)
        var login = true
        let before = SettingsBackup(appState: state, defaults: defaults, launchAtLogin: { login })
        let missing = try JSONDecoder().decode(SettingsBackup.Preferences.self, from: Data("{}".utf8))
        missing.apply(to: state, defaults: defaults, setLaunchAtLogin: { login = $0 })
        let after = SettingsBackup(appState: state, defaults: defaults, launchAtLogin: { login })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(before.preferences) == encoder.encode(after.preferences))
        let partial = try JSONDecoder().decode(SettingsBackup.Preferences.self, from: Data(#"{"foldActionsMenu":false}"#.utf8))
        partial.apply(to: state, defaults: defaults, setLaunchAtLogin: { login = $0 })
        #expect(state.foldActionsMenu == false)
        #expect(state.foldAppsMenu == true)
        #expect(state.foldNewFileMenu == false)
        #expect(state.showCommonDirs == true)
        #expect(state.appIconStyle == 2)
        #expect(defaults.bool(forKey: Key.showMenuBarExtra) == false)
        #expect(login == true)
    }
}
