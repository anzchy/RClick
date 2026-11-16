import Testing

@testable import RClick

struct LaunchSideEffectsTests {
    @Test func testHostIsInertAndNormalLaunchRemainsEnabled() {
        // The same policy gates Settings, login-item migration, handler registration,
        // launch broadcasts and the termination broadcast.
        #expect(!LaunchSideEffects.shouldRun(isTestHost: true))
        #expect(LaunchSideEffects.shouldRun(isTestHost: false))
        // Hosted tests must use the inert branch without caller configuration.
        #expect(!LaunchSideEffects.shouldRun())
    }
}
