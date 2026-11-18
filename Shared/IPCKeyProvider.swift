import Foundation
import Security

/// The extension passes false; only main may create an installation key.
nonisolated protocol KeyProvider: Sendable {
    func key(createIfMissing: Bool) throws -> Data
}

nonisolated struct InMemoryKeyProvider: KeyProvider {
    let data: Data?
    func key(createIfMissing: Bool) throws -> Data {
        guard let data, data.count == 32 else { throw IPCSecurityError.noKey }
        return data
    }
}

/// Injectable system boundary: tests supply statuses without touching Keychain.
nonisolated struct IPCKeychainRead {
    let status: OSStatus
    let data: Data?
}
nonisolated protocol IPCKeychain: Sendable {
    func read() -> IPCKeychainRead
    func add(_ data: Data) -> OSStatus
}
nonisolated struct DataProtectionIPCKeychain: IPCKeychain {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "cn.anzchy.RClick.ipc.v2",
         kSecAttrAccount as String: "installation-key",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrAccessGroup as String: SharedAppGroup.identifier]
    }
    func read() -> IPCKeychainRead {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        return IPCKeychainRead(status: status, data: result as? Data)
    }
    func add(_ data: Data) -> OSStatus {
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }
}
nonisolated struct KeychainKeyProvider: KeyProvider {
    let keychain: any IPCKeychain
    let random: any IPCRandom
    init(keychain: any IPCKeychain = DataProtectionIPCKeychain(), random: any IPCRandom = SystemIPCRandom()) {
        self.keychain = keychain
        self.random = random
    }
    func key(createIfMissing: Bool) throws -> Data {
        let result = keychain.read()
        if result.status == errSecSuccess {
            guard let data = result.data, data.count == 32 else { throw IPCSecurityError.noKey }
            return data
        }
        // Never replace a key on a locked Keychain, denied access or transient failure.
        guard result.status == errSecItemNotFound, createIfMissing else { throw IPCSecurityError.keychain(result.status) }
        let generated = try random.bytes(count: 32)
        let added = keychain.add(generated)
        if added == errSecDuplicateItem { return try key(createIfMissing: false) }
        guard added == errSecSuccess else { throw IPCSecurityError.keychain(added) }
        return generated
    }
}

nonisolated protocol IPCRandom: Sendable {
    func bytes(count: Int) throws -> Data
}
nonisolated struct SystemIPCRandom: IPCRandom {
    func bytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw IPCSecurityError.keychain(status) }
        return Data(bytes)
    }
}

nonisolated protocol IPCClock: Sendable {
    var wallTime: TimeInterval { get }
    var monotonicTime: TimeInterval { get }
}
nonisolated struct SystemIPCClock: IPCClock {
    var wallTime: TimeInterval { Date().timeIntervalSince1970 }
    var monotonicTime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
