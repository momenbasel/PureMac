import XCTest
@testable import PureMac

final class SimulatorRuntimeSupportTests: XCTestCase {

    // MARK: - JSON list parsing

    func testParseRuntimeListJSONExtractsFieldsAndSortsBySizeDescending() throws {
        let json = """
        {
          "small-id": {
            "identifier": "11111111-1111-1111-1111-111111111111",
            "version": "18.5",
            "build": "22F77",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "sizeBytes": 1000,
            "deletable": true,
            "lastUsedAt": "2026-08-05T18:46:32Z"
          },
          "large-id": {
            "identifier": "22222222-2222-2222-2222-222222222222",
            "version": "26.5",
            "build": "23F77",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "sizeBytes": 9000,
            "deletable": false
          }
        }
        """

        let runtimes = try XCTUnwrap(SimulatorRuntimeSupport.parseRuntimeListJSON(json))
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(runtimes[0].identifier, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(runtimes[0].displayName, "iOS 26.5 (23F77)")
        XCTAssertEqual(runtimes[0].sizeBytes, 9000)
        XCTAssertFalse(runtimes[0].deletable)
        XCTAssertNil(runtimes[0].lastUsedAt)

        XCTAssertEqual(runtimes[1].identifier, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(runtimes[1].displayName, "iOS 18.5 (22F77)")
        XCTAssertEqual(runtimes[1].sizeBytes, 1000)
        XCTAssertTrue(runtimes[1].deletable)
        XCTAssertNotNil(runtimes[1].lastUsedAt)
    }

    func testParseRuntimeListJSONReturnsNilForEmptyOrInvalidPayload() {
        XCTAssertNil(SimulatorRuntimeSupport.parseRuntimeListJSON(""))
        XCTAssertNil(SimulatorRuntimeSupport.parseRuntimeListJSON("   "))
        XCTAssertNil(SimulatorRuntimeSupport.parseRuntimeListJSON("not-json"))
        XCTAssertNil(SimulatorRuntimeSupport.parseRuntimeListJSON("[]"))
        XCTAssertNil(SimulatorRuntimeSupport.parseRuntimeListJSON("\"string\""))
    }

    func testParseRuntimeListJSONFallsBackToDictionaryKeyAsIdentifier() throws {
        let json = """
        {
          "ABCDEF01-2345-6789-ABCD-EF0123456789": {
            "version": "2.0",
            "build": "22N318",
            "platformIdentifier": "com.apple.platform.xrsimulator",
            "sizeBytes": 50
          }
        }
        """
        let runtimes = try XCTUnwrap(SimulatorRuntimeSupport.parseRuntimeListJSON(json))
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes[0].identifier, "ABCDEF01-2345-6789-ABCD-EF0123456789")
        XCTAssertEqual(runtimes[0].displayName, "visionOS 2.0 (22N318)")
        XCTAssertTrue(runtimes[0].deletable) // default when key absent
    }

    func testPlatformNameMapping() {
        XCTAssertEqual(
            SimulatorRuntimeSupport.platformName(from: "com.apple.platform.iphonesimulator"),
            "iOS"
        )
        XCTAssertEqual(
            SimulatorRuntimeSupport.platformName(from: "com.apple.platform.watchsimulator"),
            "watchOS"
        )
        XCTAssertEqual(
            SimulatorRuntimeSupport.platformName(from: "com.apple.platform.appletvsimulator"),
            "tvOS"
        )
        XCTAssertEqual(
            SimulatorRuntimeSupport.platformName(from: "com.apple.platform.xrsimulator"),
            "visionOS"
        )
        XCTAssertNil(SimulatorRuntimeSupport.platformName(from: nil))
        XCTAssertNil(SimulatorRuntimeSupport.platformName(from: "com.apple.platform.unknown"))
    }

    // MARK: - Selection policy (Smart Scan)

    func testMakeCleanableItemsNeverAutoSelectsRuntimeDownloads() {
        let runtimes = [
            SimulatorRuntimeSupport.RuntimeInfo(
                identifier: "deletable",
                displayName: "iOS 17.0 (21A)",
                sizeBytes: 100,
                deletable: true,
                lastUsedAt: nil
            ),
            SimulatorRuntimeSupport.RuntimeInfo(
                identifier: "locked",
                displayName: "iOS 16.0 (20A)",
                sizeBytes: 200,
                deletable: false,
                lastUsedAt: nil
            ),
            SimulatorRuntimeSupport.RuntimeInfo(
                identifier: "zero",
                displayName: "iOS 0",
                sizeBytes: 0,
                deletable: true,
                lastUsedAt: nil
            )
        ]

        let items = SimulatorRuntimeSupport.makeCleanableItems(from: runtimes)

        XCTAssertEqual(items.count, 2) // zero-size dropped

        let byID = Dictionary(uniqueKeysWithValues: items.map {
            ($0.simctlRuntimeIdentifier ?? "", $0)
        })

        XCTAssertEqual(byID["deletable"]?.name, "iOS 17.0 (21A)")
        XCTAssertEqual(byID["deletable"]?.isSelected, false)
        XCTAssertEqual(byID["deletable"]?.category, .xcodeJunk)
        XCTAssertTrue(byID["deletable"]?.isActionItem == true)
        XCTAssertEqual(byID["locked"]?.isSelected, false)
        XCTAssertNil(byID["zero"])
    }

    // MARK: - CleanableItem path helpers

    func testSimctlRuntimePathHelpers() {
        let item = CleanableItem(
            name: "iOS 18.5",
            path: CleanableItem.simctlRuntimePathPrefix + "F666EEDE-1029-48D9-BCAB-CF0E12B1D632",
            size: 1,
            category: .xcodeJunk,
            isSelected: false,
            lastModified: nil
        )
        XCTAssertTrue(item.isActionItem)
        XCTAssertEqual(item.simctlRuntimeIdentifier, "F666EEDE-1029-48D9-BCAB-CF0E12B1D632")

        let fileItem = CleanableItem(
            name: "DerivedData",
            path: "/Users/test/Library/Developer/Xcode/DerivedData",
            size: 1,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: nil
        )
        XCTAssertFalse(fileItem.isActionItem)
        XCTAssertNil(fileItem.simctlRuntimeIdentifier)

        let dockerPrune = CleanableItem(
            name: "Docker prune",
            path: "",
            size: 1,
            category: .dockerCache,
            isSelected: false,
            lastModified: nil
        )
        XCTAssertTrue(dockerPrune.isActionItem)
        XCTAssertNil(dockerPrune.simctlRuntimeIdentifier)
    }

    // MARK: - Missing developer tools

    func testIsXcrunAvailableUsesXcodeSelectStatus() {
        XCTAssertFalse(SimulatorRuntimeSupport.isXcrunAvailable { path, arguments in
            XCTAssertEqual(path, SimulatorRuntimeSupport.xcodeSelectPath)
            XCTAssertEqual(arguments, ["-p"])
            return 2
        })
        XCTAssertTrue(SimulatorRuntimeSupport.isXcrunAvailable { _, _ in 0 })
    }

    func testRunXcrunReturnsFriendlyErrorWhenDeveloperToolsMissing() {
        let result = SimulatorRuntimeSupport.runXcrun(
            ["simctl", "runtime", "list", "-j"],
            availabilityCheck: { false }
        )
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, SimulatorRuntimeSupport.missingXcrunMessage)
    }

    func testDeleteSimulatorRuntimeReportsMissingXcrun() async {
        let result = SimulatorRuntimeSupport.runXcrun(
            ["simctl", "runtime", "delete", "deadbeef"],
            availabilityCheck: { false }
        )
        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.stderr, SimulatorRuntimeSupport.missingXcrunMessage)
    }
}
