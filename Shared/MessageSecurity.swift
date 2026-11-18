import Foundation
import CryptoKit
import Synchronization

nonisolated enum IPCSecurityError: Error {
    case noKey, malformed, unauthenticated, direction, session, freshness, replay, capacity, configVersion
    case keychain(Int32)
}

nonisolated enum IPCDirection: String, Sendable {
    case toMain, toExtension
}

/// Wire format: ten UInt32 big-endian length-prefixed fields. The first nine
/// fields, including the original payload bytes, are the HMAC input. No JSON
/// re-encoding, optional signed-data field, or separately decoded payload exists.
nonisolated struct IPCEnvelope: Sendable {
    static let maximumWireBytes = 256 * 1024 // Includes base64 transport overhead.
    var version = "2"
    var direction: IPCDirection
    var action: String
    var id: String
    var inReplyTo: String = ""
    var session: String
    var timestamp: TimeInterval
    var nonce: Data
    var payload: Data = Data()
    var mac: Data = Data()

    var authenticatedBytes: Data {
        var bits = timestamp.bitPattern.bigEndian
        let time = withUnsafeBytes(of: &bits) { Data($0) }
        return Self.pack([Data(version.utf8), Data(direction.rawValue.utf8), Data(action.utf8),
                          Data(id.utf8), Data(inReplyTo.utf8), Data(session.utf8), time, nonce, payload])
    }
    func wireString() -> String { (authenticatedBytes + Self.pack([mac])).base64EncodedString() }

    static func parse(_ wire: String) throws -> IPCEnvelope {
        guard wire.utf8.count <= maximumWireBytes,
              let data = Data(base64Encoded: wire) else { throw IPCSecurityError.malformed }
        var offset = 0
        func field() throws -> Data {
            guard data.count - offset >= 4 else { throw IPCSecurityError.malformed }
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard Int(length) <= data.count - offset else { throw IPCSecurityError.malformed }
            defer { offset += Int(length) }
            return Data(data[offset..<(offset + Int(length))])
        }
        func string() throws -> String {
            guard let value = String(data: try field(), encoding: .utf8) else { throw IPCSecurityError.malformed }
            return value
        }
        let version = try string()
        guard version == "2", let direction = IPCDirection(rawValue: try string()) else { throw IPCSecurityError.malformed }
        let action = try string(), id = try string(), reply = try string(), session = try string()
        let time = try field()
        guard time.count == 8 else { throw IPCSecurityError.malformed }
        let timestamp = Double(bitPattern: time.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        let nonce = try field(), payload = try field(), mac = try field()
        guard offset == data.count, nonce.count == 16, mac.count == 32, !id.isEmpty,
              timestamp.isFinite else { throw IPCSecurityError.malformed }
        return IPCEnvelope(version: version, direction: direction, action: action, id: id,
                           inReplyTo: reply, session: session, timestamp: timestamp, nonce: nonce, payload: payload, mac: mac)
    }

    private static func pack(_ fields: [Data]) -> Data {
        var output = Data()
        for field in fields {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(field)
        }
        return output
    }
}

nonisolated enum MessageSecurity {
    static func sign(_ envelope: IPCEnvelope, key: Data) -> IPCEnvelope {
        var signed = envelope
        signed.mac = Data(HMAC<SHA256>.authenticationCode(for: envelope.authenticatedBytes, using: SymmetricKey(data: key)))
        return signed
    }
    static func verify(_ envelope: IPCEnvelope, key: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.authenticatedBytes, using: SymmetricKey(data: key))
    }
}

/// Only created after authentication, never from a second payload field.
nonisolated struct VerifiedMessage: Sendable {
    fileprivate let envelope: IPCEnvelope
    var id: String { envelope.id }
    var inReplyTo: String { envelope.inReplyTo }
    var session: String { envelope.session }
    var action: String { envelope.action }
    func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        try? JSONDecoder().decode(type, from: envelope.payload)
    }
}

/// The receiver owns verification and its atomic state, independent of callback
/// queues. Dispatch is always downstream of this boundary.
nonisolated final class IPCReceiver: Sendable {
    let direction: IPCDirection
    let clock: any IPCClock
    private let capacity: Int
    private struct State {
        var session: String
        var configVersion: Int?
        var nonces: [Data: TimeInterval] = [:]
    }
    private let state: Mutex<State>
    var currentSession: String { state.withLock { $0.session } }
    init(direction: IPCDirection, clock: any IPCClock = SystemIPCClock(), capacity: Int = 1024, session: String = "") {
        self.direction = direction
        self.clock = clock
        self.capacity = capacity
        self.state = Mutex(State(session: session))
    }
    func receive(_ wire: String, key: Data) throws -> VerifiedMessage {
        let envelope = try IPCEnvelope.parse(wire)
        guard MessageSecurity.verify(envelope, key: key) else { throw IPCSecurityError.unauthenticated }
        guard envelope.direction == direction else { throw IPCSecurityError.direction }
        try state.withLock { state in
            let announcesSession = direction == .toExtension && ["running", "menu-config"].contains(envelope.action)
            if direction == .toMain {
                let bootstrap = envelope.session.isEmpty && ["heartbeat", "request-config"].contains(envelope.action)
                guard bootstrap || (!state.session.isEmpty && envelope.session == state.session) else { throw IPCSecurityError.session }
            } else if announcesSession {
                guard !envelope.session.isEmpty else { throw IPCSecurityError.session }
            } else {
                guard !state.session.isEmpty, envelope.session == state.session else { throw IPCSecurityError.session }
            }
            let age = clock.wallTime - envelope.timestamp
            guard age <= 5, age >= -1 else { throw IPCSecurityError.freshness }
            var cache = state.nonces
            defer { state.nonces = cache }
            let now = clock.monotonicTime
            cache = cache.filter { now - $0.value < 15 }
            guard cache[envelope.nonce] == nil else { throw IPCSecurityError.replay }
            guard cache.count < capacity else { throw IPCSecurityError.capacity }
            cache[envelope.nonce] = now
            if envelope.action == "menu-config", direction == .toExtension {
                struct Revision: Decodable { let version: Int }
                guard let revision = try? JSONDecoder().decode(Revision.self, from: envelope.payload),
                      revision.version >= 0 else { throw IPCSecurityError.configVersion }
                let previous = envelope.session == state.session ? state.configVersion : nil
                guard previous == nil || revision.version >= previous! else { throw IPCSecurityError.configVersion }
                state.configVersion = revision.version
            } else if announcesSession, envelope.session != state.session {
                state.configVersion = nil
            }
            if announcesSession { state.session = envelope.session }
        }
        return VerifiedMessage(envelope: envelope)
    }
}
