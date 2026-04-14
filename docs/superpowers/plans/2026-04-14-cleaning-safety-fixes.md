# Cleaning Safety Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Prevent PureMac from deleting personal files unexpectedly and add visible confirmation before manual destructive cleaning.

**Architecture:** Move item-selection state into a small testable model, keep manual cleaning behind an explicit confirmation request, and restrict scheduled auto-clean to categories that are cache/log/temp cleanup targets. The cleaner still uses the existing scan and delete engines, but the ViewModel becomes the gatekeeper for selection, confirmation, and scheduled-clean safety.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, XcodeGen.

---

### Task 1: Regression Tests for Selection and Scheduled Auto-Clean

**Files:**
- Modify: `project.yml`
- Create: `PureMacTests/ItemSelectionStateTests.swift`
- Create: `PureMacTests/ScheduleSafetyTests.swift`
- Regenerate: `PureMac.xcodeproj/project.pbxproj`

- [x] **Step 1: Add an XCTest target in `project.yml`**

Add a `PureMacTests` target with `platform: macOS`, `type: bundle.unit-test`, source path `PureMacTests`, and dependency on the `PureMac` application target.

- [x] **Step 2: Write failing selection tests**

```swift
import XCTest
@testable import PureMac

final class ItemSelectionStateTests: XCTestCase {
    func testDefaultDeselectedItemsStartDeselected() {
        var selection = ItemSelectionState()
        let item = CleanableItem(name: "movie.mov", path: "/Users/me/Desktop/movie.mov", size: 200_000_000, category: .largeFiles, isSelected: false, lastModified: nil)

        XCTAssertFalse(selection.isSelected(item))
    }

    func testDefaultDeselectedItemsCanBeSelectedExplicitly() {
        var selection = ItemSelectionState()
        let item = CleanableItem(name: "movie.mov", path: "/Users/me/Desktop/movie.mov", size: 200_000_000, category: .largeFiles, isSelected: false, lastModified: nil)

        selection.toggle(item)

        XCTAssertTrue(selection.isSelected(item))
    }

    func testSelectAllSelectsDefaultDeselectedItems() {
        var selection = ItemSelectionState()
        let item = CleanableItem(name: "movie.mov", path: "/Users/me/Desktop/movie.mov", size: 200_000_000, category: .largeFiles, isSelected: false, lastModified: nil)

        selection.selectAll([item])

        XCTAssertTrue(selection.isSelected(item))
    }

    func testDeselectAllDeselectsDefaultSelectedItems() {
        var selection = ItemSelectionState()
        let item = CleanableItem(name: "cache.db", path: "/Users/me/Library/Caches/cache.db", size: 20_000, category: .userCache, isSelected: true, lastModified: nil)

        selection.deselectAll([item])

        XCTAssertFalse(selection.isSelected(item))
    }
}
```

- [x] **Step 3: Write failing scheduled-clean safety tests**

```swift
import XCTest
@testable import PureMac

final class ScheduleSafetyTests: XCTestCase {
    func testDefaultScheduledCategoriesExcludePersonalFileCategories() {
        let categories = ScheduleConfig().categoriesToScan

        XCTAssertFalse(categories.contains(.largeFiles))
        XCTAssertFalse(categories.contains(.mailAttachments))
        XCTAssertFalse(categories.contains(.purgeableSpace))
    }

    func testAutomaticCleaningCategoriesAreOnlyCacheLikeTargets() {
        XCTAssertEqual(
            CleaningCategory.automaticCleaningCategories,
            [.systemJunk, .userCache, .aiApps, .trashBins, .xcodeJunk, .brewCache]
        )
    }
}
```

- [x] **Step 4: Run tests and verify red**

Run: `xcodegen generate && xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS'`

Expected: test build fails because `ItemSelectionState` and `CleaningCategory.automaticCleaningCategories` do not exist yet, or schedule assertions fail against the current all-category default.

### Task 2: Fix Default Selection Semantics

**Files:**
- Create: `PureMac/ViewModels/ItemSelectionState.swift`
- Modify: `PureMac/ViewModels/AppViewModel.swift`

- [x] **Step 1: Implement `ItemSelectionState`**

Create a value type that returns `item.isSelected` unless a user override exists. `toggle`, `selectAll`, and `deselectAll` should store overrides only when they differ from the item default.

- [x] **Step 2: Replace `deselectedItems` usage in `AppViewModel`**

Use `@Published private var itemSelection = ItemSelectionState()` and route `isItemSelected`, `toggleItem`, `selectAllInCategory`, `deselectAllInCategory`, `selectedSizeInCategory`, `selectedCountInCategory`, and `totalSelectedSize` through the new selection state.

- [x] **Step 3: Clear selection overrides on every new scan**

Call `itemSelection.clear()` where the old code called `deselectedItems.removeAll()`.

- [x] **Step 4: Run selection tests and verify green**

Run: `xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' -only-testing:PureMacTests/ItemSelectionStateTests`

Expected: all selection tests pass.

### Task 3: Restrict Scheduled Auto-Clean

**Files:**
- Modify: `PureMac/Models/Models.swift`
- Modify: `PureMac/ViewModels/AppViewModel.swift`

- [x] **Step 1: Add automatic-clean category policy**

Add `CleaningCategory.automaticCleaningCategories` returning `[.systemJunk, .userCache, .aiApps, .trashBins, .xcodeJunk, .brewCache]` and `var isAutomaticCleaningAllowed: Bool`.

- [x] **Step 2: Change schedule defaults**

Change `ScheduleConfig.categoriesToScan` from `CleaningCategory.scannable` to `CleaningCategory.automaticCleaningCategories`.

- [x] **Step 3: Filter existing persisted schedules at runtime**

In `runScheduledScan()`, filter `scheduler.config.categoriesToScan` with `isAutomaticCleaningAllowed` before scanning and auto-cleaning. This protects users who already have persisted configs containing `.largeFiles`, `.mailAttachments`, or `.purgeableSpace`.

- [x] **Step 4: Run schedule safety tests and verify green**

Run: `xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' -only-testing:PureMacTests/ScheduleSafetyTests`

Expected: all schedule safety tests pass.

### Task 4: Add Manual Clean Confirmation

**Files:**
- Modify: `PureMac/ViewModels/AppViewModel.swift`
- Modify: `PureMac/Views/ContentView.swift`
- Modify: `PureMac/Views/SmartScanView.swift`
- Modify: `PureMac/Views/CategoryDetailView.swift`

- [x] **Step 1: Add pending clean state**

Add a private pending action enum for all-items vs category cleaning. Add `requestCleanAll()`, `requestCleanCategory(_:)`, `cancelClean()`, `confirmClean()`, and a `cleanConfirmationMessage` string.

- [x] **Step 2: Keep scheduled cleaning direct but safe**

Move current cleaning implementation into private `performCleanAll()` and `performCleanCategory(_:)`; manual UI calls request methods, scheduled auto-clean calls `performCleanAll()` after filtering categories.

- [x] **Step 3: Add a destructive confirmation alert**

Attach an alert at the root `ContentView`. The destructive button text should clearly state permanent deletion.

- [x] **Step 4: Route clean buttons through request methods**

Change Smart Scan and Category Detail clean buttons to call `requestCleanAll()` and `requestCleanCategory(_:)`.

- [x] **Step 5: Build the app**

Run: `xcodebuild build -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS'`

Expected: build succeeds.

### Task 5: Full Verification

**Files:**
- Verify all modified files.

- [x] **Step 1: Run all tests**

Run: `xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS'`

Expected: all tests pass.

- [x] **Step 2: Run release build**

Run: `xcodebuild build -project PureMac.xcodeproj -scheme PureMac -configuration Release -destination 'platform=macOS'`

Expected: build succeeds.

- [x] **Step 3: Review security-sensitive searches**

Run: `rg -n "removeItem|Process\\(|launchctl|tmutil|diskutil|URLSession|analytics|telemetry|isSelected|automaticCleaningCategories" PureMac -g '*.swift'`

Expected: destructive/process surfaces are limited to known cleaner paths, and no telemetry/network client appears.
