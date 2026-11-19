import XCTest
@testable import PureMac

final class AppleFeatureCatalogTests: XCTestCase {
    private func version(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    func testAvailabilityUsesMinorVersionForAppleIntelligence() throws {
        let features = AppleFeatureCatalog.features(for: version(15))
        let intelligence = try XCTUnwrap(features.first { $0.id == "intelligence" })
        let images = try XCTUnwrap(features.first { $0.id == "images" })
        XCTAssertFalse(intelligence.isAvailable(on: version(15)))
        XCTAssertTrue(intelligence.isAvailable(on: version(15, 1)))
        XCTAssertFalse(images.isAvailable(on: version(15, 1)))
        XCTAssertTrue(images.isAvailable(on: version(15, 2)))
        XCTAssertTrue(features.first { $0.id == "siri" }!.isAvailable(on: version(13)))
    }

    func testCurrentMacOSUsesSeparateControlsAndCurrentRestrictionNames() throws {
        let features = AppleFeatureCatalog.features(for: version(27))
        let intelligence = try XCTUnwrap(features.first { $0.id == "intelligence" })
        XCTAssertTrue(intelligence.steps.contains("separate"))
        XCTAssertFalse(intelligence.steps.contains("turn off Apple Intelligence"))
        XCTAssertTrue(features.first { $0.id == "extensions" }!.steps.contains("Set Extensions to Blocked"))
        XCTAssertTrue(features.first { $0.id == "images" }!.steps.contains("Enable All Restrictions"))
        XCTAssertTrue(features.first { $0.id == "images" }!.steps.contains("Blocked"))
    }

    func testCatalogHasUniqueIDsAndOnlyOfficialSupportLinks() {
        for major in [13, 14, 15, 26, 27] {
            let features = AppleFeatureCatalog.features(for: version(major))
            XCTAssertEqual(Set(features.map(\.id)).count, features.count)
            XCTAssertTrue(features.allSatisfy { $0.guide.scheme == "https" && $0.guide.host == "support.apple.com" })
            XCTAssertTrue(features.allSatisfy { !$0.steps.isEmpty })
        }
    }
}
