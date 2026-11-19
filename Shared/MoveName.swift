import Foundation

/// Bounded keep-both naming. Only an exclusive rename decides whether a name is free.
nonisolated enum MoveName {
    enum Failure: Error { case tooLong, exhausted }
    static func candidate(_ name: String, number: Int, plainFolder: Bool) throws -> String {
        guard (1...10000).contains(number) else { throw Failure.exhausted }
        let result: String
        if number == 1 { result = name }
        else if plainFolder { result = "\(name) \(number)" }
        else {
            let compounds = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]
            let suffix: String
            if let compound = compounds.first(where: { name.lowercased().hasSuffix("." + $0) }) {
                suffix = String(name.suffix(compound.count + 1))
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                suffix = String(name[dot...])
            } else { suffix = "" }
            result = "\(name.dropLast(suffix.count)) \(number)\(suffix)"
        }
        guard result.utf8.count <= 255 else { throw Failure.tooLong }
        return result
    }
}
