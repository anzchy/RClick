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
    static func protectedDirs(homeDirectory: String) -> [String] {
        [
        homeDirectory + "/Desktop/",
        homeDirectory + "/Desktop/danger/",
        homeDirectory + "/Applications/",
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]
    }
    static let suitName = SharedAppGroup.identifier

}
