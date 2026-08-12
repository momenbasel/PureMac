import XCTest
@testable import PureMac

final class VSCodeExtensionHomePathRulesTests: XCTestCase {
    func testCandidatePathsForContinueIncludeDotContinue() {
        let rel = VSCodeExtensionHomePathRules.candidateRelativePaths(
            extensionId: "Continue.continue"
        )
        XCTAssertTrue(rel.contains(".continue"))
        XCTAssertTrue(rel.contains(".config/continue"))
        XCTAssertTrue(rel.contains(".config/Continue-continue") || rel.contains(".config/continue-continue"))
    }

    func testCandidatePathsForGitHubCopilotIncludeDotCopilotAndConfigDashId() {
        let rel = VSCodeExtensionHomePathRules.candidateRelativePaths(
            extensionId: "GitHub.copilot"
        )
        XCTAssertTrue(rel.contains(".copilot"))
        XCTAssertTrue(rel.contains(".config/github-copilot"))
        // `.github` is too generic (gh CLI); publisher-only must be denied.
        XCTAssertFalse(rel.contains(".github"))
    }

    func testDeniedGenericNamePythonDoesNotEmitDotPython() {
        let rel = VSCodeExtensionHomePathRules.candidateRelativePaths(
            extensionId: "ms-python.python"
        )
        XCTAssertFalse(rel.contains(".python"))
        XCTAssertFalse(rel.contains(".config/python"))
    }

    func testDeniedDockerPublisherDoesNotEmitDotDocker() {
        let rel = VSCodeExtensionHomePathRules.candidateRelativePaths(
            extensionId: "ms-azuretools.vscode-docker"
        )
        // name vscode-docker is long enough → may emit .vscode-docker
        XCTAssertTrue(rel.contains(".vscode-docker") || rel.contains(".ms-azuretools-vscode-docker"))
        XCTAssertFalse(rel.contains(".docker"))
    }

    func testIsAssociatedMatchesCaseInsensitiveHomeDotDir() {
        let home = "/Users/demo"
        XCTAssertTrue(
            VSCodeExtensionHomePathRules.isAssociated(
                path: "\(home)/.Continue",
                extensionId: "Continue.continue",
                homeDirectoryPath: home
            )
        )
        XCTAssertFalse(
            VSCodeExtensionHomePathRules.isAssociated(
                path: "\(home)/.ssh",
                extensionId: "Continue.continue",
                homeDirectoryPath: home
            )
        )
        XCTAssertFalse(
            VSCodeExtensionHomePathRules.isAssociated(
                path: "\(home)/.config",
                extensionId: "GitHub.copilot",
                homeDirectoryPath: home
            )
        )
        XCTAssertTrue(
            VSCodeExtensionHomePathRules.isAssociated(
                path: "\(home)/.config/github-copilot",
                extensionId: "GitHub.copilot",
                homeDirectoryPath: home
            )
        )
    }

    func testIsHomePersonalizationPath() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        XCTAssertTrue(
            VSCodeExtensionHomePathRules.isHomePersonalizationPath(
                URL(fileURLWithPath: "/Users/demo/.continue"),
                homeDirectory: home
            )
        )
        XCTAssertTrue(
            VSCodeExtensionHomePathRules.isHomePersonalizationPath(
                URL(fileURLWithPath: "/Users/demo/.config/github-copilot"),
                homeDirectory: home
            )
        )
        XCTAssertFalse(
            VSCodeExtensionHomePathRules.isHomePersonalizationPath(
                URL(fileURLWithPath: "/Users/demo/Library/Application Support/Cursor/User/globalStorage/x"),
                homeDirectory: home
            )
        )
    }

    func testDefaultSelectionExcludesPersonalization() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let install = URL(fileURLWithPath: "/tmp/home/.cursor/extensions/Continue.continue-1.0.0")
        let global = URL(fileURLWithPath: "/tmp/home/Library/Application Support/Cursor/User/globalStorage/Continue.continue")
        let personal = URL(fileURLWithPath: "/tmp/home/.continue")
        let selected = VSCodeExtensionHomePathRules.defaultSelectedPaths(
            from: [install, global, personal],
            homeDirectory: home
        )
        XCTAssertTrue(selected.contains(install))
        XCTAssertTrue(selected.contains(global))
        XCTAssertFalse(selected.contains(personal))
    }
}
