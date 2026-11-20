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
    private let terminationBoundary: any MoveTerminationBoundary
    private let coordinationTimeout: TimeInterval
    private let quitWait: TimeInterval
    private var terminationPending = false
    private var terminationReply: (@MainActor () -> Void)?
    private let journalStore: (any UndoJournalStore)?
    private let cutPasteboard: any CutPasteboard
    private let pasteboard: NSPasteboard
    private let moveLogSink: (@Sendable (MoveLogEvent, String) -> Void)?
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
        cutPasteboard: (any CutPasteboard)? = nil,
        terminationBoundary: any MoveTerminationBoundary = SystemMoveTerminationBoundary(),
        quitWait: TimeInterval = 35,
        coordinationTimeout: TimeInterval = 30,
        moveLogSink: (@Sendable (MoveLogEvent, String) -> Void)? = nil,
        cutWarning: @escaping (String) -> Void = { CutWarningState.shared.show($0) },
        cutVolumeIsReadOnly: @escaping (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        }
    ) {
        self.state = state
        self.permission = permission
        self.confirmation = confirmation
        self.fileOperations = fileOperations
        self.terminationBoundary = terminationBoundary
        self.quitWait = quitWait
        self.coordinationTimeout = coordinationTimeout
        self.journalStore = journalStore
        self.cutPasteboard = cutPasteboard ?? pasteboard
        self.pasteboard = pasteboard
        self.now = now
        self.accessLeaser = accessLeaser
        self.revealNewFile = revealNewFile
        self.moveLogSink = moveLogSink
        self.cutWarning = cutWarning
        self.cutVolumeIsReadOnly = cutVolumeIsReadOnly
        // Normal runtime construction happens during launch. Hosted tests that
        // exercise Paste always inject a store; other hosted tests stay inert.
        if journalStore != nil || !TestHost.isActive {
            journalRecovery = Task { [weak self] in
                guard let self else { return }
                await self.restoreMoveJournal()
            }
        }
    }

    struct CutRecord: Sendable {
        let paths: [String]
        let identities: [FileIdentity]
        let changeCount: Int
    }

    private var journalNotice: String?
    private var journalRecovery: Task<Void, Never>?
    private var cutRecord: CutRecord?
    private var preparingCut = false
    var pendingCut: CutRecord? {
        guard let cutRecord, PendingCut(pasteboard: cutPasteboard).isStillPending(cutRecord.changeCount) else { return nil }
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
        await journalRecovery?.value
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

    /// Returns true when the delegate should return terminateLater.
    func deferTermination(reply: @escaping @MainActor () -> Void) -> Bool {
        guard preparingCut else { return false }
        guard !terminationPending else { return true }
        terminationPending = true
        terminationReply = reply
        terminationBoundary.scheduleDeadline(now().addingTimeInterval(quitWait)) { [weak self] in
            self?.replyToTermination()
        }
        return true
    }

    private func replyToTermination() {
        let reply = terminationReply
        terminationReply = nil // Take before calling: completion and deadline may both fire.
        reply?()
    }

    private func releaseReservation() {
        preparingCut = false
        replyToTermination()
    }

    private func restoreMoveJournal() async {
        let store: any UndoJournalStore
        do { store = try journalStore ?? AtomicUndoJournalStore.appGroup() }
        catch {
            logMove(MoveLogEvent(kind: .recoveryFailed, reasons: [.journalUnavailable]))
            return
        }
        let loaded: MoveJournal
        do {
            guard let value = try await executor.run({ try store.load() }) else { return }
            loaded = value
        } catch JournalFailure.discarded {
            journalNotice = "A previous move could not be fully recovered; its undo information was discarded"
            logMove(MoveLogEvent(kind: .recoveryFailed, reasons: [.journalDiscarded]))
            return
        } catch {
            journalNotice = "The move journal could not be read or quarantined; check its folder access"
            logMove(MoveLogEvent(kind: .recoveryFailed, reasons: [.journalRead]))
            return
        }
        // Recorded paths grant no access. Prune first, independently of access;
        // only inspect live objects covered by existing bookmarks, never prompt.
        let directories = (loaded.entries + loaded.previous + (loaded.deferred ?? [])).flatMap {
            [URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent(),
             URL(fileURLWithPath: $0.movedToPath).deletingLastPathComponent()]
        }
        let accessible = directories.filter { permission.hasAccess(to: $0) }
        let lease = accessLeaser.beginAccess(covering: accessible)
        defer { lease.end() }
        let operations = fileOperations
        let timestamp = now()
        let recoveryEntries = loaded.entries + loaded.previous + (loaded.deferred ?? [])
        let recoveryItems = Set(recoveryEntries.map(\.originalPath)).count
        let expiredItems = Set(recoveryEntries.filter {
            timestamp.timeIntervalSince($0.timestamp) >= 86400 || $0.timestamp > timestamp
        }.map(\.originalPath)).count
        let accessiblePaths = Set(accessible.map(\.path))
        do {
            let report = try await executor.run {
                var journal = loaded
                let report = try journal.reconcile(using: operations, at: timestamp, accessibleDirectories: accessiblePaths)
                try store.persist(journal)
                return report
            }
            if report.missingAccess > 0 {
                journalNotice = "A previous move is awaiting recovery because folder access is missing; its undo information is retained for 24 hours"
            } else if report.ambiguous > 0 {
                journalNotice = "A previous move is awaiting recovery because its locations are ambiguous; its undo information is retained for 24 hours"
            } else if report.unreadable > 0 {
                journalNotice = "A previous move is awaiting recovery because its files could not be read; its undo information is retained for 24 hours"
            }
            var skipped: Set<MoveLogEvent.Reason> = []
            if report.missingAccess > 0 { skipped.insert(.missingAccess) }
            if report.ambiguous > 0 { skipped.insert(.ambiguous) }
            if !skipped.isEmpty {
                logMove(MoveLogEvent(kind: .recoverySkipped, total: recoveryItems,
                    affected: min(recoveryItems, report.missingAccess + report.ambiguous), reasons: skipped))
            }
            if report.unreadable > 0 {
                logMove(MoveLogEvent(kind: .recoveryFailed, total: recoveryItems,
                    affected: min(recoveryItems, report.unreadable), reasons: [.recoveryRead]))
            }
            if report.pruned > 0 {
                logMove(MoveLogEvent(kind: .recoveryExpired, total: recoveryItems, affected: expiredItems, reasons: [.expired]))
            }
        } catch {
            journalNotice = "The move journal could not be saved; no further files can be moved until it is writable"
            logMove(MoveLogEvent(kind: .recoveryFailed, total: recoveryItems,
                affected: recoveryItems, reasons: [.journalWrite]))
        }
    }

    private func pasteMove(_ target: [String], trigger: String) async {
        var publishConfig = true
        defer { if publishConfig { NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: self) } }
        guard !preparingCut, !terminationPending else {
            logMove(MoveLogEvent(kind: .refused, total: pendingCut?.paths.count ?? 0,
                affected: pendingCut?.paths.count ?? 0, reasons: [.busy]))
            cutWarning(AppLocalization.localized("A move is already in progress"))
            return
        }
        preparingCut = true
        defer { releaseReservation() }
        guard let record = pendingCut else {
            logMove(MoveLogEvent(kind: .refused, total: cutRecord?.paths.count ?? 0,
                affected: cutRecord?.paths.count ?? 0, reasons: [.staleCut]))
            cutRecord = nil
            cutWarning(AppLocalization.localized("The cut has ended"))
            return
        }
        guard target.count == 1, trigger == "ctx-container" || trigger == "ctx-items" else {
            logMove(MoveLogEvent(kind: .refused, total: record.paths.count, affected: record.paths.count, reasons: [.invalidTarget]))
            cutWarning(AppLocalization.localized("Choose a folder as the destination"))
            return
        }
        let destination = URL(fileURLWithPath: target[0]).resolvingSymlinksInPath()
        let directories = [destination] + record.paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        for directory in directories where !permission.hasAccess(to: directory) {
            guard await permission.promptForPermission(for: directory) != nil else {
                logMove(MoveLogEvent(kind: .refused, total: record.paths.count, affected: record.paths.count, reasons: [.permission]))
                return
            }
        }
        guard !Task.isCancelled, directories.allSatisfy({ permission.hasAccess(to: $0) }) else {
            logMove(MoveLogEvent(kind: .refused, total: record.paths.count, affected: record.paths.count,
                reasons: [Task.isCancelled ? .cancelled : .permission]))
            return
        }
        guard cutRecord?.changeCount == record.changeCount, cutPasteboard.changeCount == record.changeCount else {
            logMove(MoveLogEvent(kind: .refused, total: record.paths.count, affected: record.paths.count, reasons: [.staleCut]))
            cutRecord = nil
            cutWarning(AppLocalization.localized("The cut has ended"))
            return
        }
        let lease = accessLeaser.beginAccess(covering: directories)
        defer { lease.end() }
        let operations = fileOperations
        let alreadyHere = await executor.run {
            record.paths.filter { path in
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
                return (try? operations.sameItem(parent, destination)) == true
            }
        }
        if alreadyHere.count == record.paths.count {
            // Pure no-op: do not consume a pending recovery notice or touch its
            // journal, clipboard generation, pending record or menu counters.
            publishConfig = false
            return
        }
        await restoreMoveJournal()
        if let notice = journalNotice {
            journalNotice = nil
            cutWarning(AppLocalization.localized(notice))
        }
        let store: any UndoJournalStore
        do { store = try journalStore ?? AtomicUndoJournalStore.appGroup() }
        catch {
            logMove(MoveLogEvent(kind: .refused, total: record.paths.count, affected: record.paths.count, reasons: [.journalUnavailable]))
            logMove(MoveLogEvent(kind: .journalFailure, total: record.paths.count, affected: record.paths.count, reasons: [.journalUnavailable]))
            cutWarning(moveFailureDescription(JournalFailure.unreadable))
            return
        }
        let timestamp = now()
        let timeout = coordinationTimeout
        terminationBoundary.protectMutation()
        defer { terminationBoundary.unprotectMutation() }
        let result = await executor.run { () -> FileActionResult in
            var result = FileActionResult()
            result.itemCount = record.paths.count
            result.unchanged = alreadyHere
            let expectedDestination: FileIdentity
            do {
                if let refusal = try operations.destinationRefusal(destination) { throw refusal }
                expectedDestination = try operations.fileIdentity(of: destination)
            } catch {
                result.failures = record.paths.filter { !alreadyHere.contains($0) }.map { FileActionFailure(path: $0, error: error) }
                return result
            }
            var journal: MoveJournal
            do {
                let old = try store.load()
                let live: (MoveJournalEntry) -> Bool = {
                    $0.timestamp <= timestamp && timestamp.timeIntervalSince($0.timestamp) < 86400
                }
                var previous = (old?.entries ?? []).filter { $0.outcome == .moved && live($0) }
                var deferred = (old?.deferred ?? []).filter(live)
                if let old, old.inProgress {
                    // Recovery may have read the outcome but failed to persist it.
                    // Preserve the durable intents in this new write-ahead record.
                    deferred += old.entries.filter { $0.outcome == .intended && live($0) }
                    if previous.isEmpty { previous = old.previous.filter { $0.outcome == .moved && live($0) } }
                }
                journal = MoveJournal(previous: previous, inProgress: true)
                journal.deferred = deferred.isEmpty ? nil : deferred
            } catch {
                result.failures = record.paths.filter { !alreadyHere.contains($0) }.map { FileActionFailure(path: $0, error: error) }
                return result
            }
            var seen: Set<URL> = []
            let unique = zip(record.paths, record.identities).compactMap { path, identity -> (String, URL, FileIdentity)? in
                let raw = URL(fileURLWithPath: path)
                let source = raw.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(raw.lastPathComponent).standardizedFileURL
                return seen.insert(source).inserted ? (path, source, identity) : nil
            }
            let selection = unique.filter { candidate in
                !unique.contains { other in
                    other.1 != candidate.1 && (try? operations.moveFacts(of: other.1).directory) == true
                        && (try? operations.contains(other.1, candidate.1)) == true
                }
            }
            result.itemCount = selection.count
            for (path, source, identity) in selection {
                if result.unchanged.contains(path) { continue }
                do {
                    if try operations.sameItem(source.deletingLastPathComponent(), destination) {
                        result.unchanged.append(path)
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
                    } else if facts.ubiquitous {
                        // Ubiquitous Desktop/Documents can live outside Mobile Documents.
                        // With no known root, only a ubiquitous destination is safe.
                        guard try operations.moveFacts(of: destination).ubiquitous else { throw PasteMoveError.cloud }
                    }
                    let plainFolder = facts.directory && !facts.package
                    let stableIdentity = try operations.stableMoveIdentity(of: source)
                    var number = 1
                    while true {
                        let name = try MoveName.candidate(source.lastPathComponent, number: number, plainFolder: plainFolder)
                        let to = destination.appendingPathComponent(name)
                        journal.entries.append(MoveJournalEntry(originalPath: source.path, movedToPath: to.path,
                            identity: stableIdentity, timestamp: timestamp, outcome: .intended))
                        try store.persist(journal) // Write-ahead: no rename may precede this durable intent.
                        do {
                            try operations.coordinatedExclusiveMove(from: source, to: to, expected: identity, expectedDestination: expectedDestination, timeout: timeout)
                            result.completed.append(path)
                            journal.entries[journal.entries.count - 1].outcome = .moved
                            do { try store.persist(journal) }
                            catch {
                                // The rename happened. Never mark that item pending again.
                                // Preserve every unattempted item and stop the batch.
                                for remaining in selection.map(\.0) where !result.completed.contains(remaining)
                                    && !result.failures.contains(where: { $0.path == remaining })
                                    && !result.unchanged.contains(remaining) {
                                    result.failures.append(FileActionFailure(path: remaining, error: error))
                                }
                                result.journalNeedsRecovery = true
                                return result
                            }
                            break
                        } catch let error as POSIXError where error.code == .EEXIST {
                            journal.entries[journal.entries.count - 1].outcome = .failed
                            try store.persist(journal)
                            number += 1
                        }
                    }
                } catch {
                    result.failures.append(FileActionFailure(path: path, error: error))
                    if let index = journal.entries.lastIndex(where: { $0.originalPath == source.path && $0.outcome == .intended }) {
                        journal.entries[index].outcome = .failed
                        do { try store.persist(journal) }
                        catch {
                            for remaining in selection.map(\.0) where !result.completed.contains(remaining)
                                && !result.failures.contains(where: { $0.path == remaining })
                                    && !result.unchanged.contains(remaining) {
                                result.failures.append(FileActionFailure(path: remaining, error: error))
                            }
                            result.journalNeedsRecovery = true
                            return result
                        }
                    }
                }
            }
            if result.completed.isEmpty && result.failures.isEmpty && !result.unchanged.isEmpty { return result }
            let moved = journal.entries.filter { $0.outcome == .moved }
            journal.entries = moved.isEmpty ? journal.previous : moved
            journal.previous = []
            journal.inProgress = false
            do { try store.persist(journal) }
            catch { result.journalNeedsRecovery = true }
            return result
        }
        if result.completed.isEmpty && result.failures.isEmpty && !result.unchanged.isEmpty {
            publishConfig = false
            return
        }
        var clipboardFailed = false
        // This is an ownership check, not a pasteboard compare-and-swap.
        if cutPasteboard.changeCount != record.changeCount {
            cutRecord = nil
        } else if result.failures.isEmpty && result.unchanged.isEmpty {
            _ = cutPasteboard.prepareForNewContents(with: .currentHostOnly)
            cutRecord = nil
        } else {
            let pending = Set(result.failures.map(\.path) + result.unchanged)
            let remainingPaths = record.paths.filter { pending.contains($0) }
            if let count = PendingCut(pasteboard: cutPasteboard).writeCut(remainingPaths) {
                let identities = remainingPaths.compactMap { path in
                    record.paths.firstIndex(of: path).map { record.identities[$0] }
                }
                cutRecord = CutRecord(paths: remainingPaths, identities: identities, changeCount: count)
            } else {
                cutRecord = nil
                clipboardFailed = true
            }
        }
        logPasteResult(result, clipboardFailed: clipboardFailed)
        if !result.failures.isEmpty {
            let lines = result.failures.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent): \(moveFailureDescription($0.error))" }
            cutWarning(String(format: AppLocalization.localized("Some items could not be moved:\n%@"), lines.joined(separator: "\n")))
        } else if result.journalNeedsRecovery {
            cutWarning(AppLocalization.localized("The move completed, but its journal needs recovery at the next launch"))
        }
    }

    /// Both the OS logger and the injectable sink receive this exact safe message.
    private func logMove(_ event: MoveLogEvent) {
        let message = event.message
        switch event.kind {
        case .moved, .partial, .recoveryExpired: logger.info("\(message, privacy: .public)")
        default: logger.warning("\(message, privacy: .public)")
        }
        moveLogSink?(event, message)
    }

    private func logPasteResult(_ result: FileActionResult, clipboardFailed: Bool) {
        let moved = result.completed.count
        let total = result.itemCount
        let remaining = Set(result.failures.map(\.path) + result.unchanged)
        logMove(MoveLogEvent(kind: .moved, moved: moved, total: total, affected: moved))
        if moved > 0 && !remaining.isEmpty {
            logMove(MoveLogEvent(kind: .partial, moved: moved, total: total, affected: remaining.count))
        }
        var reasons = Set(result.failures.map { moveLogReason($0.error) })
        if clipboardFailed { reasons.insert(.clipboard) }
        if !reasons.isEmpty {
            let affected = clipboardFailed ? remaining.count : Set(result.failures.map(\.path)).count
            logMove(MoveLogEvent(kind: .refused, moved: moved, total: total, affected: affected, reasons: reasons))
        }
        let timeouts = result.failures.filter { moveLogReason($0.error) == .timeout }
        if !timeouts.isEmpty {
            logMove(MoveLogEvent(kind: .coordinationTimeout, moved: moved, total: total,
                affected: Set(timeouts.map(\.path)).count, reasons: [.timeout]))
        }
        let changed = result.failures.filter { moveLogReason($0.error) == .destinationChanged }
        if !changed.isEmpty {
            logMove(MoveLogEvent(kind: .destinationChanged, moved: moved, total: total,
                affected: Set(changed.map(\.path)).count, reasons: [.destinationChanged]))
        }
        let journal = result.failures.filter { moveLogReason($0.error) == .journalWrite }
        if !journal.isEmpty || result.journalNeedsRecovery {
            let affected = Set(journal.map(\.path) + (result.journalNeedsRecovery ? result.completed : [])).count
            logMove(MoveLogEvent(kind: .journalFailure, moved: moved, total: total,
                affected: affected, reasons: [.journalWrite]))
        }
    }

    private func moveLogReason(_ error: any Error) -> MoveLogEvent.Reason {
        switch error {
        case JournalFailure.discarded: return .journalDiscarded
        case JournalFailure.unreadable: return .journalRead
        case JournalFailure.writeFailed: return .journalWrite
        case DestinationRefusal.systemRoot: return .systemRoot
        case DestinationRefusal.trash: return .trash
        case DestinationRefusal.package: return .package
        case DestinationRefusal.notFolder: return .notFolder
        case PasteMoveError.changed: return .sourceChanged
        case PasteMoveError.destinationChanged: return .destinationChanged
        case PasteMoveError.crossVolume: return .crossVolume
        case PasteMoveError.insideSource: return .insideSource
        case PasteMoveError.mountPoint: return .mountPoint
        case PasteMoveError.cloud: return .cloud
        case PasteMoveError.timeout: return .timeout
        case MoveName.Failure.tooLong: return .nameTooLong
        case MoveName.Failure.exhausted: return .nameExhausted
        case let error as POSIXError where error.code == .ENOTSUP: return .unsupported
        case let error as POSIXError where error.code == .ENOENT: return .missing
        case let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile: return .missing
        case let error as CocoaError where error.code == .fileReadNoPermission || error.code == .fileWriteNoPermission: return .permission
        default: return .filesystem
        }
    }

    private func moveFailureDescription(_ error: any Error) -> String {
        let key: String
        switch error {
        case JournalFailure.discarded: key = "A previous move could not be fully recovered; its undo information was discarded"
        case JournalFailure.unreadable: key = "The move journal could not be read or quarantined; check its folder access"
        case JournalFailure.writeFailed: key = "The move journal could not be saved; no further files can be moved until it is writable"
        case DestinationRefusal.systemRoot: key = "System roots cannot be a move destination"
        case DestinationRefusal.trash: key = "Use Finder’s Move to Trash"
        case DestinationRefusal.package: key = "Packages and their contents cannot be a move destination"
        case DestinationRefusal.notFolder: key = "Choose a folder as the destination"
        case PasteMoveError.crossVolume: key = "Moving between disks is not supported yet"
        case PasteMoveError.insideSource: key = "A folder cannot be moved into itself"
        case PasteMoveError.mountPoint: key = "A volume root cannot be moved"
        case PasteMoveError.cloud: key = "Moving items outside their cloud container is not supported yet"
        case PasteMoveError.changed: key = "Changed since cut"
        case PasteMoveError.destinationChanged: key = "The destination changed"
        case PasteMoveError.timeout: key = "File coordination timed out"
        case MoveName.Failure.tooLong: key = "The numbered name would exceed 255 UTF-8 bytes"
        case MoveName.Failure.exhausted: key = "No available numbered name was found"
        case let posix as POSIXError where posix.code == .ENOTSUP: key = "This disk does not support exclusive moves"
        default: return error.localizedDescription
        }
        return AppLocalization.localized(key)
    }

    private func prepareCut(_ target: [String]) async {
        guard !preparingCut, !terminationPending else {
            logger.info("Cut ignored: another operation is reserved or Quit is pending")
            return
        }
        preparingCut = true
        defer { releaseReservation() }
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
        guard let count = PendingCut(pasteboard: cutPasteboard).writeCut(target) else {
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

    func createFile(
        rid: String, target: [String],
        templateResource: (String) -> URL? = { Bundle.main.url(forResource: "template", withExtension: $0) },
        templateWarning: (String) -> Void = { CutWarningState.shared.show($0) }
    ) async {
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
        let fileURL = URL(fileURLWithPath: getUniqueFilePath(dir: dirPath, ext: ext))
        // These builtin text formats explicitly use an empty template. A custom
        // type with the same extension still requires its configured template.
        let permitsEmpty = ["txt": ".txt", "md": ".md", "json": ".json"][rcitem.id] == ext
        let contents: Data
        if rcitem.template == nil && permitsEmpty {
            contents = Data()
        } else {
            // User templates take precedence, including when missing: silently
            // substituting a bundled default would discard the user's choice.
            let source = rcitem.template ?? templateResource(ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            guard let source, let data = try? Data(contentsOf: source), permitsEmpty || !data.isEmpty else {
                logger.warning("New File refused; reason=templateUnavailable count=1")
                templateWarning(String(format: AppLocalization.localized("The template for %@ is missing or unreadable, so no file was created."), rcitem.displayName))
                return
            }
            contents = data
        }
        do {
            // Recheck at the write boundary as well as choosing a unique name.
            try contents.write(to: fileURL, options: .withoutOverwriting)
            revealInFinderAndRename(fileURL)
        } catch {
            logger.error("New File failed; reason=writeFailed count=1")
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
