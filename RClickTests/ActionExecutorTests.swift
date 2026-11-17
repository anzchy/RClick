//
//  ActionExecutorTests.swift
//  RClickTests
//
//  ActionExecutor 单测：提交的工作不在主线程上跑，并且一次只跑一项。
//

import Foundation
import Synchronization
import Testing
@testable import RClick

struct ActionExecutorTests {

    /// 记录同时在跑的工作数与历史最大值，供多个后台线程并发写入。
    private final class OverlapProbe: Sendable {
        private struct State {
            var active = 0
            var maxActive = 0
            var finished = 0
            var ranOnMainThread = false
        }
        private let state = Mutex(State())

        func enter() {
            let onMain = Thread.isMainThread
            state.withLock {
                $0.active += 1
                $0.maxActive = max($0.maxActive, $0.active)
                if onMain { $0.ranOnMainThread = true }
            }
        }

        func leave() {
            state.withLock {
                $0.active -= 1
                $0.finished += 1
            }
        }

        var maxActive: Int { state.withLock { $0.maxActive } }
        var finished: Int { state.withLock { $0.finished } }
        var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }
    }

    @MainActor
    @Test func workSubmittedFromTheMainActorRunsOffTheMainThread() async {
        let executor = ActionExecutor()

        let ranOnMain = await executor.run { Thread.isMainThread }

        #expect(ranOnMain == false)
    }

    @Test func concurrentSubmissionsRunOneAtATime() async {
        let executor = ActionExecutor()
        let probe = OverlapProbe()
        let submissions = 8

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<submissions {
                group.addTask {
                    await executor.run {
                        probe.enter()
                        Thread.sleep(forTimeInterval: 0.02)  // 让重叠有机会发生
                        probe.leave()
                    }
                }
            }
        }

        #expect(probe.finished == submissions)
        #expect(probe.maxActive == 1)
        #expect(probe.ranOnMainThread == false)
    }

    @Test func aThrownErrorReachesTheCaller() async {
        struct Boom: Error {}
        let executor = ActionExecutor()

        await #expect(throws: Boom.self) {
            try await executor.run { () throws(Boom) -> Int in throw Boom() }
        }
    }
}
