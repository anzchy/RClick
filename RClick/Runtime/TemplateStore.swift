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
