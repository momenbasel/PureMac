import Foundation

/// Numeric release versions. Only app tags (vMAJOR.MINOR[.PATCH]) are accepted;
/// the repository also publishes cli-v... releases which must never win.
struct AppReleaseVersion: Comparable {
    let components: [Int]
    let prerelease: String?

    init?(_ string: String) {
        var value = string
        if value.hasPrefix("v") { value.removeFirst() }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count),
              numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let parsed = numbers.compactMap { Int($0) }
        guard parsed.count == numbers.count else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }) else { return nil }
        }
        components = parsed + Array(repeating: 0, count: 3 - parsed.count)
        prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components {
            return lhs.components.lexicographicallyPrecedes(rhs.components)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }
}

struct AppRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable { let name: String }
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease, assets
    }

    var version: AppReleaseVersion? { AppReleaseVersion(tagName) }

    var isStableAppRelease: Bool {
        guard !draft, !prerelease, let version, version.prerelease == nil,
              htmlURL.scheme == "https", htmlURL.host == "github.com",
              htmlURL.user == nil, htmlURL.password == nil, htmlURL.port == nil,
              htmlURL.path.hasPrefix("/momenbasel/PureMac/releases/tag/") else { return false }
        return assets.contains {
            let name = $0.name.lowercased()
            return (name.hasPrefix("puremac-") || name == "puremac.zip" || name == "puremac.dmg")
                && !name.contains("cli") && (name.hasSuffix(".zip") || name.hasSuffix(".dmg"))
        }
    }
}

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    nonisolated static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    nonisolated static let installedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    nonisolated static let releasesURL = URL(string: "https://github.com/momenbasel/PureMac/releases")!

    enum State: Equatable {
        case idle, checking
        case available(AppRelease)
        case upToDate
        case failed(String)
    }

    enum CheckError: LocalizedError {
        case invalidVersion, noRelease, rateLimited, serverError
        var errorDescription: String? {
            switch self {
            case .invalidVersion: return String(localized: "This build has no readable version. Open the releases page to check manually.")
            case .noRelease: return String(localized: "No stable PureMac app release was found. Try again later.")
            case .rateLimited: return String(localized: "GitHub is receiving too many requests. Please try again later.")
            case .serverError: return String(localized: "The release service is unavailable. Please try again later.")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    var isChecking: Bool { state == .checking }
    private let currentVersion: String
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    init(currentVersion: String = UpdateService.installedVersion,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    func checkForUpdates() {
        Task { await check() }
    }

    func check() async {
        guard !isChecking else { return }
        state = .checking
        do {
            guard let installed = AppReleaseVersion(currentVersion) else { throw CheckError.invalidVersion }
            // Fetch a page rather than /latest: the latest release may be CLI.
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/momenbasel/PureMac/releases?per_page=100")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("PureMac-Update-Check", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw CheckError.serverError }
            if http.statusCode == 403 || http.statusCode == 429 { throw CheckError.rateLimited }
            guard http.statusCode == 200 else { throw CheckError.serverError }
            let release = try Self.latestAppRelease(in: data)
            guard let latest = release.version else { throw CheckError.noRelease }
            state = latest > installed ? .available(release) : .upToDate
            lastChecked = Date()
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated static func latestAppRelease(in data: Data) throws -> AppRelease {
        let releases = try JSONDecoder().decode([AppRelease].self, from: data)
        guard let latest = releases.filter(\.isStableAppRelease).max(by: {
            // isStableAppRelease validated both versions.
            $0.version! < $1.version!
        }) else { throw CheckError.noRelease }
        return latest
    }
}
