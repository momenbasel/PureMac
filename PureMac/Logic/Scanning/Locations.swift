//
//  Locations.swift
//  PureMac
//
//  Defines all macOS filesystem locations where applications leave files.
//  Used by the heuristic scan engine to discover app-related artifacts.
//

import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path

class Locations: ObservableObject {

    struct SearchCategory {
        let name: String
        var paths: [String]
    }

    // Standard macOS Library subdirectories.
    // Used to determine if depth=2 matches should add the parent directory (vendor folders)
    // or the matched item itself (standard system folders).
    static let standardLibrarySubdirectories: Set<String> = [
        "Application Scripts", "Application Support", "Caches",
        "Containers", "Group Containers", "HTTPStorages",
        "Internet Plug-Ins", "LaunchAgents", "LaunchDaemons",
        "Logs", "Preferences", "PreferencePanes",
        "PrivilegedHelperTools", "Saved Application State",
        "Services", "WebKit", "Extensions", "Frameworks"
    ]

    let cacheDir: String
    let tempDir: String
    var appSearch: SearchCategory
    var reverseSearch: SearchCategory

    init() {
        let (cacheDir, tempDir) = Locations.darwinCT()
        self.cacheDir = cacheDir
        self.tempDir = tempDir

        self.appSearch = SearchCategory(name: "Apps", paths: [
            // User home
            "\(home)",
            "\(home)/.config",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Applications",
            // User Library
            "\(home)/Library",
            "\(home)/Library/Application Scripts",
            "\(home)/Library/Application Support",
            "\(home)/Library/Application Support/CrashReporter",
            "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
            "\(home)/Library/Containers",
            "\(home)/Library/Caches",
            "\(home)/Library/Caches/com.apple.helpd/Generated",
            "\(home)/Library/Caches/com.crashlytics",
            "\(home)/Library/Caches/com.google.SoftwareUpdate",
            "\(home)/Library/Caches/com.google.Keystone",
            "\(home)/Library/Caches/org.sparkle-project.Sparkle",
            "\(home)/Library/Caches/com.segment.analytics",
            "\(home)/Library/Caches/SentryCrash",
            "\(home)/Library/Caches/Rollbar",
            "\(home)/Library/Caches/Amplitude",
            "\(home)/Library/Caches/Realm",
            "\(home)/Library/Caches/Parse",
            "\(home)/Library/Group Containers",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/Internet Plug-Ins",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Logs",
            "\(home)/Library/Logs/DiagnosticReports",
            "\(home)/Library/Preferences",
            "\(home)/Library/PreferencePanes",
            "\(home)/Library/Preferences/ByHost",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/Services",
            "\(home)/Library/WebKit",
            // System-wide
            "/Applications",
            "/Users/Shared",
            "/Users/Shared/Library/Application Support",
            "/Library",
            "/Library/Application Support",
            "/Library/Application Support/CrashReporter",
            "/Library/Caches",
            "/Library/Extensions",
            "/Library/Internet Plug-Ins",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/Logs",
            "/Library/Logs/DiagnosticReports",
            "/Library/Preferences",
            "/Library/PrivilegedHelperTools",
            "/private/var/db/receipts",
            "/private/tmp",
            "/usr/local/bin",
            "/usr/local/etc",
            "/usr/local/opt",
            "/usr/local/sbin",
            "/usr/local/share",
            "/usr/local/var",
            cacheDir,
            tempDir
        ])

        // Dynamically append Application Support subfolders for deeper search
        let subfolders = Locations.listAppSupportDirectories()
        for folder in subfolders {
            self.appSearch.paths.append("\(home)/Library/Application Support/\(folder)")
        }

        self.reverseSearch = SearchCategory(name: "Reverse", paths: [
            "\(home)/Library/Application Scripts",
            "\(home)/Library/Application Support",
            "\(home)/Library/Application Support/Caches",
            "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
            "\(home)/Library/Containers",
            "\(home)/Library/Caches",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/Internet Plug-Ins",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Logs",
            "\(home)/Library/Preferences",
            "\(home)/Library/PreferencePanes",
            "\(home)/Library/Preferences/ByHost",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/WebKit",
            "/Users/Shared/Library/Application Support",
            "/Library/Application Support",
            "/Library/Application Support/CrashReporter",
            "/Library/Internet Plug-Ins",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
        ])
    }

    static func darwinCT() -> (String, String) {
        var cacheDir = ""
        var tempDir = ""
        if let cfCacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first {
            cacheDir = cfCacheDir
        }
        if let cfTempDir = ProcessInfo.processInfo.environment["TMPDIR"] {
            tempDir = cfTempDir
        }
        return (cacheDir, tempDir)
    }

    static func listAppSupportDirectories() -> [String] {
        let appSupportPath = "\(home)/Library/Application Support"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appSupportPath) else {
            return []
        }
        return contents.filter { item in
            var isDir: ObjCBool = false
            let fullPath = (appSupportPath as NSString).appendingPathComponent(item)
            return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
