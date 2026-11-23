import Foundation
import OSLog

/// Closed vocabulary for the public move log. No event field can carry a path,
/// name, identity, arbitrary error description or other file-derived string.
nonisolated struct MoveLogEvent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case moved, partial, refused, coordinationTimeout, journalFailure
        case recoverySkipped, recoveryFailed, recoveryExpired, destinationChanged
    }
    enum Reason: String, Hashable, Sendable {
        case busy, staleCut, invalidTarget, permission, cancelled
        case systemRoot, trash, package, notFolder, sourceChanged, destinationChanged
        case crossVolume, insideSource, mountPoint, cloud, timeout, unsupported
        case nameTooLong, nameExhausted, missing, filesystem, clipboard
        case journalUnavailable, journalRead, journalWrite, journalDiscarded
        case missingAccess, ambiguous, recoveryRead, expired
    }
    let kind: Kind
    var moved = 0
    var total = 0
    var affected = 0
    var reasons: Set<Reason> = []

    var message: String {
        let labels = reasons.isEmpty ? "none" : reasons.map(\.rawValue).sorted().joined(separator: ",")
        return "Paste kind=\(kind.rawValue) moved=\(moved) total=\(total) affected=\(affected) reasons=\(labels)"
    }
}


/// Only fixed text, integer diagnostics, and closed labels can enter public logs.
/// Deliberately no String initializer, String interpolation, or String append API:
/// `ActionLogMessage(arbitraryString)` and `.text(arbitraryString)` must not compile.
nonisolated struct ActionLogMessage: Sendable {
    private(set) var rendered: String
    init(_ text: StaticString) { rendered = text.description }
    func text(_ text: StaticString) -> Self {
        var copy = self; copy.rendered += text.description; return copy
    }
    func number(_ value: Int) -> Self {
        var copy = self; copy.rendered += String(value); return copy
    }
    enum ErrorDomain: Sendable {
        case cocoa, posix, other
        init(_ error: NSError) {
            switch error.domain {
            case NSCocoaErrorDomain: self = .cocoa
            case NSPOSIXErrorDomain: self = .posix
            default: self = .other
            }
        }
        var label: StaticString {
            switch self {
            case .cocoa: "NSCocoaErrorDomain"
            case .posix: "NSPOSIXErrorDomain"
            case .other: "other"
            }
        }
    }
    func domain(_ domain: ErrorDomain) -> Self { text(domain.label) }

    // MoveLogEvent has only closed enum cases and integer counts. Keep its
    // existing sorted reason vocabulary without accepting an arbitrary String.
    static func move(_ event: MoveLogEvent) -> Self {
        var message = Self("Paste kind=")
        message.rendered += event.kind.rawValue
        message = message.text(" moved=").number(event.moved).text(" total=").number(event.total)
            .text(" affected=").number(event.affected).text(" reasons=")
        if event.reasons.isEmpty { return message.text("none") }
        for (index, reason) in event.reasons.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            if index > 0 { message = message.text(",") }
            message.rendered += reason.rawValue
        }
        return message
    }
}

/// OSLog and the optional recorder receive exactly the same safe message.
nonisolated struct ActionLogger: Sendable {
    let system: Logger
    let sink: (@Sendable (String) -> Void)?
    func debug(_ message: ActionLogMessage) { system.debug("\(message.rendered, privacy: .public)"); sink?(message.rendered) }
    func info(_ message: ActionLogMessage) { system.info("\(message.rendered, privacy: .public)"); sink?(message.rendered) }
    func warning(_ message: ActionLogMessage) { system.warning("\(message.rendered, privacy: .public)"); sink?(message.rendered) }
    func error(_ message: ActionLogMessage) { system.error("\(message.rendered, privacy: .public)"); sink?(message.rendered) }
}
