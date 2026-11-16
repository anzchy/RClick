import Foundation
import Testing

@testable import RClick

@MainActor
struct LaunchSideEffectsTests {
    @Test func testHostIsInertAndNormalLaunchRemainsEnabled() {
        // Pins the policy values; the lifecycle tests below pin the delegate wiring.
        #expect(!LaunchSideEffects.shouldRun(isTestHost: true))
        #expect(LaunchSideEffects.shouldRun(isTestHost: false))
        // Hosted tests must use the inert branch without caller configuration.
        #expect(!LaunchSideEffects.shouldRun())
    }

    @Test func hostedLaunchNeverStartsSideEffects() {
        // The real host has finished applicationDidFinishLaunching before tests run.
        // The marker precedes Settings, login migration, observers, handlers and sends.
        #expect(!AppDelegate.launchSideEffectsStarted)
    }

    @Test func terminationSendsQuitOnlyOutsideTheTestHost() {
        var testHostSends = 0
        let testHost = AppDelegate(isTestHost: true, sendQuit: { testHostSends += 1 })
        let notification = Notification(name: Notification.Name("testTermination"))
        testHost.applicationWillTerminate(notification)
        #expect(testHostSends == 0)

        var normalSends = 0
        let normal = AppDelegate(isTestHost: false, sendQuit: { normalSends += 1 })
        normal.applicationWillTerminate(notification)
        #expect(normalSends == 1)
    }
}
