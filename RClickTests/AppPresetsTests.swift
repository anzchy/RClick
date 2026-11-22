import AppKit
import Foundation
import Testing
@testable import RClick

@MainActor
struct AppPresetsTests {
    @Test func presetsHaveUniqueIdentifiersAndResolvableSymbols() {
        #expect(Set(AppPresets.all.map(\.bundleID)).count == AppPresets.all.count)
        for preset in AppPresets.all {
            #expect(NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil) != nil)
        }
        #expect(AppPresets.all.first { $0.nameKey == "WebStorm" }?.bundleID == "com.jetbrains.WebStorm")
    }

    @Test func targetsRespectPresetOverridesAndKeepDirectoriesAndMissingPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a file.txt")
        let missing = root.appendingPathComponent("missing.txt")
        try Data().write(to: file)
        // A real, minimal bundle avoids depending on which apps are installed.
        let terminal = root.appendingPathComponent("Terminal.app")
        try FileManager.default.createDirectory(at: terminal.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.apple.Terminal", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: terminal.appendingPathComponent("Contents/Info.plist"))
        let targets = [file.path, root.path, missing.path]
        #expect(AppPresets.resolveOpenTargets(appPath: terminal.path, explicit: nil, targetPaths: targets).map(\.url) == [root, root, missing])
        #expect(AppPresets.resolveOpenTargets(appPath: terminal.path, explicit: false, targetPaths: targets).map(\.url) == [file, root, missing])
        #expect(AppPresets.resolveOpenTargets(appPath: nil, explicit: true, targetPaths: targets).map(\.url) == [root, root, missing])
        #expect(AppPresets.resolveOpenTargets(appPath: nil, explicit: nil, targetPaths: targets).map(\.url) == [file, root, missing])
        #expect(AppPresets.resolveOpenTargets(appPath: nil, explicit: true, targetPaths: []).isEmpty)
        let encodedFile = file.absoluteString
        let resolved = AppPresets.resolveOpenTargets(appPath: nil, explicit: true, targetPaths: [encodedFile])
        #expect(resolved.first?.path == file.path)
        #expect(resolved.first?.url == root)
    }

    @Test func symbolsReuseImagesWithinEachAppearance() throws {
        let light = try #require(MenuSymbolIcon.image(named: "terminal", pointSize: 16, isDark: false))
        #expect(light === MenuSymbolIcon.image(named: "terminal", pointSize: 16, isDark: false))
        let dark = try #require(MenuSymbolIcon.image(named: "terminal", pointSize: 16, isDark: true))
        #expect(light !== dark)
        #expect(dark === MenuSymbolIcon.image(named: "terminal", pointSize: 16, isDark: true))
    }
}


extension AppPresetsTests {
    @Test func openTargetsPreserveRawPercentNamesAndDecodeOnlyFileURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["100%41.txt", "50% off %20.txt", "only%42.txt"] {
            let file = root.appendingPathComponent(name)
            try Data("raw".utf8).write(to: file)
            let resolved = AppPresets.resolveOpenTargets(appPath: nil, explicit: false, targetPaths: [file.path, file.absoluteString])
            #expect(resolved.map(\.url) == [file, file])
            #expect(resolved.map(\.path) == [file.path, file.path])
            #expect(resolved.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            #expect(AppPresets.resolveOpenTargets(appPath: nil, explicit: true, targetPaths: [file.path]).first?.url == root)
        }
    }
}
