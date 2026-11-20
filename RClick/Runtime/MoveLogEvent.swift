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
