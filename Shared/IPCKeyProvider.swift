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

nonisolated struct KeychainKeyProvider: KeyProvider {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "cn.anzchy.RClick.ipc.v2",
         kSecAttrAccount as String: "installation-key",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrAccessGroup as String: SharedAppGroup.identifier]
    }

    func key(createIfMissing: Bool) throws -> Data {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw IPCSecurityError.noKey }
            return data
        }
        // Never replace a key on a locked Keychain, denied access or any transient failure.
        guard status == errSecItemNotFound, createIfMissing else { throw IPCSecurityError.keychain(status) }
        let generated = try SystemIPCRandom().bytes(count: 32)
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = generated
        let added = SecItemAdd(add as CFDictionary, nil)
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
