import XCTest
@testable import PureMac

final class PerformanceInspectorTests: XCTestCase {
    func testParseLaunchItemUsesProgramArgumentsAndActualFlags() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.example.sync</string>
            <key>ProgramArguments</key>
            <array>
                <string>/Applications/Example.app/Contents/MacOS/helper</string>
                <string>--background</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>StartInterval</key><integer>300</integer>
            <key>Disabled</key><true/>
        </dict>
        </plist>
        """
        let url = URL(fileURLWithPath: "/Users/example/Library/LaunchAgents/com.example.sync.plist")

        let item = try PerformanceInspector.parseLaunchItem(
            data: Data(plist.utf8),
            sourceURL: url,
            domain: .userAgent
        )

        XCTAssertEqual(item.label, "com.example.sync")
        XCTAssertEqual(item.program, "/Applications/Example.app/Contents/MacOS/helper")
        XCTAssertEqual(item.arguments, ["--background"])
        XCTAssertEqual(item.domain, .userAgent)
        XCTAssertTrue(item.isDisabled)
        XCTAssertEqual(item.triggers, [String(localized: "At login"), String(localized: "Conditional keep alive"), String(format: String(localized: "Every %lld seconds"), Int64(300))])
        XCTAssertEqual(item.sourceURL, url)
    }

    func testParseLaunchItemPrefersDeclaredProgramAndFallsBackToFilenameLabel() throws {
        let value: [String: Any] = [
            "Program": "/usr/local/bin/example-helper",
            "ProgramArguments": ["--mode", "quiet"],
            "WatchPaths": ["/Users/example/Library/Application Support/Example"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
        let url = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist")

        let item = try PerformanceInspector.parseLaunchItem(
            data: data,
            sourceURL: url,
            domain: .systemDaemon
        )

        XCTAssertEqual(item.label, "com.example.helper")
        XCTAssertEqual(item.program, "/usr/local/bin/example-helper")
        XCTAssertEqual(item.arguments, ["--mode", "quiet"])
        XCTAssertEqual(item.triggers, [String(localized: "Watches paths")])
        XCTAssertFalse(item.isDisabled)
    }

    func testParseLaunchItemRejectsNonDictionaryPropertyList() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["one", "two"],
            format: .xml,
            options: 0
        )

        XCTAssertThrowsError(
            try PerformanceInspector.parseLaunchItem(
                data: data,
                sourceURL: URL(fileURLWithPath: "/tmp/example.plist"),
                domain: .userAgent
            )
        ) { error in
            XCTAssertEqual(error as? PerformanceInspectorError, .invalidPropertyList)
        }
    }

    func testParseTimeMachineSnapshotsClassifiesAndSortsKnownDates() throws {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-12-090011.local
        com.apple.os.update-1234567890ABCDEF
        com.apple.TimeMachine.2026-09-14-143015.local
        custom.snapshot
        """

        let snapshots = PerformanceInspector.parseTimeMachineSnapshots(output)

        XCTAssertEqual(snapshots.count, 4)
        XCTAssertEqual(snapshots[0].identifier, "com.apple.TimeMachine.2026-09-14-143015.local")
        XCTAssertEqual(snapshots[0].kind, .timeMachine)
        XCTAssertNotNil(snapshots[0].date)
        XCTAssertEqual(snapshots[1].identifier, "com.apple.TimeMachine.2026-09-12-090011.local")
        XCTAssertEqual(snapshots[2].identifier, "com.apple.os.update-1234567890ABCDEF")
        XCTAssertEqual(snapshots[2].kind, .systemUpdate)
        XCTAssertNil(snapshots[2].date)
        XCTAssertEqual(snapshots[3].kind, .local)
    }

    func testParseTimeMachineSnapshotsIgnoresBlankAndHeaderLines() {
        XCTAssertTrue(PerformanceInspector.parseTimeMachineSnapshots("Snapshots for disk /:\n\n").isEmpty)
    }

    func testDeletionTimestampAllowsOnlyVerifiedTimeMachineSnapshots() {
        let valid = PerformanceSnapshot(
            identifier: "com.apple.TimeMachine.2026-09-14-143015.local",
            kind: .timeMachine,
            date: nil
        )
        let update = PerformanceSnapshot(
            identifier: "com.apple.os.update-123456",
            kind: .systemUpdate,
            date: nil
        )
        let injected = PerformanceSnapshot(
            identifier: "com.apple.TimeMachine.2026-09-14-143015;reboot.local",
            kind: .timeMachine,
            date: nil
        )
        let invalidDate = PerformanceSnapshot(
            identifier: "com.apple.TimeMachine.2026-99-99-999999.local",
            kind: .timeMachine,
            date: nil
        )

        XCTAssertEqual(PerformanceInspector.deletionTimestamp(for: valid), "2026-09-14-143015")
        XCTAssertNil(PerformanceInspector.deletionTimestamp(for: update))
        XCTAssertNil(PerformanceInspector.deletionTimestamp(for: injected))
        XCTAssertNil(PerformanceInspector.deletionTimestamp(for: invalidDate))
    }
}
