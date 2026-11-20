import Foundation
import Testing
@testable import RClick

@MainActor
struct OfficeTemplateTests {
    @Test func bundledPackagesContainMainPartsAndNeutralMetadata() throws {
        for (ext, part) in [("docx", "word/document.xml"), ("pptx", "ppt/presentation.xml")] {
            let url = try #require(Bundle.main.url(forResource: "template", withExtension: ext))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", url.path, "-d", directory.path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("[Content_Types].xml").path))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(part).path))
            let metadata = try String(contentsOf: directory.appendingPathComponent("docProps/core.xml"), encoding: .utf8)
            #expect(!metadata.contains("Steve Canny"))
            #expect(!metadata.contains("/Users/"))
            #expect(!metadata.contains("@"))
            #expect(!metadata.contains("generated"))
            #expect(!metadata.contains("python-docx"))
        }
    }
}
