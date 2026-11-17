//
//  FileOperationsTests.swift
//  RClickTests
//
//  SystemFileOperations 单测：在临时目录里用真实文件验证移动、复制、删除、
//  卷与文件身份、可写性，以及经 NSFileCoordinator 协调的移动或复制。
//

import Foundation
import Testing
@testable import RClick

struct FileOperationsTests {

    private let ops: any FileOperations = SystemFileOperations()

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func moveRelocatesTheItemAndKeepsItsIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try write("hello", to: source)
        let before = try ops.fileIdentity(of: source)

        try ops.moveItem(at: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try contents(of: destination) == "hello")
        #expect(try ops.fileIdentity(of: destination) == before)
    }

    @Test func copyDuplicatesTheItemWithANewIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try write("hello", to: source)

        try ops.copyItem(at: source, to: destination)

        #expect(try contents(of: source) == "hello")
        #expect(try contents(of: destination) == "hello")
        #expect(try ops.fileIdentity(of: destination) != ops.fileIdentity(of: source))
    }

    @Test func copyOntoAnExistingNameFailsAndLeavesBothItems() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try write("new", to: source)
        try write("old", to: destination)

        #expect(throws: CocoaError.self) { try ops.copyItem(at: source, to: destination) }
        #expect(try contents(of: destination) == "old")
        #expect(try contents(of: source) == "new")
    }

    @Test func removeDeletesTheItem() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try write("x", to: file)

        try ops.removeItem(at: file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func itemsInOneDirectoryShareAVolumeIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try write("a", to: a)
        try write("b", to: b)

        #expect(try ops.volumeIdentity(of: a) == ops.volumeIdentity(of: dir))
        #expect(try ops.volumeIdentity(of: a) == ops.volumeIdentity(of: b))
        #expect(try ops.fileIdentity(of: a).volume == ops.volumeIdentity(of: a))
    }

    @Test func identityOfAMissingItemThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.txt")

        #expect(throws: (any Error).self) { try ops.fileIdentity(of: missing) }
        #expect(throws: (any Error).self) { try ops.volumeIdentity(of: missing) }
    }

    @Test func writabilityFollowsPermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writable = dir.appendingPathComponent("rw.txt")
        let readOnly = dir.appendingPathComponent("ro.txt")
        try write("rw", to: writable)
        try write("ro", to: readOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)

        #expect(ops.isWritable(writable))
        #expect(!ops.isWritable(readOnly))
        #expect(ops.isWritable(dir))
    }

    @Test func coordinatedMoveRelocatesTheItem() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try write("moved", to: source)

        try ops.coordinatedTransfer(.move, from: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try contents(of: destination) == "moved")
    }

    @Test func coordinatedCopyDuplicatesTheItem() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try write("copied", to: source)

        try ops.coordinatedTransfer(.copy, from: source, to: destination)

        #expect(try contents(of: source) == "copied")
        #expect(try contents(of: destination) == "copied")
    }

    @Test func coordinatedTransferOntoAnExistingNameThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try write("new", to: source)
        try write("old", to: destination)

        #expect(throws: (any Error).self) { try ops.coordinatedTransfer(.move, from: source, to: destination) }
        #expect(try contents(of: source) == "new")
        #expect(try contents(of: destination) == "old")
    }
}
