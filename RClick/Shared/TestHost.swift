import Foundation

/// Shared detection for the app process launched by the unit-test runner.
enum TestHost {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }
}
