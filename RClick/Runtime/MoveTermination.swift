import Foundation

@MainActor
protocol MoveTerminationBoundary: AnyObject {
    func protectMutation()
    func unprotectMutation()
    func scheduleDeadline(_ date: Date, action: @escaping @MainActor () -> Void)
}

@MainActor
final class SystemMoveTerminationBoundary: MoveTerminationBoundary {
    func protectMutation() { ProcessInfo.processInfo.disableSuddenTermination() }
    func unprotectMutation() { ProcessInfo.processInfo.enableSuddenTermination() }
    func scheduleDeadline(_ date: Date, action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            action()
        }
    }
}
