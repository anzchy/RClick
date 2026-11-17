//
//  ActionExecutor.swift
//  RClick
//
//  动作的串行后台执行器：长时间的文件操作放到这里跑，主线程保持响应。
//  弹窗与授权面板不在这里：它们留在 MainActor 上，由 ActionService 在提交工作前后处理。
//

import Foundation

/// 串行后台执行器。
///
/// 每次 `run` 的工作闭包都在 actor 上同步执行（闭包内没有挂起点），
/// 所以同一时刻只有一项工作在跑；actor 的默认执行器是全局协作线程池，不会是主线程。
actor ActionExecutor {
    nonisolated func run<T: Sendable, E: Error>(_ work: @Sendable () throws(E) -> T) async throws(E) -> T {
        try work()
    }
}
