import XCTest
@testable import PureMac

final class UpdateServiceTests: XCTestCase {
    func testVersionComparisonIsNumericAndStableBeatsPrerelease() throws {
        XCTAssertTrue(try XCTUnwrap(AppReleaseVersion("v3.10.0")) > XCTUnwrap(AppReleaseVersion("3.9.9")))
        XCTAssertEqual(AppReleaseVersion("3.0"), AppReleaseVersion("3.0.0"))
        XCTAssertTrue(try XCTUnwrap(AppReleaseVersion("3.0.0")) > XCTUnwrap(AppReleaseVersion("3.0.0-beta.1")))
        for invalid in ["cli-v9.0.0", "latest", "3..0", "-1.2.3", "3.2x", ""] {
            XCTAssertNil(AppReleaseVersion(invalid), invalid)
        }
    }

    func testSelectsNewestStableAppReleaseAndRejectsCLIAndUntrustedLinks() throws {
        let data = Data("""
        [
          {"tag_name":"cli-v99.0.0","html_url":"https://github.com/momenbasel/PureMac/releases/tag/cli-v99.0.0","draft":false,"prerelease":false,"assets":[{"name":"puremac-cli.zip"}]},
          {"tag_name":"v4.0.0","html_url":"https://github.com/momenbasel/PureMac/releases/tag/v4.0.0","draft":false,"prerelease":true,"assets":[{"name":"PureMac-4.0.0.zip"}]},
          {"tag_name":"v3.10.0","html_url":"https://github.com/momenbasel/PureMac/releases/tag/v3.10.0","draft":false,"prerelease":false,"assets":[{"name":"PureMac-3.10.0.zip"}]},
          {"tag_name":"v3.9.0","html_url":"https://github.com/momenbasel/PureMac/releases/tag/v3.9.0","draft":false,"prerelease":false,"assets":[{"name":"PureMac-3.9.0.dmg"}]},
          {"tag_name":"v99.0.0","html_url":"https://example.com/malware","draft":false,"prerelease":false,"assets":[{"name":"PureMac-99.0.0.zip"}]}
        ]
        """.utf8)
        XCTAssertEqual(try UpdateService.latestAppRelease(in: data).tagName, "v3.10.0")
        XCTAssertThrowsError(try UpdateService.latestAppRelease(in: Data("[]".utf8)))
        XCTAssertThrowsError(try UpdateService.latestAppRelease(in: Data("invalid".utf8)))
    }

    @MainActor
    func testNetworkFailureNeverReportsUpToDateAndCanRetry() async {
        let service = UpdateService(currentVersion: "3.0.0") { _ in
            throw URLError(.notConnectedToInternet)
        }
        await service.check()
        guard case .failed = service.state else { return XCTFail("Expected failure") }
        XCTAssertFalse(service.isChecking)
        await service.check()
        guard case .failed = service.state else { return XCTFail("Expected retry to finish") }
    }

    @MainActor
    func testHTTPErrorAndAvailableAndCurrentVersions() async {
        for (installed, expectedAvailable) in [("2.9.0", true), ("3.0.0", false), ("3.1.0", false)] {
            let service = UpdateService(currentVersion: installed) { request in
                XCTAssertEqual(request.url?.host, "api.github.com")
                let data = Data("""
                [{"tag_name":"v3.0.0","html_url":"https://github.com/momenbasel/PureMac/releases/tag/v3.0.0","draft":false,"prerelease":false,"assets":[{"name":"PureMac-3.0.0.zip"}]}]
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            await service.check()
            if expectedAvailable {
                guard case .available = service.state else { return XCTFail("Expected available") }
            } else {
                guard case .upToDate = service.state else { return XCTFail("Expected current") }
            }
            XCTAssertNotNil(service.lastChecked)
        }
        let limited = UpdateService(currentVersion: "3.0.0") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        await limited.check()
        guard case .failed = limited.state else { return XCTFail("Expected rate limit failure") }
    }
}
