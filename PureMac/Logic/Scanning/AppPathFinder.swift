//
//  AppPathFinder.swift
//  PureMac
//
//  Heuristic file discovery engine that locates all filesystem artifacts
//  belonging to a given macOS application. Uses multi-level matching
//  against bundle identifiers, app names, entitlements, and team IDs
//  with configurable sensitivity.
//

import Foundation
import AppKit

class AppPathFinder {

    // MARK: - Types

    struct AppInfo {
        let appName: String
        let bundleIdentifier: String
        let path: URL
        let entitlements: [String]?
        let teamIdentifier: String?
    }

    enum Sensitivity {
        case strict    // Exact bundle ID + exact name match only
        case enhanced  // + partial matching, bundle components, stripped version
        case deep      // + company name, entitlements, team ID
    }

    // MARK: - Properties

    private let appInfo: AppInfo
    private let locations: Locations
    private let sensitivity: Sensitivity
    private var collectionSet: Set<URL> = []
    private let collectionQueue = DispatchQueue(label: "com.puremac.pathfinder.collection")

    // Pre-computed cached identifiers (computed once in init, used in hot loop)
    private let normalizedBundleID: String
    private let bundleLastTwo: String
    private let normalizedAppName: String
    private let appNameLettersOnly: String
    private let pathComponentName: String
    private let companyName: String?
    private let baseBundleID: String?
    private let strippedAppName: String?
    private let normalizedEntitlements: [String]
    private let normalizedTeamID: String?

    // MARK: - Initialization

    init(appInfo: AppInfo, locations: Locations, sensitivity: Sensitivity = .enhanced) {
        self.appInfo = appInfo
        self.locations = locations
        self.sensitivity = sensitivity

        self.normalizedBundleID = appInfo.bundleIdentifier.normalizedForMatching()
        self.bundleLastTwo = appInfo.bundleIdentifier.bundleLastTwoComponents
        self.normalizedAppName = appInfo.appName.normalizedForMatching()
        self.appNameLettersOnly = appInfo.appName.lettersOnly
        self.pathComponentName = appInfo.path.lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
            .normalizedForMatching()
        self.companyName = appInfo.bundleIdentifier.bundleCompanyName
        self.baseBundleID = appInfo.bundleIdentifier.baseBundleIdentifier?.normalizedForMatching()

        let stripped = appInfo.appName.strippingTrailingVersion().normalizedForMatching()
        self.strippedAppName = (stripped != normalizedAppName && !stripped.isEmpty) ? stripped : nil

        self.normalizedEntitlements = appInfo.entitlements?.compactMap { e in
            let n = e.normalizedForMatching()
            return n.isEmpty ? nil : n
        } ?? []

        self.normalizedTeamID = appInfo.teamIdentifier?.normalizedForMatching()
    }

    // MARK: - Public API

    /// Find all files related to this app synchronously.
    func findPaths() -> Set<URL> {
        collectionSet.insert(appInfo.path)

        for location in locations.appSearch.paths {
            let isLibRoot = isLibraryDirectory(location)
            let maxDepth = isLibRoot ? 2 : 1
            processLocation(location, currentDepth: 0, maxDepth: maxDepth, isLibraryRootSearch: isLibRoot)
        }

        let containers = discoverContainers()
        collectionSet.formUnion(containers)

        applyConditions()

        return filterSubpaths(collectionSet)
    }

    /// Find all files related to this app with parallel location processing.
    func findPathsAsync(completion: @escaping (Set<URL>) -> Void) {
        collectionSet.insert(appInfo.path)

        let group = DispatchGroup()
        for location in locations.appSearch.paths {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let isLibRoot = self.isLibraryDirectory(location)
                let maxDepth = isLibRoot ? 2 : 1
                self.processLocation(location, currentDepth: 0, maxDepth: maxDepth, isLibraryRootSearch: isLibRoot)
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let containers = self.discoverContainers()
            self.collectionQueue.sync {
                self.collectionSet.formUnion(containers)
            }
            self.applyConditions()
            let result = self.filterSubpaths(self.collectionSet)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - Location Processing

    private func processLocation(_ location: String, currentDepth: Int, maxDepth: Int, isLibraryRootSearch: Bool) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: location) else {
            return
        }

        var localResults: [URL] = []
        var subdirs: [URL] = []

        for item in contents {
            let itemURL = URL(fileURLWithPath: location).appendingPathComponent(item)
            let normalizedName: String

            if itemURL.hasDirectoryPath || itemURL.pathExtension.isEmpty {
                normalizedName = item.normalizedForMatching()
            } else {
                normalizedName = (item as NSString).deletingPathExtension.normalizedForMatching()
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }

            if shouldSkipItem(normalizedName, at: itemURL) { continue }

            if matchesApp(normalizedName: normalizedName, itemURL: itemURL) {
                let itemToAdd: URL

                // For depth-2 matches in Library root, add the parent directory when
                // it is a vendor folder (not a standard Library subdirectory).
                if isLibraryRootSearch && currentDepth == 2 {
                    let parent = itemURL.deletingLastPathComponent()
                    let parentName = parent.lastPathComponent
                    if !Locations.standardLibrarySubdirectories.contains(parentName) {
                        itemToAdd = parent
                    } else {
                        itemToAdd = itemURL
                    }
                } else {
                    itemToAdd = itemURL
                }

                localResults.append(itemToAdd)
            }

            // Recurse into subdirectories up to maxDepth
            if isDir.boolValue && currentDepth < maxDepth {
                if isLibraryRootSearch && currentDepth == 0 {
                    if !skipDeepSearch.contains(itemURL.lastPathComponent) {
                        subdirs.append(itemURL)
                    }
                } else {
                    subdirs.append(itemURL)
                }
            }
        }

        collectionQueue.sync {
            collectionSet.formUnion(localResults)
        }

        for subdir in subdirs {
            processLocation(subdir.path, currentDepth: currentDepth + 1, maxDepth: maxDepth, isLibraryRootSearch: isLibraryRootSearch)
        }
    }

    // MARK: - Matching Engine

    /// Multi-level heuristic matcher. Returns true if the normalized filename
    /// belongs to the target app at the current sensitivity level.
    private func matchesApp(normalizedName: String, itemURL: URL) -> Bool {
        // Per-app condition overrides take priority
        for condition in appConditions {
            if normalizedBundleID.contains(condition.bundleID) {
                if condition.excludeTerms.contains(where: { normalizedName.contains($0) }) {
                    return false
                }
                if condition.includeTerms.contains(where: { normalizedName.contains($0) }) {
                    return true
                }
            }
        }

        // Entitlement-based matching
        for entitlement in normalizedEntitlements {
            let match = sensitivity == .strict
                ? normalizedName == entitlement
                : normalizedName.contains(entitlement)
            if match { return true }
        }

        // Level 1: Full bundle identifier
        let fullBundleMatch = normalizedName.contains(normalizedBundleID)

        // Level 2: App name
        let isStrict = sensitivity == .strict
        let appNameMatch = !normalizedAppName.isEmpty && (isStrict
            ? normalizedName == normalizedAppName
            : normalizedName.contains(normalizedAppName))

        // Level 3: Path component name (the .app directory name without extension)
        let pathMatch = !pathComponentName.isEmpty && (isStrict
            ? normalizedName == pathComponentName
            : normalizedName.contains(pathComponentName))

        // Level 4: Letters-only app name
        let lettersMatch = !appNameLettersOnly.isEmpty && (isStrict
            ? normalizedName == appNameLettersOnly
            : normalizedName.contains(appNameLettersOnly))

        if (normalizedBundleID.count >= 5 && fullBundleMatch) || appNameMatch || pathMatch || lettersMatch {
            return true
        }

        // Enhanced mode: additional partial matching strategies
        if sensitivity != .strict {
            // Level 5: Last two bundle ID components
            if normalizedName.contains(bundleLastTwo) { return true }

            // Level 6: Base bundle ID (strips .helper/.agent/.daemon suffixes)
            if let base = baseBundleID, !base.isEmpty, normalizedName.contains(base) { return true }

            // Level 7: Version-stripped app name
            if let stripped = strippedAppName, normalizedName.contains(stripped) { return true }
        }

        // Deep mode: broadest matching heuristics
        if sensitivity == .deep {
            // Level 8: Company name extracted from bundle ID
            if let company = companyName, !company.isEmpty, normalizedName.contains(company) { return true }

            // Level 9: Team identifier from code signature
            if let teamID = normalizedTeamID, !teamID.isEmpty, normalizedName.contains(teamID) { return true }
        }

        return false
    }

    // MARK: - Skip Logic

    private func shouldSkipItem(_ normalizedName: String, at url: URL) -> Bool {
        if collectionSet.contains(url) { return true }

        for skip in skipConditions {
            for path in skip.skipPaths {
                if url.path.hasPrefix(path) { return true }
            }
            if skip.skipPrefixes.contains(where: { normalizedName.hasPrefix($0) }) {
                if !skip.allowPrefixes.contains(where: { normalizedName.hasPrefix($0) }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Container Discovery

    /// Discovers sandboxed app containers that belong to this app by checking
    /// both UUID-named containers (via metadata plist) and name-matched containers.
    private func discoverContainers() -> [URL] {
        var containers: [URL] = []

        guard let containersPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Containers") else { return containers }

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: containersPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return containers }

        for dir in dirs {
            let dirName = dir.lastPathComponent

            // UUID-named containers: read the metadata plist for the owning bundle ID
            if dirName.count == 36 && dirName.contains("-") {
                let metaPlist = dir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                if let meta = NSDictionary(contentsOf: metaPlist),
                   let bundleID = meta["MCMMetadataIdentifier"] as? String,
                   bundleID == appInfo.bundleIdentifier {
                    containers.append(dir)
                }
            }

            // Named containers matching the bundle ID directly
            if dirName.normalizedForMatching() == normalizedBundleID {
                containers.append(dir)
            }
        }

        return containers
    }

    // MARK: - Condition Application

    /// Applies per-app force-include and force-exclude path overrides after
    /// the main scan has completed.
    private func applyConditions() {
        for condition in appConditions {
            if normalizedBundleID.contains(condition.bundleID) {
                if let paths = condition.forceIncludePaths {
                    for path in paths {
                        if FileManager.default.fileExists(atPath: path.path) {
                            collectionSet.insert(path)
                        }
                    }
                }
                if let paths = condition.forceExcludePaths {
                    for path in paths {
                        collectionSet.remove(path)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func isLibraryDirectory(_ location: String) -> Bool {
        location == "\(home)/Library" || location == "/Library"
    }

    /// Removes child paths when a parent is already in the set, and discards
    /// results that consist solely of a Trash item.
    private func filterSubpaths(_ urls: Set<URL>) -> Set<URL> {
        let sorted = urls.map { $0.standardizedFileURL }.sorted { $0.path < $1.path }
        var filtered: [URL] = []

        for url in sorted {
            // Remove any existing entries that are children of this URL
            filtered.removeAll { $0.path.hasPrefix(url.path + "/") }

            // Only add if this URL is not a child of an existing entry
            if !filtered.contains(where: { url.path.hasPrefix($0.path + "/") }) {
                filtered.append(url)
            }
        }

        // A single result pointing into the Trash is not meaningful
        if filtered.count == 1, let first = filtered.first, first.path.contains(".Trash") {
            return []
        }

        return Set(filtered)
    }
}
