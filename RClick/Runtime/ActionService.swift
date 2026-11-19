//
//  ActionService.swift
//  RClick
//
//  文件操作 / 动作执行服务。从原 AppDelegate 迁移而来，是主 app 的"动作执行层"。
//  依赖 AppState（只读状态）、PermissionService 与删除确认（经协议注入，可 mock 单测）。
//  注意：第一版不过度拆分，用私有方法 + MARK 分组（FileActions / AppActions / FinderActions / SystemActions）。
//

import AppKit
import ApplicationServices
import Foundation
import os.log

@MainActor
final class ActionService {
    @AppLog(category: "ActionService")
    private var logger

    private let state: ActionStateProviding
    private let permission: PermissionProviding
    private let confirmation: DeleteConfirmationProviding
    private let fileOperations: any FileOperations
    private let journalStore: (any UndoJournalStore)?
    private let pasteboard: NSPasteboard
    private let cutWarning: (String) -> Void
    private let cutVolumeIsReadOnly: (URL) -> Bool
    /// System boundary: tests can observe reveal without opening Finder or posting keys.
    private let revealNewFile: ((URL) -> Void)?
    /// 当前时间；只用于自动重命名等待 Finder 的截止时间。
    private let now: @Sendable () -> Date
    /// 删除批次在后台执行期间持有的目录访问。
    private let accessLeaser: any ScopedAccessLeasing
    /// 长时间文件操作的串行后台执行器；弹窗与授权面板不进这里。
    private let executor = ActionExecutor()

    init(
        state: ActionStateProviding,
        permission: PermissionProviding,
        confirmation: DeleteConfirmationProviding,
        fileOperations: any FileOperations = SystemFileOperations(),
        pasteboard: NSPasteboard = .general,
        now: @escaping @Sendable () -> Date = { Date() },
        accessLeaser: any ScopedAccessLeasing = BookmarkAccessLeaser(),
        revealNewFile: ((URL) -> Void)? = nil,
        journalStore: (any UndoJournalStore)? = nil,
        cutWarning: @escaping (String) -> Void = { CutWarningState.shared.show($0) },
        cutVolumeIsReadOnly: @escaping (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        }
    ) {
        self.state = state
        self.permission = permission
        self.confirmation = confirmation
        self.fileOperations = fileOperations
        self.journalStore = journalStore
        self.pasteboard = pasteboard
        self.now = now
        self.accessLeaser = accessLeaser
        self.revealNewFile = revealNewFile
        self.cutWarning = cutWarning
        self.cutVolumeIsReadOnly = cutVolumeIsReadOnly
    }

    struct CutRecord: Sendable {
        let paths: [String]
        let identities: [FileIdentity]
        let changeCount: Int
    }

    private var cutRecord: CutRecord?
    private var preparingCut = false
    var pendingCut: CutRecord? {
        guard let cutRecord, PendingCut(pasteboard: pasteboard).isStillPending(cutRecord.changeCount) else { return nil }
        return cutRecord
    }

    // MARK: - SystemActions

    /// 复制路径到剪贴板
    /// 将全部选中路径复制为一个纯文本项，每行一个；沙盒扩展无法发布 public.file-url，复制文件请用 Finder 的 Command-C，移动文件请用剪切 + 粘贴。
    /// 与扩展内的离线快链路共用 Clipboard 实现。
    func copyPath(_ target: [String]) {
        Clipboard.copyPaths(target, to: pasteboard)
    }

    /// 复制全部选中项的文件名（不含路径）到剪贴板，一行一个。
    func copyFileName(_ target: [String]) {
        Clipboard.copyFileNames(target, to: pasteboard)
    }

    // MARK: - AppActions

    /// 用指定应用打开选中文件/目录（沙盒门控：先 hasAccess，失败兜底再授权重试）
    func openApp(rid: String, target: [String]) async {
        guard let rcitem = state.getAppItem(rid: rid) else {
            logger.warning("when openapp, but not have app \(rid)")
            return
        }

        let appUrl = rcitem.url
        logger.debug("openApp: rid=\(rid) app=\(appUrl.path) target=\(target) opensNewInstance=\(rcitem.opensNewInstance)")

        // 通过共享目标解析处理「选中文件时打开所在目录」选项
        for resolved in AppPresets.resolveOpenTargets(
            appPath: appUrl.path, explicit: rcitem.opensContainingDir, targetPaths: target
        ) {
            await openWithApp(resolved.url, appUrl: appUrl, opensNewInstance: rcitem.opensNewInstance)
        }
    }

    private func openWithApp(_ url: URL, appUrl: URL, opensNewInstance: Bool) async {
        let logger = self.logger  // 捕获 Sendable logger，供完成回调使用
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let accessURL = (exists && isDir.boolValue) ? url : url.deletingLastPathComponent()

        // 门控先行：未授权先弹窗，避免"只是打开一个文件"也要用户授权整个父目录的弹窗偏重
        if !permission.hasAccess(to: accessURL) {
            guard await permission.promptForPermission(for: accessURL) != nil else {
                logger.warning("用户取消授权，跳过打开：\(url.path)")
                return
            }
        }

        let config = NSWorkspace.OpenConfiguration()
        // 以新实例打开（浏览器类 app 会新开窗口而非新 tab）
        config.createsNewApplicationInstance = opensNewInstance
        NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: config) { [weak self] runningApp, error in
            guard let self else { return }
            if let error {
                // 失败兜底：再弹授权并重试一次
                Task { @MainActor in
                    await self.openRetryAfterPermission(url: url, appUrl: appUrl, accessURL: accessURL, opensNewInstance: opensNewInstance, firstError: error)
                }
            } else if let runningApp {
                logger.debug("Successfully opened with application: \(runningApp.localizedName ?? "Unknown")")
            }
        }
    }

    private func openRetryAfterPermission(url: URL, appUrl: URL, accessURL: URL, opensNewInstance: Bool, firstError: Error) async {
        let logger = self.logger  // 捕获 Sendable logger
        guard await permission.promptForPermission(for: accessURL) != nil else {
            logger.error("打开失败且用户取消授权：\(url.path) — \(firstError.localizedDescription)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = opensNewInstance
        NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: config) { _, retryError in
            if let retryError {
                logger.error("重试打开仍失败：\(url.path) — \(retryError.localizedDescription)")
            }
        }
    }

    /// 打开常用目录（沙盒门控：目录需已授权，B4 之后添加时即存 bookmark，此处为兜底）
    func openCommonDirs(target: [String]) async {
        logger.debug("开始打开常用目录，目标路径：\(target)")

        for dirPath in target {
            let path = dirPath
            let url = URL(fileURLWithPath: path, isDirectory: true)

            if !permission.hasAccess(to: url) {
                guard await permission.promptForPermission(for: url) != nil else {
                    logger.warning("用户取消授权，跳过打开目录：\(path)")
                    continue
                }
            }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - FileActions

    /// 动作分发入口
    func actionHandler(rid: String, target: [String], trigger: String, optionKeyPressed: Bool = false) async {
        guard let rcitem = state.getActionItem(rid: RCAction.entityID(for: rid)) else {
            logger.warning("when actionHandler, but not have action \(rid)")
            return
        }

        if rid == "paste-move" {
            guard rcitem.enabled else { return }
            await pasteMove(target, trigger: trigger)
            return
        }
        switch rcitem.id {
        case "cut":
            guard rcitem.enabled else {
                logger.info("Cut refused: stored action is disabled")
                return
            }
            guard trigger == MenuTrigger.contextualItems.rawValue else {
                logger.info("Cut refused: trigger is not an item-selection menu")
                return
            }
            guard !target.isEmpty else {
                logger.info("Cut refused: selection is empty")
                return
            }
            await prepareCut(target)
        case "copy-path":
            copyPath(target)
        case "copy-file-name":
            copyFileName(target)
        case "delete-direct":
            await deleteFoldorFile(target, trigger, optionKeyPressed: optionKeyPressed)
        case "unhide":
            await unhideFilesAndDirs(target, trigger)
        case "hide":
            await hideFilesAndDirs(target, trigger)
        case "airdrop":
            await showAirDrop(target, trigger)
        default:
            logger.warning("no action id matched")
        }
    }

    private func pasteMove(_ target: [String], trigger: String) async {
        guard !preparingCut else { return }
        preparingCut = true
        defer {
            preparingCut = false
            NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
        }
        guard let record = pendingCut, target.count == 1,
              trigger == "ctx-container" || trigger == "ctx-items" else { return }
        let destination = URL(fileURLWithPath: target[0]).resolvingSymlinksInPath()
        let directories = [destination] + record.paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        for directory in directories where !permission.hasAccess(to: directory) {
            guard await permission.promptForPermission(for: directory) != nil else { return }
        }
        guard directories.allSatisfy({ permission.hasAccess(to: $0) }) else { return }
        let lease = accessLeaser.beginAccess(covering: directories)
        defer { lease.end() }
        let operations = fileOperations
        let store: any UndoJournalStore
        do { store = try journalStore ?? AtomicUndoJournalStore.appGroup() }
        catch { cutWarning(error.localizedDescription); return }
        let timestamp = now()
        let result = await executor.run { () -> FileActionResult in
            var result = FileActionResult()
            do {
                if let refusal = try operations.destinationRefusal(destination) { throw refusal }
            } catch {
                result.failures = record.paths.map { FileActionFailure(path: $0, error: error) }
                return result
            }
            var journal: MoveJournal
            do {
                let old = try store.load()
                guard old?.inProgress != true else { throw CocoaError(.fileWriteUnknown) }
                let previous = (old?.entries ?? []).filter { $0.outcome == .moved && timestamp.timeIntervalSince($0.timestamp) < 86400 }
                journal = MoveJournal(previous: previous, inProgress: true)
            } catch {
                result.failures = record.paths.map { FileActionFailure(path: $0, error: error) }
                return result
            }
            for (path, identity) in zip(record.paths, record.identities) {
                let raw = URL(fileURLWithPath: path)
                let source = raw.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(raw.lastPathComponent)
                do {
                    if try operations.sameItem(source.deletingLastPathComponent(), destination) {
                        result.completed.append(path)
                        continue
                    }
                    let facts = try operations.moveFacts(of: source)
                    if facts.mountPoint { throw PasteMoveError.mountPoint }
                    if facts.directory, try operations.contains(source, destination) { throw PasteMoveError.insideSource }
                    guard try operations.volumeIdentity(of: source) == operations.volumeIdentity(of: destination) else {
                        throw PasteMoveError.crossVolume
                    }
                    if let container = facts.providerContainer {
                        guard try operations.contains(container, destination) else { throw PasteMoveError.cloud }
                    } else if facts.ubiquitous { throw PasteMoveError.cloud }
                    let plainFolder = facts.directory && !facts.package
                    let stableIdentity = try operations.stableMoveIdentity(of: source)
                    var number = 1
                    while true {
                        let name = try MoveName.candidate(source.lastPathComponent, number: number, plainFolder: plainFolder)
                        let to = destination.appendingPathComponent(name)
                        journal.entries.append(MoveJournalEntry(originalPath: source.path, movedToPath: to.path,
                            identity: stableIdentity, timestamp: timestamp, outcome: .intended))
                        try store.save(journal) // Write-ahead: no rename may precede this durable intent.
                        do {
                            try operations.coordinatedExclusiveMove(from: source, to: to, expected: identity)
                            result.completed.append(path)
                            journal.entries[journal.entries.count - 1].outcome = .moved
                            do { try store.save(journal) }
                            catch { return result } // Intent remains durable; launch reconciliation resolves it.
                            break
                        } catch let error as POSIXError where error.code == .EEXIST {
                            journal.entries[journal.entries.count - 1].outcome = .failed
                            try store.save(journal)
                            number += 1
                        }
                    }
                } catch { result.failures.append(FileActionFailure(path: path, error: error)) }
            }
            let moved = journal.entries.filter { $0.outcome == .moved }
            journal.entries = moved.isEmpty ? journal.previous : moved
            journal.previous = []
            journal.inProgress = false
            do { try store.save(journal) }
            catch { /* Durable intents/outcomes remain available for launch reconciliation. */ }
            return result
        }
        // This is an ownership check, not a pasteboard compare-and-swap.
        if pasteboard.changeCount != record.changeCount {
            cutRecord = nil
        } else if result.failures.isEmpty {
            pasteboard.clearContents()
            cutRecord = nil
        } else {
            let failedPaths = result.failures.map(\.path)
            if let count = PendingCut(pasteboard: pasteboard).writeCut(failedPaths) {
                let identities = failedPaths.compactMap { path in
                    record.paths.firstIndex(of: path).map { record.identities[$0] }
                }
                cutRecord = CutRecord(paths: failedPaths, identities: identities, changeCount: count)
            } else { cutRecord = nil }
        }
        if !result.failures.isEmpty {
            let lines = result.failures.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent): \(moveFailureDescription($0.error))" }
            cutWarning(String(format: AppLocalization.localized("Some items could not be moved:\n%@"), lines.joined(separator: "\n")))
        }
    }

    private func moveFailureDescription(_ error: any Error) -> String {
        let key: String
        switch error {
        case DestinationRefusal.systemRoot: key = "System roots cannot be a move destination"
        case DestinationRefusal.trash: key = "Use Finder’s Move to Trash"
        case DestinationRefusal.package: key = "Packages and their contents cannot be a move destination"
        case DestinationRefusal.notFolder: key = "Choose a folder as the destination"
        case PasteMoveError.crossVolume: key = "Moving between disks is not supported yet"
        case PasteMoveError.insideSource: key = "A folder cannot be moved into itself"
        case PasteMoveError.mountPoint: key = "A volume root cannot be moved"
        case PasteMoveError.cloud: key = "Moving items outside their cloud container is not supported yet"
        case PasteMoveError.changed: key = "Changed since cut"
        case PasteMoveError.timeout: key = "File coordination timed out"
        case MoveName.Failure.tooLong: key = "The numbered name would exceed 255 UTF-8 bytes"
        case MoveName.Failure.exhausted: key = "No available numbered name was found"
        case let posix as POSIXError where posix.code == .ENOTSUP: key = "This disk does not support exclusive moves"
        default: return error.localizedDescription
        }
        return AppLocalization.localized(key)
    }

    private func prepareCut(_ target: [String]) async {
        guard !preparingCut else {
            logger.info("Cut ignored: another Cut is preparing")
            return
        }
        preparingCut = true
        defer { preparingCut = false }
        let urls = target.map { URL(fileURLWithPath: $0) }
        var seen: Set<String> = []
        let parents = urls.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }
        for parent in parents where !permission.hasAccess(to: parent) {
            guard await permission.promptForPermission(for: parent) != nil else {
                logger.info("Cut cancelled: source-parent permission panel dismissed")
                return
            }
            guard permission.hasAccess(to: parent) else {
                logger.warning("Cut refused: source-parent grant does not cover the selection")
                return
            }
        }
        // An earlier grant may have been revoked while a later panel was open.
        guard parents.allSatisfy({ permission.hasAccess(to: $0) }) else {
            logger.warning("Cut refused: source-parent access was revoked during preparation")
            return
        }
        // Check after authorization: sandbox-denied traversal is deliberately
        // fail-closed in isProtectedFolder, but must not suppress the access panel.
        if let protected = target.first(where: { Utils.isProtectedFolder($0) }) {
            logger.warning("Cut refused: selection contains a protected folder")
            cutWarning(String(format: AppLocalization.localized("Protected system folders cannot be cut: %@"), protected))
            return
        }
        let lease = accessLeaser.beginAccess(covering: parents)
        defer { lease.end() }
        for url in urls {
            let parent = url.deletingLastPathComponent()
            let values = try? parent.resourceValues(forKeys: [.isWritableKey])
            if cutVolumeIsReadOnly(url) || values?.isWritable == false || !fileOperations.isWritable(parent) {
                logger.warning("Cut refused: source volume is read-only or its parent is not writable")
                cutWarning(String(format: AppLocalization.localized("The source is on a read-only disk or in an unwritable folder: %@"), url.path))
                return
            }
        }
        let identities: [FileIdentity]
        do {
            identities = try urls.map { try fileOperations.fileIdentity(of: $0) }
        } catch {
            logger.error("Cut failed: source identity could not be read; selection count: \(target.count)")
            return
        }
        guard let count = PendingCut(pasteboard: pasteboard).writeCut(target) else {
            logger.error("Cut failed: clipboard write was rejected or could not be verified; selection count: \(target.count)")
            return
        }
        cutRecord = CutRecord(paths: target, identities: identities, changeCount: count)
        logger.info("Cut recorded; selection count: \(target.count)")
    }

    func showAirDrop(_ target: [String], _ trigger: String) async {
        logger.info("---- showAirDrop trigger:\(trigger)")
        let fm = FileManager.default
        var fileURLs: [URL] = []

        if trigger == "ctx-container" {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized("Warning")
            alert.informativeText = AppLocalization.localized("The current folder cannot be shared. Please select files or subfolders instead.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: AppLocalization.localized("OK"))
            alert.runModal()
            return
        }

        for item in target {
            let path = item
            logger.info("airdrop path \(path)")

            if Utils.isProtectedFolder(path) {
                let alert = NSAlert()
                alert.messageText = AppLocalization.localized("Warning")
                alert.informativeText = String(format: AppLocalization.localized("Protected system folders cannot be shared: %@"), path)
                alert.alertStyle = .warning
                alert.addButton(withTitle: AppLocalization.localized("OK"))
                alert.runModal()
                logger.warning("试图分享受保护的系统文件夹，操作已被阻止：\(path)")
                continue
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue {
                    logger.warning("不能通过 AirDrop 分享文件夹：\(path)")
                    let alert = NSAlert()
                    alert.messageText = AppLocalization.localized("Notice")
                    alert.informativeText = String(format: AppLocalization.localized("Folders cannot be shared via AirDrop: %@"), path)
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: AppLocalization.localized("OK"))
                    alert.runModal()
                    continue
                } else {
                    // 确保有文件所在目录的访问权限
                    let fileURL = URL(fileURLWithPath: path)
                    let dirURL = fileURL.deletingLastPathComponent()
                    if !permission.hasAccess(to: dirURL) {
                        guard await permission.promptForPermission(for: dirURL) != nil else {
                            logger.warning("用户取消授权，跳过 AirDrop：\(path)")
                            continue
                        }
                    }
                    fileURLs.append(fileURL)
                }
            }
        }

        if !fileURLs.isEmpty {
            if let airDropService = NSSharingService(named: .sendViaAirDrop) {
                airDropService.perform(withItems: fileURLs)
                logger.info("已通过 AirDrop 分享文件：\(fileURLs.map { $0.path }.joined(separator: ", "))")
            } else {
                logger.warning("无法获取 AirDrop 服务")
            }
        }
    }

    func unhideFilesAndDirs(_ target: [String], _ trigger: String) async {
        logger.info("开始取消隐藏文件和目录，目标路径：\(target)")
        if let dirPath = target.first {
            let fileManager = FileManager.default
            let path = dirPath
            logger.info("处理主目录：\(path)")
            let url = URL(fileURLWithPath: path)

            // 确保有目录的访问权限
            if !permission.hasAccess(to: url) {
                guard await permission.promptForPermission(for: url) != nil else {
                    logger.warning("用户取消授权，跳过取消隐藏：\(path)")
                    return
                }
            }

            do {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isHiddenKey], options: [.skipsPackageDescendants])
                for case var fileURL in contents {
                    do {
                        var resourceValues = URLResourceValues()
                        resourceValues.isHidden = false
                        try fileURL.setResourceValues(resourceValues)
                        logger.info("成功取消隐藏：\(fileURL.path)")
                    } catch {
                        logger.error("取消隐藏失败：\(fileURL.path): \(error)")
                    }
                }
            } catch {
                logger.error("获取目录内容失败：\(error)")
            }

            do {
                var resourceValues = URLResourceValues()
                resourceValues.isHidden = false
                var targetURL = url
                try targetURL.setResourceValues(resourceValues)
                logger.info("成功取消隐藏主目录：\(path)")
            } catch {
                logger.error("取消隐藏主目录失败：\(path): \(error)")
            }
            logger.info("取消隐藏操作完成，共处理目录：\(path)")
        }
    }

    func hideFilesAndDirs(_ target: [String], _ trigger: String) async {
        logger.info("开始隐藏文件和目录，目标路径：\(target), 触发器：\(trigger)")
        let fileManager = FileManager.default

        if trigger == "ctx-container", let dirPath = target.first {
            let path = dirPath
            logger.info("处理主目录：\(path)")
            let url = URL(fileURLWithPath: path)

            // 确保有目录的访问权限
            if !permission.hasAccess(to: url) {
                guard await permission.promptForPermission(for: url) != nil else {
                    logger.warning("用户取消授权，跳过隐藏：\(path)")
                    return
                }
            }

            do {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
                for case var fileURL in contents {
                    if Utils.isProtectedFolder(fileURL.path) {
                        logger.warning("跳过受保护的文件路径：\(fileURL.path)")
                        continue
                    }
                    do {
                        var resourceValues = URLResourceValues()
                        resourceValues.isHidden = true
                        try fileURL.setResourceValues(resourceValues)
                        logger.info("成功隐藏：\(fileURL.path)")
                    } catch {
                        logger.error("隐藏失败：\(fileURL.path): \(error)")
                    }
                }
            } catch {
                logger.error("获取目录内容失败：\(error)")
            }
        } else if trigger == "ctx-items" {
            for dirPath in target {
                let path = dirPath
                logger.info("处理路径：\(path)")
                let url = URL(fileURLWithPath: path)

                if Utils.isProtectedFolder(path) {
                    logger.warning("跳过受保护的文件路径：\(path)")
                    continue
                }

                // 确保有文件所在目录的访问权限
                let dirURL = url.deletingLastPathComponent()
                if !permission.hasAccess(to: dirURL) {
                    guard await permission.promptForPermission(for: dirURL) != nil else {
                        logger.warning("用户取消授权，跳过隐藏：\(path)")
                        continue
                    }
                }

                do {
                    var resourceValues = URLResourceValues()
                    resourceValues.isHidden = true
                    var targetURL = url
                    try targetURL.setResourceValues(resourceValues)
                    logger.info("成功隐藏：\(path)")
                } catch {
                    logger.error("隐藏失败：\(path): \(error)")
                }
            }
        }
        logger.info("隐藏操作完成")
    }

    @discardableResult
    func deleteFoldorFile(_ target: [String], _ trigger: String, optionKeyPressed: Bool = false) async -> FileActionResult {
        logger.info("---- deleteFoldorFile trigger:\(trigger) option:\(optionKeyPressed)")

        if trigger == "ctx-container" {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized("Warning")
            alert.informativeText = AppLocalization.localized("The current folder cannot be deleted. Please select files or subfolders instead.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: AppLocalization.localized("OK"))
            alert.runModal()
            return FileActionResult()
        }

        var pathsToDelete: [String] = []
        for item in target {
            let path = item

            if Utils.isProtectedFolder(path) {
                let alert = NSAlert()
                alert.messageText = AppLocalization.localized("Warning")
                alert.informativeText = String(format: AppLocalization.localized("Protected system folders cannot be deleted: %@"), path)
                alert.alertStyle = .warning
                alert.addButton(withTitle: AppLocalization.localized("OK"))
                alert.runModal()
                logger.warning("试图删除受保护的系统文件夹，操作已被阻止：\(path)")
                continue
            }

            pathsToDelete.append(path)
        }

        guard !pathsToDelete.isEmpty else { return FileActionResult() }

        // 先把授权问完，再让确认框当最后一道关卡：确认框里的条目数就是
        // "确认后真的会被删掉的数量"，取消授权的项在确认之前就已经出局。
        // 授权由 BookmarkManager 持有到进程结束，提前检查不会失效。
        var authorized: [String] = []
        for path in pathsToDelete {
            let dirURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            if !permission.hasAccess(to: dirURL) {
                guard await permission.promptForPermission(for: dirURL) != nil else {
                    logger.warning("用户取消授权，跳过删除：\(path)")
                    continue
                }
                guard permission.hasAccess(to: dirURL) else {
                    logger.warning("授权未覆盖目标目录，跳过删除：\(path)")
                    continue
                }
            }
            authorized.append(path)
        }

        guard !authorized.isEmpty else { return FileActionResult() }

        // 绕过废纸篓的删除默认必须确认；按住 Option 点击是唯一跳过确认的方式。
        if !optionKeyPressed {
            guard confirmation.confirmPermanentDelete(paths: authorized) else {
                logger.info("用户取消了删除确认，共 \(authorized.count) 项未删除")
                return FileActionResult()
            }
        }

        // 真正的删除放到串行后台执行器：确认框与授权面板已经在主线程上问完了。
        // 执行期间主线程空闲，设置页可能撤销授权；租约另开一份访问，批次结束后才归还。
        let fileOperations = self.fileOperations
        let paths = authorized
        let lease = accessLeaser.beginAccess(
            covering: paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        )
        defer { lease.end() }
        let result = await executor.run { () -> FileActionResult in
            var result = FileActionResult()
            for path in paths {
                do {
                    try fileOperations.removeItem(at: URL(fileURLWithPath: path))
                    result.completed.append(path)
                } catch {
                    result.failures.append(FileActionFailure(path: path, error: error))
                }
            }
            return result
        }
        for failure in result.failures {
            logger.error("delete \(failure.path) file run error \(failure.error)")
        }
        return result
    }

    // MARK: - NewFileActions

    func createFile(rid: String, target: [String]) async {
        guard let dirPath = targetDirectoryForNewFile(target) else {
            logger.warning("when createFile, but not have target directory")
            return
        }

        let dirURL = URL(fileURLWithPath: dirPath)

        // 确保有目标目录的访问权限
        if !permission.hasAccess(to: dirURL) {
            guard await permission.promptForPermission(for: dirURL) != nil else {
                logger.warning("用户取消授权，跳过创建文件")
                return
            }
        }

        if rid == NewFileMenuItem.customFileId {
            let filePath = getUniqueFilePath(dir: dirPath, ext: "")
            let fileURL = URL(fileURLWithPath: filePath)
            do {
                try Data().write(to: fileURL)
                logger.info("created editable file: \(fileURL.path)")
                revealInFinderAndRename(fileURL)
            } catch {
                logger.error("create editable file error: \(error.localizedDescription)")
            }
            return
        }

        guard let rcitem = state.getFileType(rid: rid) else {
            logger.warning("when createFile, but not have fileType \(rid) ")
            return
        }

        let ext = rcitem.ext
        logger.info("create file dir:\(dirPath) -- ext \(ext)")
        let filePath = getUniqueFilePath(dir: dirPath, ext: ext)
        let fileURL = URL(fileURLWithPath: filePath)

        do {
            let fileManager = FileManager.default

            if let templateUrl = rcitem.template {
                try fileManager.copyItem(at: templateUrl, to: fileURL)
                logger.info("已成功复制模板到目标路径：\(fileURL.path)")
            } else {
                if let defaultTemplateURL = Bundle.main.url(forResource: "template", withExtension: ext.replacingOccurrences(of: ".", with: "")) {
                    logger.info("使用模板创建文件，模板路径：\(defaultTemplateURL.path)")
                    try fileManager.copyItem(at: defaultTemplateURL, to: fileURL)
                    logger.info("已成功复制模板到目标路径：\(fileURL.path)")
                } else {
                    logger.warning("模板文件不存在：\(ext)")
                    try Data().write(to: fileURL)
                }
            }
            revealInFinderAndRename(fileURL)
        } catch let error as NSError {
            switch error.domain {
            case NSCocoaErrorDomain:
                switch error.code {
                case NSFileNoSuchFileError:
                    logger.error("文件不存在：\(filePath)")
                case NSFileWriteOutOfSpaceError:
                    logger.error("磁盘空间不足")
                case NSFileWriteNoPermissionError:
                    logger.error("没有写入权限：\(filePath)")
                default:
                    logger.error("创建文件错误：\(error.localizedDescription) (错误码：\(error.code))")
                }
            default:
                logger.error("未处理的错误：\(error.localizedDescription) (错误码：\(error.code))")
            }
        }
    }

    // MARK: - 辅助

    /// 生成目录内唯一的文件名（避免重名冲突）
    func getUniqueFilePath(dir: String, ext: String) -> String {
        let fileManager = FileManager.default
        let dirURL = URL(fileURLWithPath: dir.hasSuffix("/") ? String(dir.dropLast()) : dir)
        let baseFileName = AppLocalization.localized("Untitled")
        var filePath = dirURL.appendingPathComponent("\(baseFileName)\(ext)").path
        var counter = 1

        while fileManager.fileExists(atPath: filePath) {
            let newFileName = "\(baseFileName)\(counter)"
            filePath = dirURL.appendingPathComponent("\(newFileName)\(ext)").path
            counter += 1
        }

        return filePath
    }

    /// 解析新建文件的目标目录（目录直接用；文件取父目录）
    private func targetDirectoryForNewFile(_ target: [String]) -> String? {
        guard let rawPath = target.first else { return nil }
        let path = rawPath
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return path
            }
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }

        return path
    }

    /// 在 Finder 中选中新文件并触发重命名（需要辅助功能权限）
    private func revealInFinderAndRename(_ fileURL: URL) {
        if let revealNewFile {
            revealNewFile(fileURL)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])

        guard AXIsProcessTrusted() else {
            // 等 Finder 完成激活和选中再弹提示，避免提示窗口被 Finder 抢到后面。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.presentAccessibilityHintIfNeeded()
            }
            return
        }

        // 权限可用时重新武装一次性提示：用户之后撤销权限，还能再收到一次提醒。
        UserDefaults.group.set(false, forKey: Key.didShowRenamePermissionHint)
        waitForFinderThenRename(fileURL)
    }

    /// 缺少辅助功能权限时只提示一次，之后静默跳过自动重命名。
    private func presentAccessibilityHintIfNeeded() {
        let defaults = UserDefaults.group
        guard !defaults.bool(forKey: Key.didShowRenamePermissionHint) else {
            logger.debug("Accessibility permission still missing; auto-rename skipped")
            return
        }
        defaults.set(true, forKey: Key.didShowRenamePermissionHint)

        let alert = NSAlert()
        alert.messageText = AppLocalization.localized("Auto-Rename Needs Permission")
        alert.informativeText = String(
            format: AppLocalization.localized(
                "RClick needs \"%@\" permission to rename a newly created file automatically. Enable it for the RClick app in System Settings > %@."
            ),
            SystemSettingsNaming.accessibilitySection,
            SystemSettingsNaming.privacySecuritySection
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLocalization.localized("Open Settings"))
        alert.addButton(withTitle: AppLocalization.localized("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionChecker.openAccessibilitySettings()
        }
    }

    /// 等 Finder 真正成为前台并稳定后再发 Return。
    ///
    /// 原来的固定 0.35s + 0.25s 延时在慢目录或 Finder 响应较慢时会抢跑，
    /// 表现为“有时进入重命名、有时没有”。这里改成轮询前台应用，最多等 2 秒。
    private func waitForFinderThenRename(
        _ fileURL: URL,
        deadline: Date? = nil,
        activate: Bool = true
    ) {
        let deadline = deadline ?? now().addingTimeInterval(2)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            // 激活和选中不是同一时刻完成，留一点稳定时间再触发重命名。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.postReturnKey()
            }
            return
        }

        guard now() < deadline else {
            logger.warning("Finder did not become active; auto-rename skipped for \(fileURL.path)")
            return
        }

        // 只激活一次，之后单纯轮询，避免每 50ms 重复调用 activate。
        if activate {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFinderThenRename(fileURL, deadline: deadline, activate: false)
        }
    }

    private func postReturnKey() {
        let keyCodeReturn: CGKeyCode = 36
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
