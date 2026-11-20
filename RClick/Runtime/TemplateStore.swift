import Foundation

/// Owns template snapshots. The caller supplies a temporary root in tests.
@MainActor
struct TemplateStore {
    let baseURL: URL
    static var standard: TemplateStore {
        TemplateStore(baseURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RClick/Templates", isDirectory: true))
    }

    func importFile(_ source: URL) throws -> NewFile.Template {
        let id = UUID().uuidString
        let snapshot = try FileWrapper(url: source, options: .immediate)
        let destination = try write(snapshot, id: id, originalName: source.lastPathComponent)
        return NewFile.Template(id: id, name: source.lastPathComponent, path: destination.path)
    }

    func write(_ snapshot: FileWrapper, id: String, originalName: String) throws -> URL {
        guard UUID(uuidString: id) != nil, originalName == URL(fileURLWithPath: originalName).lastPathComponent,
              originalName != ".", originalName != "..", !originalName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // A snapshot must not retain live symbolic references to the user's files.
        func validate(_ item: FileWrapper) throws {
            guard !item.isSymbolicLink else { throw CocoaError(.fileReadUnsupportedScheme) }
            if item.isDirectory {
                for child in item.fileWrappers?.values ?? Dictionary<String, FileWrapper>().values { try validate(child) }
            }
        }
        try validate(snapshot)
        let directory = baseURL.appendingPathComponent(id, isDirectory: true)
        let destination = directory.appendingPathComponent(originalName)
        guard owns(destination) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot.write(to: destination, options: .atomic, originalContentsURL: nil)
        return destination
    }

    /// Only snapshot children or the old store's direct children can be deleted.
    /// Resolve symlinks before checking containment, never trust a backup path or ID.
    func owns(_ url: URL) -> Bool {
        let root = baseURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard path.starts(with: root), path.count > root.count else { return false }
        let relative = Array(path.dropFirst(root.count))
        return relative.count == 1 || (relative.count == 2 && UUID(uuidString: relative[0]) != nil)
    }

    func remove(_ entry: NewFile.Template) throws {
        guard let path = entry.path else { return }
        let url = URL(fileURLWithPath: path)
        guard owns(url), FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent != baseURL, (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try FileManager.default.removeItem(at: parent)
        }
    }

}

/// Value-owned sheet edits. Discarding this value is Cancel.
@MainActor
struct TemplateDraft {
    var entries: [NewFile.Template]
    var blankEnabled: Bool
    private var pending: [String: FileWrapper] = [:]

    init(file: NewFile) {
        entries = file.userTemplates
        blankEnabled = file.usesBlank
    }

    mutating func replace(id: String, source: URL) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        pending[id] = try FileWrapper(url: source, options: .immediate)
    }

    mutating func rename(id: String, name: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].name = uniqueName(name, excluding: id)
    }

    private func uniqueName(_ proposed: String, excluding id: String? = nil) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? AppLocalization.localized("Template") : trimmed
        let names = Set(entries.filter { $0.id != id }.map { $0.name.lowercased() })
        var candidate = base
        var suffix = 2
        while names.contains(candidate.lowercased()) { candidate = "\(base) \(suffix)"; suffix += 1 }
        return candidate
    }

    func save(store: TemplateStore, replacing old: [NewFile.Template]) throws -> [NewFile.Template] {
        var saved = entries
        for index in saved.indices {
            let id = saved[index].id
            if let snapshot = pending[id] {
                let url = try store.write(snapshot, id: id, originalName: snapshot.preferredFilename ?? "template")
                saved[index].path = url.path
            }
        }
        let kept = Set(saved.compactMap(\.path))
        for entry in old where !(entry.path.map { kept.contains($0) } ?? false) { try store.remove(entry) }
        return saved
    }

    mutating func add(_ source: URL, store: TemplateStore) throws {
        let snapshot = try FileWrapper(url: source, options: .immediate)
        let entry = NewFile.Template(name: uniqueName(source.lastPathComponent))
        pending[entry.id] = snapshot
        entries.append(entry)
    }
}
