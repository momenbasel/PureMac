//
//  Conditions.swift
//  PureMac
//
//  Per-app matching rules and system-level skip conditions for the heuristic scan engine.
//  These define edge cases where bundle ID and app name matching alone is insufficient.
//

import Foundation

// MARK: - AppCondition

/// Defines per-app overrides for the heuristic file matcher.
///
/// Some apps use naming conventions that collide with other apps (e.g. "Xcode" vs "Xcodes"),
/// or scatter files under unexpected names. This struct lets the scanner include additional
/// search terms, exclude false positives, and force-include/exclude specific filesystem paths.
struct AppCondition: Codable {
    let bundleID: String
    let includeTerms: [String]
    let excludeTerms: [String]
    let forceIncludePaths: [URL]?
    let forceExcludePaths: [URL]?

    init(
        bundleID: String,
        includeTerms: [String],
        excludeTerms: [String],
        forceIncludePaths: [String]? = nil,
        forceExcludePaths: [String]? = nil
    ) {
        self.bundleID = bundleID.normalizedForMatching()
        self.includeTerms = includeTerms.map { $0.normalizedForMatching() }
        self.excludeTerms = excludeTerms.map { $0.normalizedForMatching() }
        self.forceIncludePaths = forceIncludePaths?.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        self.forceExcludePaths = forceExcludePaths?.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}

// MARK: - SkipCondition

/// Defines prefixes and paths that should be skipped during scanning.
///
/// `skipPrefixes` - Normalized filename prefixes that are always skipped (e.g. system plists).
/// `allowPrefixes` - Exceptions to skipPrefixes for Apple apps we DO want to scan.
/// `skipPaths` - Absolute paths that should never appear in scan results.
struct SkipCondition {
    let skipPrefixes: [String]
    let allowPrefixes: [String]
    let skipPaths: [String]
}

// MARK: - App Conditions Database

/// Per-app matching overrides.
/// Each entry handles a specific app whose files cannot be reliably found by bundle ID alone.
let appConditions: [AppCondition] = [

    // ---------------------------------------------------------------
    // Apple Developer Tools
    // ---------------------------------------------------------------

    // Xcode: includes simulator containers, DerivedData markers, and Apple DT prefixes.
    // Must exclude Xcodes.app (third-party Xcode version manager) and Xcode cleaner utilities.
    AppCondition(
        bundleID: "com.apple.dt.xcode",
        includeTerms: ["com.apple.dt", "xcode", "simulator"],
        excludeTerms: [
            "com.robotsandpencils.xcodesapp",
            "com.xcodesorg.xcodesapp",
            "com.oneminutegames.xcodecleaner",
            "io.hyperapp.xcodecleaner",
            "available-xcodes",
            "xcodes",
            "cleaner for xcode"
        ],
        forceIncludePaths: [
            "\(home)/Library/Containers/com.apple.iphonesimulator.ShareExtension"
        ]
    ),

    // Xcodes.app (robotsandpencils variant)
    AppCondition(
        bundleID: "com.robotsandpencils.xcodesapp",
        includeTerms: [],
        excludeTerms: [
            "com.apple.dt.xcode",
            "com.oneminutegames.xcodecleaner",
            "io.hyperapp.xcodecleaner"
        ]
    ),

    // Xcodes.app (xcodesorg variant)
    AppCondition(
        bundleID: "com.xcodesorg.xcodesapp",
        includeTerms: [],
        excludeTerms: [
            "com.apple.dt.xcode",
            "com.oneminutegames.xcodecleaner",
            "io.hyperapp.xcodecleaner"
        ]
    ),

    // Xcode Cleaner (hyperapp)
    AppCondition(
        bundleID: "io.hyperapp.xcodecleaner",
        includeTerms: [],
        excludeTerms: [
            "com.robotsandpencils.xcodesapp",
            "com.oneminutegames.xcodecleaner",
            "com.apple.dt.xcode",
            "xcodes.json"
        ]
    ),

    // ---------------------------------------------------------------
    // Communication & Video Conferencing
    // ---------------------------------------------------------------

    // Zoom: uses "us.zoom.xos" bundle but files are often named just "zoom".
    AppCondition(
        bundleID: "us.zoom.xos",
        includeTerms: ["zoom"],
        excludeTerms: []
    ),

    // Microsoft Teams: exclude general Office shared frameworks.
    AppCondition(
        bundleID: "com.microsoft.teams2",
        includeTerms: [],
        excludeTerms: ["office"]
    ),

    // ---------------------------------------------------------------
    // Web Browsers
    // ---------------------------------------------------------------

    // Brave Browser
    AppCondition(
        bundleID: "com.brave.browser",
        includeTerms: ["brave"],
        excludeTerms: []
    ),

    // Google Chrome: include "google" and "chrome" but exclude iTerm's chromefeaturestate
    // and unrelated "monochrome" matches.
    AppCondition(
        bundleID: "com.google.chrome",
        includeTerms: ["google", "chrome"],
        excludeTerms: ["iterm", "chromefeaturestate", "monochrome"]
    ),

    // Microsoft Edge: exclude other Microsoft products that share the "com.microsoft" prefix.
    AppCondition(
        bundleID: "com.microsoft.edgemac",
        includeTerms: [],
        excludeTerms: ["vscode", "rdc", "appcenter", "office", "oneauth"]
    ),

    // Mozilla Firefox (release)
    AppCondition(
        bundleID: "org.mozilla.firefox",
        includeTerms: ["firefox"],
        excludeTerms: ["thunderbird"]
    ),

    // Mozilla Firefox Nightly
    AppCondition(
        bundleID: "org.mozilla.firefox.nightly",
        includeTerms: ["mozilla", "firefox"],
        excludeTerms: ["thunderbird"]
    ),

    // Mozilla Thunderbird
    AppCondition(
        bundleID: "org.mozilla.thunderbird",
        includeTerms: [],
        excludeTerms: ["firefox"]
    ),

    // Arc Browser: uses Firestore for sync; force-include its App Support and Caches folders.
    AppCondition(
        bundleID: "company.thebrowser.Browser",
        includeTerms: ["firestore"],
        excludeTerms: [],
        forceIncludePaths: [
            "\(home)/Library/Application Support/Arc/",
            "\(home)/Library/Caches/Arc/"
        ]
    ),

    // ---------------------------------------------------------------
    // Developer Tools & IDEs
    // ---------------------------------------------------------------

    // VS Code: force-include the "Code" support directory.
    // Must exclude VS Code Insiders to prevent cross-contamination.
    AppCondition(
        bundleID: "com.microsoft.VSCode",
        includeTerms: ["vscode"],
        excludeTerms: ["vscodeinsiders", "insiders"],
        forceIncludePaths: [
            "\(home)/Library/Application Support/Code/"
        ]
    ),

    // VS Code Insiders: separate from stable VS Code.
    AppCondition(
        bundleID: "com.microsoft.VSCodeInsiders",
        includeTerms: ["vscodeinsiders", "insiders"],
        excludeTerms: [],
        forceIncludePaths: [
            "\(home)/Library/Application Support/Code - Insiders/"
        ]
    ),

    // GitHub Desktop: uses "comgithubelectron" in some legacy cache paths.
    AppCondition(
        bundleID: "com.github.githubclient",
        includeTerms: ["comgithubelectron"],
        excludeTerms: []
    ),

    // JetBrains IDEs (IntelliJ, PyCharm, WebStorm, etc.): share common directories.
    // The bundle ID prefix "jetbrains" matches all JetBrains products.
    AppCondition(
        bundleID: "jetbrains",
        includeTerms: ["jcef"],
        excludeTerms: [],
        forceIncludePaths: [
            "\(home)/Library/Application Support/JetBrains/",
            "\(home)/Library/Caches/JetBrains/",
            "\(home)/Library/Logs/JetBrains/"
        ]
    ),

    // Native Instruments (Native Access, Kontakt, etc.)
    AppCondition(
        bundleID: "com.native-instruments.nativeaccess",
        includeTerms: ["comnative", "nativeinstruments"],
        excludeTerms: []
    ),

    // ---------------------------------------------------------------
    // Productivity & Utilities
    // ---------------------------------------------------------------

    // Logi Options+: "logi" prefix collides with "login" and "logic".
    AppCondition(
        bundleID: "com.logi.optionsplus",
        includeTerms: ["logi", "logipluginservice"],
        excludeTerms: ["login", "logic"]
    ),

    // 1Password: uses shared Chromium-based browser engine paths.
    AppCondition(
        bundleID: "com.1password.1password",
        includeTerms: ["waveboxapp", "sidekick"],
        excludeTerms: []
    ),

    // Stats (system monitor): exclude "video" to avoid matching video-stats plists.
    AppCondition(
        bundleID: "eu.exelban.stats",
        includeTerms: [],
        excludeTerms: ["video"]
    ),

    // BatteryToolkit: plist prefix uses concatenated form "memhaeuser".
    AppCondition(
        bundleID: "me.mhaeuser.BatteryToolkit",
        includeTerms: ["memhaeuser"],
        excludeTerms: []
    ),

    // Okta Verify
    AppCondition(
        bundleID: "com.okta.mobile",
        includeTerms: ["okta"],
        excludeTerms: []
    ),

    // ---------------------------------------------------------------
    // Virtualization & Remote Access
    // ---------------------------------------------------------------

    // BlueStacks: uses interprocess communication files with non-obvious names.
    AppCondition(
        bundleID: "com.now.gg.BlueStacks",
        includeTerms: ["bst_boost_interprocess"],
        excludeTerms: []
    ),

    // StrongDM: Electron app with "sdm" bundle but files named "strongdm".
    AppCondition(
        bundleID: "com.electron.sdm",
        includeTerms: ["strongdm"],
        excludeTerms: []
    ),

    // ---------------------------------------------------------------
    // Social & Messaging
    // ---------------------------------------------------------------

    // Facebook Archon (Workplace): includes login helper with different naming.
    AppCondition(
        bundleID: "com.facebook.archon.developerid",
        includeTerms: ["archon.loginhelper"],
        excludeTerms: []
    ),
]

// MARK: - Skip Conditions

/// System-level skip rules applied globally during scanning.
/// Prevents the scanner from matching macOS system files, the Trash, and known false positives.
let skipConditions: [SkipCondition] = [
    SkipCondition(
        skipPrefixes: [
            "mobiledocuments",
            "reminders",
            "dsstore",
            "comapplepasswordmanager"
        ],
        allowPrefixes: [
            "comappleconfigurator",
            "comappledt",
            "comappleiwork",
            "comapplesfsymbols",
            "comappletestflight",
            "comapplesharedfilelist",
            "comapplelssharedfilelist"
        ],
        skipPaths: [
            "\(home)/.Trash",
            "/Library/SystemExtensions",
            "/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
            "\(home)/Library/Application Support/Chromium/NativeMessagingHosts/com.apple.passwordmanager.json",
            "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json"
        ]
    )
]

// MARK: - Deep Search Exclusions

/// Library subdirectories excluded from depth=2 (deep) search.
/// These are macOS system directories that never contain third-party app files.
/// Searching them wastes time and produces false positives.
let skipDeepSearch: Set<String> = [

    // Core System
    "Apple", "Audio", "Bluetooth", "ColorSync", "Components", "CoreAnalytics",
    "CoreMediaIO", "DirectoryServices", "Filesystems", "GPUBundles", "Graphics",
    "KernelCollections", "OSAnalytics", "OpenDirectory", "Sandbox", "Security",
    "SystemExtensions", "SystemMigration", "SystemProfiler", "StagedDriverExtensions",
    "StagedExtensions", "StartupItems",

    // User Data & System Services
    "Accessibility", "Accounts", "AppleMediaServices", "Assistant", "Assistants",
    "Autosave Information", "Biome", "Calendars", "CallServices", "CloudStorage",
    "Contacts", "Cookies", "DataAccess", "DataDeliveryServices", "DoNotDisturb",
    "DuetExpertCenter", "Finance", "FinanceBackup", "FrontBoard", "GameKit",
    "GroupContainersAlias", "HomeKit", "IdentityServices", "IntelligencePlatform",
    "Intents", "KeyboardServices", "LanguageModeling", "LockdownMode", "Mail",
    "MediaAnalysis", "Messages", "Metadata", "Mobile Documents", "MobileDevice",
    "News", "Passes", "PersonalizationPortrait", "Photos", "PrivateCloudCompute",
    "Reminders", "ResponseKit", "Safari", "SafariSafeBrowsing", "SafariSandboxBroker",
    "ScreenRecordings", "StatusKit", "Suggestions", "SyncedPreferences", "Translation",
    "UnifiedAssetFramework", "Weather", "homeenergyd", "studentd",

    // Development & System Tools
    "Developer", "Perl", "Ruby", "Java", "Python", "Catacomb", "InstallerSandboxes",
    "Trial", "Updates", "Staging", "ContainerManager", "Daemon Containers",

    // Additional System Directories
    "ColorPickers", "Colors", "Compositions", "Contextual Menu Items", "Documentation",
    "DriverExtensions", "Favorites", "FontCollections", "Fonts", "Image Capture",
    "Input Methods", "Jupyter", "Keyboard", "Keyboard Layouts", "Keychains",
    "Managed Preferences", "PDF Services", "Printers", "QuickLook", "Receipts",
    "Screen Savers", "ScriptingAdditions", "Scripts", "Sharing", "Shortcuts",
    "Sounds", "Speech", "Spelling", "Spotlight", "User Pictures", "User Template",
    "Video", "WebServer", "Workflows",

    // Apple Service Bundles (com.apple.*)
    "com.apple.AppleMediaServices", "com.apple.WatchListKit", "com.apple.aiml.instrumentation",
    "com.apple.appleaccountd", "com.apple.bluetooth.services.cloud", "com.apple.bluetoothuser",
    "com.apple.familycircled", "com.apple.iTunesCloud", "com.apple.internal.ck",

    // iCloud & Sync Infrastructure
    "com.apple.cloudpaird", "com.apple.iCloudHelper", "com.apple.nsurlsessiond",
    "com.apple.sbd", "com.apple.touristd",

    // System Agents & Daemons
    "com.apple.AMPLibraryAgent", "com.apple.bird", "com.apple.coreduetd",
    "com.apple.homed", "com.apple.photoanalysisd", "com.apple.routined",
    "com.apple.siriactionsd", "com.apple.suggestd",

    // Frameworks & Runtime (never user-facing)
    "com.apple.AppStoreComponents", "com.apple.ScreenTimeUI",
    "com.apple.TelephonyUtilities", "com.apple.WebInspector"
]

// MARK: - Reverse Search Exclusions

/// Normalized prefixes of files and folders to skip during orphan (reverse) search.
/// These are macOS system items, Apple daemons, and infrastructure that should never
/// be flagged as orphaned third-party app files.
let skipReverse: [String] = [
    // Apple & System
    "apple", "temporary", "btserver", "proapps", "scripteditor", "ilife",
    "livefsd", "siritoday", "addressbook", "animoji", "appstore",
    "askpermission", "callhistory", "clouddocs", "diskimages", "dock",
    "facetime", "fileprovider", "instruments", "knowledge", "mobilesync",
    "syncservices", "homeenergyd", "icloud", "icdd", "networkserviceproxy",
    "familycircle", "geoservices", "installation", "passkit",
    "sharedimagecache", "desktop", "mbuseragent", "swiftpm", "baseband",
    "coresimulator", "photoslegacyupgrade", "photosupgrade", "siritts",
    "ipod", "globalpreferences",

    // Analytics & Telemetry
    "apmanalytics", "apmexperiment", "avatarcache", "byhost",
    "contextstoreagent", "mobilemeaccounts", "mobiledocuments", "mobile",
    "intentbuilderc", "loginwindow", "momc", "replayd", "sharedfilelistd",

    // Build Tools & Compilers
    "clang", "audiocomponent", "csexattrcryptoservice",
    "livetranscriptionagent", "sandboxhelper", "statuskitagent",

    // System Daemons
    "betaenrollmentd", "contentlinkingd", "diagnosticextensionsd", "gamed",
    "heard", "homed", "itunescloudd", "lldb", "mds", "mediaanalysisd",
    "metrickitd", "mobiletimerd", "proactived", "ptpcamerad", "studentd",
    "talagent", "watchlistd", "apptranslocation", "xcrun",

    // Generic Infrastructure
    "ds_store", "caches", "crashreporter", "trash",

    // PureMac itself (never flag our own files)
    "puremac",

    // Common SDKs and Shared Components
    "amsdatamigratortool", "arfilecache", "assistant", "chromium",
    "cloudkit", "webkit", "databases", "diagnostic", "cache", "gamekit",
    "homebrew", "logi", "microsoft", "mozilla", "sync", "google",
    "sentinel", "hexnode", "sentry", "tvappservices", "reminders", "pbs",
    "notarytool", "differentialprivacy", "storeassetd", "webpush",
    "storedownloadd", "fsck", "crash", "python", "discrecording",
    "photossearch", "pylint", "jamf", "scopedbookmarkagent", "anonymous",
    "identifier", "isolated", "nobackup", "privacypreservingmeasurement",
    "symbols", "stickersd", "privatecloudcomputed", "tipsd",
    "controlcenter", "contactsd", "staticcheck", "index", "segment",
    "sparkle", "summaryevents", "launchdarkly", "identityservicesd",
    "embeddedbinaryvalidationutility", "aaprofilepicture", "minilauncher",
    "jna", "automator", "locationaccessstored", "spotlight", "cef"
]
