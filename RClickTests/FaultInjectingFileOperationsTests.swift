//
//  FaultInjectingFileOperationsTests.swift
//  RClickTests
//
//  文件操作测试替身自身的约定：没注入故障时与真实实现一致；注入后按约定失败。
//  后续的剪切 / 粘贴 / 撤销测试依赖这些失败形状（残缺副本、重名、跨卷）。
//

import Foundation
import Testing
@testable import RClick

struct FaultInjectingFileOperationsTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclick-fault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func copyThatFailsHalfwayLeavesAPartialCopyAndTheOriginal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.bin")
        let destination = dir.appendingPathComponent("b.bin")
        try Data("0123456789".utf8).write(to: source)
        let ops = FaultInjectingFileOperations()
        ops.failCopyHalfway(to: destination.path)

        #expect(throws: FaultInjectingFileOperations.InjectedFault(operation: "copy", path: destination.path)) {
            try ops.copyItem(at: source, to: destination)
        }
        #expect(try Data(contentsOf: source) == Data("0123456789".utf8))
        #expect(try Data(contentsOf: destination) == Data("01234".utf8))
    }

    @Test func coordinatedCopyThatFailsHalfwayLeavesAPartialCopy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.bin")
        let destination = dir.appendingPathComponent("b.bin")
        try Data("abcdef".utf8).write(to: source)
        let ops = FaultInjectingFileOperations()
        ops.failCopyHalfway(to: destination.path)

        #expect(throws: FaultInjectingFileOperations.InjectedFault(operation: "copy", path: destination.path)) {
            try ops.coordinatedTransfer(.copy, from: source, to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("abc".utf8))
    }

    @Test func nameAlreadyExistsFailsMoveAndCopyWithoutTouchingTheSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let destination = dir.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: source)
        let ops = FaultInjectingFileOperations()
        ops.reportNameExists(at: destination.path)

        for attempt in [
            { try ops.moveItem(at: source, to: destination) },
            { try ops.copyItem(at: source, to: destination) },
            { try ops.coordinatedTransfer(.move, from: source, to: destination) },
        ] {
            let error = #expect(throws: CocoaError.self) { try attempt() }
            #expect(error?.code == .fileWriteFileExists)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func otherVolumeChangesOnlyTheVolumeOfItemsUnderThePrefix() throws {
        let dirA = try makeTempDir()
        let dirB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let real = SystemFileOperations()
        let ops = FaultInjectingFileOperations()
        ops.placeOnOtherVolume(dirB.path)

        #expect(try real.volumeIdentity(of: dirA) == real.volumeIdentity(of: dirB))  // 前提：真实同卷
        #expect(try ops.volumeIdentity(of: dirA) == real.volumeIdentity(of: dirA))
        #expect(try ops.volumeIdentity(of: dirB) != ops.volumeIdentity(of: dirA))
        #expect(try ops.fileIdentity(of: dirB).volume == ops.volumeIdentity(of: dirB))
    }

    @Test func withoutFaultsItBehavesLikeTheRealLayer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        let copy = dir.appendingPathComponent("b.txt")
        let moved = dir.appendingPathComponent("c.txt")
        try Data("x".utf8).write(to: source)
        let ops = FaultInjectingFileOperations()

        try ops.copyItem(at: source, to: copy)
        try ops.moveItem(at: copy, to: moved)
        try ops.removeItem(at: source)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try Data(contentsOf: moved) == Data("x".utf8))
    }
}
