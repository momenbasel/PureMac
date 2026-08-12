import XCTest
@testable import PureMac

final class VSCodeExtensionListUpdaterTests: XCTestCase {
    func testRemovingInstallDirectoryDropsThatExtensionOnly() {
        let keep = makeItem(path: "/tmp/home/.cursor/extensions/keep.ext-1.0.0", id: "keep.ext")
        let gone = makeItem(path: "/tmp/home/.cursor/extensions/gone.ext-1.0.0", id: "gone.ext")
        let result = VSCodeExtensionListUpdater.applyingRemoval(
            extensions: [keep, gone],
            selected: gone,
            removedPaths: [URL(fileURLWithPath: gone.path)]
        )
        XCTAssertEqual(result.extensions.map(\.extensionId), ["keep.ext"])
        XCTAssertEqual(result.selected?.extensionId, "keep.ext")
    }

    func testRemovingInstallSelectsNextThenPrevious() {
        let a = makeItem(path: "/tmp/a", id: "a.ext")
        let b = makeItem(path: "/tmp/b", id: "b.ext")
        let c = makeItem(path: "/tmp/c", id: "c.ext")

        let mid = VSCodeExtensionListUpdater.applyingRemoval(
            extensions: [a, b, c],
            selected: b,
            removedPaths: [URL(fileURLWithPath: b.path)]
        )
        XCTAssertEqual(mid.extensions.map(\.extensionId), ["a.ext", "c.ext"])
        XCTAssertEqual(mid.selected?.extensionId, "c.ext")

        let last = VSCodeExtensionListUpdater.applyingRemoval(
            extensions: [a, b, c],
            selected: c,
            removedPaths: [URL(fileURLWithPath: c.path)]
        )
        XCTAssertEqual(last.selected?.extensionId, "b.ext")

        let only = VSCodeExtensionListUpdater.applyingRemoval(
            extensions: [a],
            selected: a,
            removedPaths: [URL(fileURLWithPath: a.path)]
        )
        XCTAssertTrue(only.extensions.isEmpty)
        XCTAssertNil(only.selected)
    }

    func testNeighborOrderUsesDisplayOrderNotStorageOrder() {
        let a = makeItem(path: "/tmp/a", id: "a.ext")
        let b = makeItem(path: "/tmp/b", id: "b.ext")
        let c = makeItem(path: "/tmp/c", id: "c.ext")
        // Storage order a,b,c — display order c,b,a (e.g. size sort).
        let result = VSCodeExtensionListUpdater.applyingRemoval(
            extensions: [a, b, c],
            selected: b,
            removedPaths: [URL(fileURLWithPath: b.path)],
            neighborOrder: [c, b, a]
        )
        XCTAssertEqual(result.selected?.extensionId, "a.ext")
    }

    func testRemovingOnlyRelatedStorageKeepsExtensionRow() {
        let item = makeItem(path: "/tmp/home/.cursor/extensions/keep.ext-1.0.0", id: "keep.ext")
        let storage = URL(fileURLWithPath: "/tmp/home/Library/Application Support/Cursor/User/globalStorage/keep.ext")
        let result = VSCodeExtensionListUpdater.applyingRemoval(
            extensions: [item],
            selected: item,
            removedPaths: [storage]
        )
        XCTAssertEqual(result.extensions.map(\.extensionId), ["keep.ext"])
        XCTAssertEqual(result.selected?.extensionId, "keep.ext")
    }

    private func makeItem(path: String, id: String) -> VSCodeExtensionItem {
        VSCodeExtensionItem(
            editorLabel: "Cursor",
            displayName: id,
            path: path,
            size: 1,
            lastModified: nil,
            extensionId: id,
            editorDotDirectory: ".cursor"
        )
    }
}
