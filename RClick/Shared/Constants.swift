//
//  Constants.swift
//  RClick
//
//  Created by 李旭 on 2024/9/25.
//

import Foundation


public enum Constants {
    /// The identifier for the settings window.
    static let settingsWindowID = "rclick-settings"
    /// Protect the home and its essential folders, the filesystem root, and OS installation roots.
    /// Match these folders themselves; their children remain available for file actions.
    static func protectedDirs(homeDirectory: String) -> [String] {
        [
            homeDirectory,
            homeDirectory + "/Desktop",
            homeDirectory + "/Documents",
            homeDirectory + "/Library",
            homeDirectory + "/Applications",
            "/", "/Applications", "/System", "/Library", "/Users",
            "/usr", "/bin", "/sbin", "/var"
        ]
    }
    static let suitName = SharedAppGroup.identifier

}
