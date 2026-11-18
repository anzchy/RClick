import Foundation
import Security
import Synchronization
import XCTest
@testable import RClick

@MainActor final class IPCKeyProviderTests: XCTestCase {
    func testMainCreatesOnlyOnGenuineNotFound() throws {
        let store = TestIPCKeychain(reads: [.init(status: errSecItemNotFound, data: nil)])
        let provider = KeychainKeyProvider(keychain: store, random: FixedIPCRandom(value: 0x7e))
        XCTAssertEqual(try provider.key(createIfMissing: true), Data(repeating: 0x7e, count: 32))
        XCTAssertEqual(store.additions, [Data(repeating: 0x7e, count: 32)])
    }
    func testExtensionNeverCreatesAndTransientErrorsNeverRegenerate() {
        for (status, mayCreate) in [(errSecItemNotFound, false), (errSecInteractionNotAllowed, true), (errSecMissingEntitlement, true), (errSecAuthFailed, true)] {
            let store = TestIPCKeychain(reads: [.init(status: status, data: nil)])
            XCTAssertThrowsError(try KeychainKeyProvider(keychain: store).key(createIfMissing: mayCreate))
            XCTAssertEqual(store.additions, [])
        }
    }
    func testDuplicateCreationReadsWinnerInsteadOfReturningLoser() throws {
        let winner = Data(repeating: 0x55, count: 32)
        let store = TestIPCKeychain(reads: [.init(status: errSecItemNotFound, data: nil), .init(status: errSecSuccess, data: winner)], added: errSecDuplicateItem)
        let provider = KeychainKeyProvider(keychain: store, random: FixedIPCRandom(value: 0x7e))
        XCTAssertEqual(try provider.key(createIfMissing: true), winner)
        XCTAssertEqual(store.additions.count, 1)
    }
    func testExistingKeyReadOnlyAndMalformedKeyOrAddFailureFailClosed() throws {
        let original = Data(repeating: 0x55, count: 32)
        let store = TestIPCKeychain(reads: [.init(status: errSecSuccess, data: original)])
        XCTAssertEqual(try KeychainKeyProvider(keychain: store).key(createIfMissing: false), original)
        XCTAssertEqual(store.additions, [])
        for malformed in [Data(), Data(repeating: 1, count: 31)] {
            let invalid = TestIPCKeychain(reads: [.init(status: errSecSuccess, data: malformed)])
            XCTAssertThrowsError(try KeychainKeyProvider(keychain: invalid).key(createIfMissing: true))
            XCTAssertEqual(invalid.additions, [])
        }
        let denied = TestIPCKeychain(reads: [.init(status: errSecItemNotFound, data: nil)], added: errSecMissingEntitlement)
        XCTAssertThrowsError(try KeychainKeyProvider(keychain: denied).key(createIfMissing: true))
    }
}

nonisolated struct FixedIPCRandom: IPCRandom {
    let value: UInt8
    func bytes(count: Int) throws -> Data { Data(repeating: value, count: count) }
}
nonisolated final class TestIPCKeychain: IPCKeychain {
    private struct State {
        var reads: [IPCKeychainRead]
        var additions: [Data] = []
    }
    private let state: Mutex<State>
    private let added: OSStatus
    init(reads: [IPCKeychainRead], added: OSStatus = errSecSuccess) {
        state = Mutex(State(reads: reads))
        self.added = added
    }
    var additions: [Data] { state.withLock { $0.additions } }
    func read() -> IPCKeychainRead { state.withLock { $0.reads.removeFirst() } }
    func add(_ data: Data) -> OSStatus {
        state.withLock { $0.additions.append(data) }
        return added
    }
}
