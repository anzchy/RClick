//
//  Messager.swift
//  RClick
//
//  进程间通信（IPC）管理器
//  基于：DistributedNotificationCenter + Codable 协议
//

import Foundation
import OSLog
import AppKit
import Synchronization
import Observation

// MARK: - 消息类型枚举

/// 主程序发送给 Extension 的消息类型
enum MainToExtensionAction: String, Codable {
    /// 发送完整菜单配置
    case menuConfig = "menu-config"
    /// 主程序启动通知
    case running = "running"
    /// 主程序退出通知
    case quit = "quit"
    /// 确认已收到点击事件（用于扩展判断主程序是否可通信）
    case actionAck = "action-ack"
}

/// Extension 发送给主程序的消息类型
enum ExtensionToMainAction: String, Codable {
    /// 菜单点击事件
    case click = "click"
    /// 心跳消息
    case heartbeat = "heartbeat"
    /// 请求菜单配置
    case requestConfig = "request-config"
}

// MARK: - 消息载荷

/// 菜单配置消息载荷
struct MenuConfigPayload: Codable {
    /// 菜单版本号，用于防重复和防乱序
    let version: Int
    /// 动作菜单项列表
    let actions: [ActionMenuItem]
    /// 应用菜单项列表
    let apps: [AppMenuItem]
    /// 新建文件菜单项列表
    let newFiles: [NewFileMenuItem]
    /// 常用目录菜单项列表
    let commonDirs: [CommonDirMenuItem]
    /// 是否折叠动作菜单（默认 false）
    let actionsCollapsed: Bool
    /// 是否折叠应用菜单（默认 false）
    let appsCollapsed: Bool
    /// 是否折叠新建文件菜单（默认 true）
    let newFilesCollapsed: Bool
    /// 是否折叠常用目录菜单（默认 true）
    let commonDirsCollapsed: Bool
    /// 应用图标样式：0=无图标 1=简单图标（单色 template） 2=原始图标（默认）
    let iconStyle: Int

    init(
        version: Int = 1,
        actions: [ActionMenuItem] = [],
        apps: [AppMenuItem] = [],
        newFiles: [NewFileMenuItem] = [],
        commonDirs: [CommonDirMenuItem] = [],
        actionsCollapsed: Bool = false,
        appsCollapsed: Bool = false,
        newFilesCollapsed: Bool = true,
        commonDirsCollapsed: Bool = true,
        iconStyle: Int = RCAppIconStyle.simple.rawValue
    ) {
        self.version = version
        self.actions = actions
        self.apps = apps
        self.newFiles = newFiles
        self.commonDirs = commonDirs
        self.actionsCollapsed = actionsCollapsed
        self.appsCollapsed = appsCollapsed
        self.newFilesCollapsed = newFilesCollapsed
        self.commonDirsCollapsed = commonDirsCollapsed
        self.iconStyle = iconStyle
    }

    private enum CodingKeys: String, CodingKey {
        case version, actions, apps, newFiles, commonDirs
        case actionsCollapsed, appsCollapsed, newFilesCollapsed, commonDirsCollapsed
        case iconStyle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        actions = try values.decode([ActionMenuItem].self, forKey: .actions)
        apps = try values.decode([AppMenuItem].self, forKey: .apps)
        newFiles = try values.decode([NewFileMenuItem].self, forKey: .newFiles)
        commonDirs = try values.decode([CommonDirMenuItem].self, forKey: .commonDirs)
        actionsCollapsed = try values.decode(Bool.self, forKey: .actionsCollapsed)
        appsCollapsed = try values.decode(Bool.self, forKey: .appsCollapsed)
        newFilesCollapsed = try values.decode(Bool.self, forKey: .newFilesCollapsed)
        commonDirsCollapsed = try values.decode(Bool.self, forKey: .commonDirsCollapsed)
        // Payloads produced before icon styles existed used original app icons.
        iconStyle = try values.decodeIfPresent(Int.self, forKey: .iconStyle) ?? RCAppIconStyle.original.rawValue
    }

}

/// 点击事件消息载荷
nonisolated struct ClickEventPayload: Codable, Sendable {
    /// 点击的菜单项 ID
    let itemId: String
    /// 菜单项类型
    let itemType: MenuItemType
    /// 目标文件/目录路径列表
    let target: [String]
    /// 触发来源
    let trigger: MenuTrigger
    /// 点击时是否按住 Option。「直接删除」据此跳过确认
    let optionKeyPressed: Bool?

    init(
        itemId: String,
        itemType: MenuItemType,
        target: [String] = [],
        trigger: MenuTrigger,
        optionKeyPressed: Bool? = nil
    ) {
        self.itemId = itemId
        self.itemType = itemType
        self.target = target
        self.trigger = trigger
        self.optionKeyPressed = optionKeyPressed
    }
}

// MARK: - 辅助类型

/// 运行状态消息载荷（用于通知 Extension 主程序运行状态）
nonisolated struct RunningPayload: Codable, Sendable {
    /// 监听目录列表
    let directories: [String]

    init(directories: [String] = []) {
        self.directories = directories
    }
}

/// 菜单项类型
nonisolated enum MenuItemType: String, Codable, Sendable {
    case action = "action"  // 动作菜单
    case app = "app"  // 应用菜单
    case newFile = "new-file"  // 新建文件
    case commonDir = "common-dir"  // 常用目录
}

/// 触发来源
nonisolated enum MenuTrigger: String, Codable, Sendable {
    /// 选中文件/文件夹右键
    case contextualItems = "ctx-items"
    /// 空白处右键
    case contextualContainer = "ctx-container"
    /// 侧边栏右键
    case contextualSidebar = "ctx-sidebar"
    /// 工具栏
    case toolbar = "toolbar"
}

/// 项目类型（文件/文件夹）
nonisolated enum ItemType: String, Codable, Sendable {
    case file = "file"
    case folder = "folder"
    case unknown = "unknown"
}

// Handlers see only authenticated envelope bytes, including payload-free actions.
nonisolated final class Messager: NSObject, Sendable {
    static let shared: Messager = {
        // A hosted test must never create/read a production Keychain item.
        let testHost = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
        return Messager(keyProvider: testHost ? InMemoryKeyProvider(data: nil) : KeychainKeyProvider())
    }()
    static let mainToExtensionNotification = "cn.anzchy.RClick.MainToExtension"
    static let extensionToMainNotification = "cn.anzchy.RClick.ExtensionToMain"
    private struct State {
        var main: [MainToExtensionAction: @Sendable (VerifiedMessage) -> Void] = [:]
        var ext: [ExtensionToMainAction: @Sendable (VerifiedMessage) -> Void] = [:]
        var key: Data?
        var nextValidation: TimeInterval = 0
        var nextMACRefresh: TimeInterval = 0
        var readBackoff: TimeInterval = 1
        var macBackoff: TimeInterval = 1
        var configVersion = 0
        var lastConfig: Data?
        var invalidated: (@Sendable () -> Void)?
        var failures = IPCFailurePolicy()
    }
    private let state: Mutex<State>
    private let isExtension: Bool
    private let center: NotificationCenter
    private let keyProvider: any KeyProvider
    private let clock: any IPCClock
    private let random: any IPCRandom
    private let receiver: IPCReceiver
    private let logger = Logger(subsystem: "cn.anzchy.RClick", category: "Messager")

    init(isExtension: Bool? = nil, center: NotificationCenter = DistributedNotificationCenter.default(),
         keyProvider: any KeyProvider, clock: any IPCClock = SystemIPCClock(),
         random: any IPCRandom = SystemIPCRandom()) {
        let ext = isExtension ?? (Bundle.main.bundleIdentifier ?? "").hasSuffix(".FinderSyncExt")
        self.isExtension = ext
        self.center = center
        self.keyProvider = keyProvider
        self.clock = clock
        self.random = random
        let launchSession = ext ? "" : ((try? random.bytes(count: 16).base64EncodedString()) ?? "")
        self.receiver = IPCReceiver(direction: ext ? .toExtension : .toMain, clock: clock, session: launchSession)
        let initialKey = try? keyProvider.key(createIfMissing: !ext)
        self.state = Mutex(State(key: initialKey, nextValidation: clock.monotonicTime + (initialKey == nil ? 1 : 10),
                                 nextMACRefresh: clock.monotonicTime + (initialKey == nil ? 1 : 0)))
        super.init()
        if !hasReadableKey { logger.error("IPC signing and verification unavailable: no readable key") }
        if !ext && launchSession.isEmpty { logger.error("IPC unavailable: session creation failed") }
        center.addObserver(self, selector: #selector(receiveNotification(_:)),
                           name: Notification.Name(ext ? Self.mainToExtensionNotification : Self.extensionToMainNotification), object: nil)
    }
    deinit { center.removeObserver(self) }
    var currentSession: String { receiver.currentSession }
    var canUseCachedMenus: Bool { hasReadableKey && !receiver.currentSession.isEmpty }
    var hasReadableKey: Bool { state.withLock { $0.key != nil } }

    /// Never called from menu construction. Periodic checks run on send/receive
    /// cycles (at most once per 10 s); failed reads and MAC-triggered refreshes
    /// back off 1,2,4,...,30 s. Holding the mutex coalesces concurrent misses.
    private func key(onMACFailure: Bool = false) -> Data? {
        let result = state.withLock { state -> (Data?, Bool) in
            let now = clock.monotonicTime
            if onMACFailure {
                guard now >= state.nextMACRefresh else { return (state.key, false) }
                state.nextMACRefresh = now + state.macBackoff
                state.macBackoff = min(30, state.macBackoff * 2)
            } else {
                guard now >= state.nextValidation else { return (state.key, false) }
            }
            let previous = state.key
            state.key = try? keyProvider.key(createIfMissing: !isExtension)
            if state.key == nil {
                state.nextValidation = now + state.readBackoff
                state.nextMACRefresh = max(state.nextMACRefresh, state.nextValidation)
                state.readBackoff = min(30, state.readBackoff * 2)
            } else {
                state.nextValidation = now + 10
                state.readBackoff = 1
                if state.key != previous { state.macBackoff = 1 }
            }
            return (state.key, state.key != previous)
        }
        if result.1 { resynchronize() }
        return result.0
    }
    func onMainMessage(_ action: MainToExtensionAction, handler: @escaping @Sendable (VerifiedMessage) -> Void) {
        state.withLock { $0.main[action] = handler }
    }
    func onExtensionMessage(_ action: ExtensionToMainAction, handler: @escaping @Sendable (VerifiedMessage) -> Void) {
        state.withLock { $0.ext[action] = handler }
    }
    func onSessionInvalidated(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.invalidated = handler }
    }
    private func resynchronize() {
        receiver.resetSession(isExtension ? "" : ((try? random.bytes(count: 16).base64EncodedString()) ?? ""))
        state.withLock { $0.invalidated }?()
        if isExtension {
            requestMenuConfig()
        } else {
            sendRunningNotification()
            if let config = state.withLock({ $0.lastConfig }) {
                sendRaw("menu-config", direction: .toExtension, payload: config, id: UUID().uuidString)
            }
        }
    }
    @objc private func receiveNotification(_ notification: NSNotification) {
        do {
            guard let wire = notification.object as? String, wire.utf8.count <= IPCEnvelope.maximumWireBytes else { throw IPCSecurityError.malformed }
            _ = try IPCEnvelope.parse(wire) // Reject malformed floods BEFORE any key read.
            guard let key = key() else { throw IPCSecurityError.noKey }
            let message: VerifiedMessage
            do {
                message = try receiver.receive(wire, key: key)
            } catch IPCSecurityError.unauthenticated {
                guard let refreshed = self.key(onMACFailure: true) else { throw IPCSecurityError.noKey }
                message = try receiver.receive(wire, key: refreshed) // One retry, never a loop.
            }
            if isExtension, let action = MainToExtensionAction(rawValue: message.action) {
                let handler = state.withLock { $0.main[action] }
                handler?(message)
            } else if !isExtension, let action = ExtensionToMainAction(rawValue: message.action) {
                let handler = state.withLock { $0.ext[action] }
                handler?(message)
            }
        } catch {
            if case IPCSecurityError.clockDiscontinuity = error { resynchronize() }
            let report = state.withLock { state in
                let decision = state.failures.reject(now: clock.monotonicTime)
                return (decision.log, decision.notice, state.failures.rejectedCount)
            }
            if report.0 { logger.error("Rejected IPC messages: \(report.2, privacy: .public)") }
            if !isExtension, report.1 { Task { @MainActor in IPCRejectionNotice.shared.record() } }
        }
    }
    private func send<T: Encodable>(_ action: String, direction: IPCDirection, data: T?, id: String, inReplyTo: String = "") {
        guard let payload = try? data.map({ try JSONEncoder().encode($0) }) ?? Data() else { return }
        sendRaw(action, direction: direction, payload: payload, id: id, inReplyTo: inReplyTo)
    }
    private func sendRaw(_ action: String, direction: IPCDirection, payload: Data, id: String, inReplyTo: String = "") {
        if receiver.checkClock() { resynchronize(); return }
        guard let key = key(), let nonce = try? random.bytes(count: 16), isExtension || !currentSession.isEmpty else { return }
        let envelope = IPCEnvelope(direction: direction, action: action, id: id, inReplyTo: inReplyTo,
                                   session: receiver.currentSession, timestamp: clock.wallTime, nonce: nonce, payload: payload)
        let wire = MessageSecurity.sign(envelope, key: key).wireString()
        guard wire.utf8.count <= IPCEnvelope.maximumWireBytes else { return }
        let name = Notification.Name(direction == .toMain ? Self.extensionToMainNotification : Self.mainToExtensionNotification)
        if let distributed = center as? DistributedNotificationCenter {
            distributed.postNotificationName(name, object: wire, userInfo: nil, deliverImmediately: true)
        } else {
            center.post(name: name, object: wire)
        }
    }
    func sendToExtension<T: Encodable>(_ action: MainToExtensionAction, data: T? = nil, inReplyTo: String = "") {
        guard !isExtension else { return }
        send(action.rawValue, direction: .toExtension, data: data, id: UUID().uuidString, inReplyTo: inReplyTo)
    }
    func sendToMain<T: Encodable>(_ action: ExtensionToMainAction, data: T? = nil, id: String = UUID().uuidString) {
        guard isExtension else { return }
        send(action.rawValue, direction: .toMain, data: data, id: id)
    }
    @MainActor func sendMenuConfig(_ config: MenuConfigPayload) {
        guard !isExtension else { return }
        let version = state.withLock { $0.configVersion += 1; return $0.configVersion }
        let versioned = MenuConfigPayload(version: version, actions: config.actions, apps: config.apps,
                                          newFiles: config.newFiles, commonDirs: config.commonDirs,
                                          actionsCollapsed: config.actionsCollapsed, appsCollapsed: config.appsCollapsed,
                                          newFilesCollapsed: config.newFilesCollapsed, commonDirsCollapsed: config.commonDirsCollapsed,
                                          iconStyle: config.iconStyle)
        guard let payload = try? JSONEncoder().encode(versioned) else { return }
        state.withLock { $0.lastConfig = payload }
        sendRaw(MainToExtensionAction.menuConfig.rawValue, direction: .toExtension, payload: payload, id: UUID().uuidString)
    }
    func sendRunningNotification(directories: [String] = []) { sendToExtension(.running, data: RunningPayload(directories: directories)) }
    func sendQuitNotification() { sendToExtension(.quit, data: Optional<Int>.none) }
    func sendActionAck(inReplyTo: String) { sendToExtension(.actionAck, data: Optional<Int>.none, inReplyTo: inReplyTo) }
    func sendHeartbeat() { sendToMain(.heartbeat, data: Optional<Int>.none) }
    func requestMenuConfig() { sendToMain(.requestConfig, data: Optional<Int>.none) }
    @discardableResult func sendClickEvent(_ event: ClickEventPayload, id: String = UUID().uuidString) -> String {
        sendToMain(.click, data: event, id: id)
        return id
    }
    func decodeSignedData<T: Decodable>(_ message: VerifiedMessage, as type: T.Type = T.self) -> T? { message.decode(type) }
}

/// Click-time liveness: each pending click owns its own three-second deadline.
nonisolated struct PendingClicks {
    private var ids: Set<String> = []
    mutating func register(_ id: String) { ids.insert(id) }
    mutating func acknowledge(_ inReplyTo: String) { ids.remove(inReplyTo) }
    mutating func expire(_ id: String) -> Bool { ids.remove(id) != nil }
}

nonisolated struct IPCFailurePolicy {
    private(set) var rejectedCount = 0
    private var lastLog: TimeInterval?
    private var noticeShown = false
    mutating func reject(now: TimeInterval) -> (log: Bool, notice: Bool) {
        rejectedCount += 1
        let log = lastLog.map { now - $0 >= 10 } ?? true
        if log { lastLog = now }
        let notice = !noticeShown
        noticeShown = true
        return (log, notice)
    }
}

@MainActor @Observable final class IPCRejectionNotice {
    static let shared = IPCRejectionNotice()
    private(set) var wasRejected = false
    func record() { wasRejected = true }
}

/// Final renderer guard: callback queues can deliver two verified configs out of
/// order even when verification itself was serialized correctly.
nonisolated struct MenuConfigDeliveryOrder {
    private var session: String?
    private var version: Int?
    mutating func accepts(session: String, version: Int, currentSession: String) -> Bool {
        guard !session.isEmpty, session == currentSession else { return false }
        if self.session == session, let previous = self.version, version < previous { return false }
        self.session = session
        self.version = version
        return true
    }
}

/// Finder's actual handler/controller seam. Cached payloads, liveness and click
/// deadlines are synchronized here; the thin extension only renders snapshots.
nonisolated final class IPCExtensionDelivery: Sendable {
    private struct State {
        var config: VerifiedMessage?
        var order = MenuConfigDeliveryOrder()
        var activity = PeerActivity()
        var pending = PendingClicks()
        var configChanged: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    private let messager: Messager
    init(messager: Messager) {
        self.messager = messager
        messager.onSessionInvalidated { [weak self] in
            self?.state.withLock { $0.config = nil; $0.activity.disconnect() }
        }
        messager.onMainMessage(.menuConfig) { [weak self] message in self?.receiveConfig(message) }
        messager.onMainMessage(.running) { [weak self] message in
            guard message.decode(RunningPayload.self) != nil else { return }
            self?.state.withLock { _ = $0.activity.receive() }
        }
        messager.onMainMessage(.quit) { [weak self] _ in self?.state.withLock { $0.activity.disconnect() } }
        messager.onMainMessage(.actionAck) { [weak self] message in
            self?.state.withLock { $0.pending.acknowledge(message.inReplyTo) }
        }
    }
    func onConfigChanged(_ handler: @escaping @Sendable () -> Void) { state.withLock { $0.configChanged = handler } }
    private func receiveConfig(_ message: VerifiedMessage) {
        struct Revision: Decodable { let version: Int }
        guard let config = message.decode(Revision.self) else { return }
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard messager.canUseCachedMenus,
                  state.order.accepts(session: message.session, version: config.version, currentSession: messager.currentSession) else { return nil }
            state.config = message
            _ = state.activity.receive()
            return state.configChanged
        }
        callback?()
    }
    func menuConfig<T: Decodable>(as type: T.Type) -> T? {
        let message: VerifiedMessage? = state.withLock { state in
            guard messager.canUseCachedMenus, state.config?.session == messager.currentSession else {
                state.config = nil
                return nil
            }
            return state.config
        }
        return message?.decode(type)
    }
    var isHostAppRunning: Bool { messager.canUseCachedMenus && state.withLock { $0.activity.isActive() } }
    func registerClick(_ id: String) { state.withLock { $0.pending.register(id) } }
    func expireClick(_ id: String) -> Bool { state.withLock { $0.pending.expire(id) } }
}
