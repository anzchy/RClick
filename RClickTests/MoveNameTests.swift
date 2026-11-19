import Testing
@testable import RClick

struct MoveNameTests {
    @Test func preservesFilePackageCompoundAndFolderNames() throws {
        for (name, folder, expected) in [
            ("Report.pages", false, "Report 2.pages"), ("Foo.app", false, "Foo 2.app"),
            ("archive.tar.gz", false, "archive 2.tar.gz"), ("archive.tar.bz2", false, "archive 2.tar.bz2"),
            ("archive.tar.xz", false, "archive 2.tar.xz"), ("archive.tar.zst", false, "archive 2.tar.zst"),
            (".gitignore", false, ".gitignore 2"), ("Project.v2", true, "Project.v2 2"),
            ("data.unknown.bin", false, "data.unknown 2.bin")
        ] {
            #expect(try MoveName.candidate(name, number: 2, plainFolder: folder) == expected)
        }
        #expect(try MoveName.candidate("notes.txt", number: 3, plainFolder: false) == "notes 3.txt")
        #expect(try MoveName.candidate("notes.txt", number: 1, plainFolder: false) == "notes.txt")
        #expect(throws: MoveName.Failure.self) {
            try MoveName.candidate(String(repeating: "é", count: 125) + ".txt", number: 2, plainFolder: false)
        }
        #expect(throws: MoveName.Failure.self) {
            try MoveName.candidate("file", number: 10001, plainFolder: false)
        }
    }
}
