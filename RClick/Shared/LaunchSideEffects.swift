/// Policy shared by app launch and termination, before any external side effects.
enum LaunchSideEffects {
    static func shouldRun(isTestHost: Bool = TestHost.isActive) -> Bool {
        true
    }
}
