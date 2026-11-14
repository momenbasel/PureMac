import Foundation
import XCTest
@testable import PureMac

final class ProtectionAuditTests: XCTestCase {
    func testParsesEnabledAndDisabledGatekeeperStates() {
        XCTAssertEqual(
            ProtectionAudit.parse(.gatekeeper, result: result(stdout: "assessments enabled")).status,
            .enabled
        )
        XCTAssertEqual(
            ProtectionAudit.parse(.gatekeeper, result: result(stdout: "assessments disabled")).status,
            .disabled
        )
    }

    func testParsesFileVaultFirewallAndSIPStates() {
        XCTAssertEqual(
            ProtectionAudit.parse(.fileVault, result: result(stdout: "FileVault is On.")).status,
            .enabled
        )
        XCTAssertEqual(
            ProtectionAudit.parse(.fileVault, result: result(stdout: "FileVault is Off.")).status,
            .disabled
        )
        XCTAssertEqual(
            ProtectionAudit.parse(.firewall, result: result(stdout: "Firewall is enabled. (State = 1)")).status,
            .enabled
        )
        XCTAssertEqual(
            ProtectionAudit.parse(.firewall, result: result(stdout: "Firewall is disabled. (State = 0)")).status,
            .disabled
        )
        XCTAssertEqual(
            ProtectionAudit.parse(
                .systemIntegrityProtection,
                result: result(stdout: "System Integrity Protection status: enabled.")
            ).status,
            .enabled
        )
        XCTAssertEqual(
            ProtectionAudit.parse(
                .systemIntegrityProtection,
                result: result(stdout: "System Integrity Protection status: disabled.")
            ).status,
            .disabled
        )
    }

    func testUnrecognizedOutputIsUnknown() {
        let finding = ProtectionAudit.parse(
            .systemIntegrityProtection,
            result: result(stdout: "System Integrity Protection status: unknown (Custom Configuration).")
        )

        XCTAssertEqual(finding.status, .unknown)
        XCTAssertEqual(finding.detail, String(localized: "The system returned an unrecognized status."))
    }

    func testCommandFailureCannotBeReportedAsEnabled() {
        let finding = ProtectionAudit.parse(
            .gatekeeper,
            result: ProtectionCommandResult(
                exitCode: 1,
                stdout: "assessments enabled",
                stderr: "operation failed",
                timedOut: false,
                cancelled: false,
                launchError: nil
            )
        )

        XCTAssertEqual(finding.status, .unknown)
        XCTAssertEqual(finding.detail, String(localized: "PureMac could not read this setting."))
    }

    func testTimeoutIsUnknown() {
        let finding = ProtectionAudit.parse(
            .firewall,
            result: ProtectionCommandResult(
                exitCode: nil,
                stdout: "",
                stderr: "",
                timedOut: true,
                cancelled: false,
                launchError: nil
            )
        )

        XCTAssertEqual(finding.status, .unknown)
        XCTAssertEqual(finding.detail, String(localized: "The check timed out."))
    }

    func testAuditPreservesCheckOrder() async {
        let xProtect = ProtectionFinding(
            check: .xProtect,
            status: .enabled,
            detail: "Installed.",
            version: "definitions 1"
        )
        let audit = ProtectionAudit(
            commandExecutor: { command in
                switch command {
                case .gatekeeper:
                    return ProtectionCommandResult(
                        exitCode: 0,
                        stdout: "assessments enabled",
                        stderr: "",
                        timedOut: false,
                        cancelled: false,
                        launchError: nil
                    )
                case .fileVault:
                    return ProtectionCommandResult(
                        exitCode: 0,
                        stdout: "FileVault is On.",
                        stderr: "",
                        timedOut: false,
                        cancelled: false,
                        launchError: nil
                    )
                case .firewall:
                    return ProtectionCommandResult(
                        exitCode: 0,
                        stdout: "Firewall is enabled. (State = 1)",
                        stderr: "",
                        timedOut: false,
                        cancelled: false,
                        launchError: nil
                    )
                case .systemIntegrityProtection:
                    return ProtectionCommandResult(
                        exitCode: 0,
                        stdout: "System Integrity Protection status: enabled.",
                        stderr: "",
                        timedOut: false,
                        cancelled: false,
                        launchError: nil
                    )
                }
            },
            xProtectInspector: { xProtect }
        )

        let snapshot = await audit.run()

        XCTAssertEqual(snapshot.findings.map(\.check), ProtectionCheck.allCases)
        XCTAssertTrue(snapshot.findings.allSatisfy { $0.status == .enabled })
    }

    func testCommandsUseFixedAbsoluteExecutablesWithoutAShell() {
        let expected: [ProtectionCommand: (String, [String])] = [
            .gatekeeper: ("/usr/sbin/spctl", ["--status"]),
            .fileVault: ("/usr/bin/fdesetup", ["status"]),
            .firewall: ("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
            .systemIntegrityProtection: ("/usr/bin/csrutil", ["status"])
        ]

        for command in ProtectionCommand.allCases {
            XCTAssertEqual(command.executableURL.path, expected[command]?.0)
            XCTAssertEqual(command.arguments, expected[command]?.1)
            XCTAssertNotEqual(command.executableURL.path, "/bin/sh")
            XCTAssertNotEqual(command.executableURL.path, "/bin/zsh")
        }
    }

    func testRunnerPassesArgumentsDirectlyWithoutShellExpansion() async {
        let request = ProtectionProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "$(echo injected); *"]
        )

        let output = await ProtectionCommandRunner.run(request, timeout: 1)

        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.stdout, "$(echo injected); *")
    }

    func testRunnerTimeoutIsBounded() async {
        let request = ProtectionProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"]
        )
        let start = Date()

        let output = await ProtectionCommandRunner.run(request, timeout: 0.05)

        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testRunnerReturnsWhenADescendantKeepsOutputPipeOpen() async {
        let request = ProtectionProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 2 & /usr/bin/printf done"]
        )
        let start = Date()

        let output = await ProtectionCommandRunner.run(request, timeout: 1)

        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.stdout, "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testCancellingRunnerStopsTheProcess() async {
        let request = ProtectionProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"]
        )
        let start = Date()
        let task = Task {
            await ProtectionCommandRunner.run(request, timeout: 10)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let output = await task.value

        XCTAssertTrue(output.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    private func result(stdout: String) -> ProtectionCommandResult {
        ProtectionCommandResult(
            exitCode: 0,
            stdout: stdout,
            stderr: "",
            timedOut: false,
            cancelled: false,
            launchError: nil
        )
    }
}
