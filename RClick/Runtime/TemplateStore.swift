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
        let directory = baseURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return NewFile.Template(id: id, name: source.lastPathComponent, path: destination.path)
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

    mutating func add(_ source: URL, store: TemplateStore) throws {
        let snapshot = try FileWrapper(url: source, options: .immediate)
        let entry = NewFile.Template(name: source.lastPathComponent)
        pending[entry.id] = snapshot
        entries.append(entry)
    }
}
