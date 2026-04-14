import SwiftUI
import Combine

@MainActor
class AppViewModel: ObservableObject {
    private enum PendingCleanAction {
        case all(items: [CleanableItem])
        case category(CleaningCategory, items: [CleanableItem])

        var items: [CleanableItem] {
            switch self {
            case .all(let items), .category(_, let items):
                return items
            }
        }
    }

    // MARK: - State
    @Published var selectedCategory: CleaningCategory = .smartScan
    @Published var scanState: ScanState = .idle
    @Published var categoryResults: [CleaningCategory: CategoryResult] = [:]
    @Published var diskInfo = DiskInfo()
    @Published var totalJunkSize: Int64 = 0
    @Published var totalFreedSpace: Int64 = 0
    @Published var scanProgress: Double = 0
    @Published var cleanProgress: Double = 0
    @Published var currentScanCategory: String = ""
    @Published var showCleanConfirmation = false
    @Published var lastCleanedDate: Date?
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false
    @Published private var itemSelection = ItemSelectionState()

    var scheduler = SchedulerService()
    private let scanEngine = ScanEngine()
    private let cleaningEngine = CleaningEngine()
    private var pendingCleanAction: PendingCleanAction?

    // MARK: - Computed

    var totalItemCount: Int {
        categoryResults.values.reduce(0) { $0 + $1.itemCount }
    }

    var currentCategoryResult: CategoryResult? {
        categoryResults[selectedCategory]
    }

    var allResults: [CategoryResult] {
        CleaningCategory.scannable.compactMap { categoryResults[$0] }.filter { $0.totalSize > 0 }
    }

    // MARK: - Selection

    func isItemSelected(_ item: CleanableItem) -> Bool {
        itemSelection.isSelected(item)
    }

    func toggleItem(_ item: CleanableItem) {
        itemSelection.toggle(item)
    }

    func selectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        itemSelection.selectAll(result.items)
    }

    func deselectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        itemSelection.deselectAll(result.items)
    }

    func selectedSizeInCategory(_ category: CleaningCategory) -> Int64 {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    func selectedCountInCategory(_ category: CleaningCategory) -> Int {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.count
    }

    var totalSelectedSize: Int64 {
        allResults.flatMap { $0.items }.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    var cleanConfirmationMessage: String {
        let items = pendingCleanAction?.items ?? []
        let size = items.reduce(0) { $0 + $1.size }
        let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

        return "This will permanently delete \(items.count) selected items (\(formattedSize)). This cannot be undone."
    }

    // MARK: - Init

    init() {
        loadDiskInfo()
        checkFullDiskAccess()
        scheduler.setTrigger { [weak self] in
            await self?.runScheduledScan()
        }
        scheduler.start()
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() {
        Task.detached {
            let granted = FullDiskAccessManager.shared.hasFullDiskAccess
            await MainActor.run { [weak self] in
                self?.hasFullDiskAccess = granted
            }
        }
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
    }

    // MARK: - Disk Info

    func loadDiskInfo() {
        Task {
            let info = await scanEngine.getDiskInfo()
            self.diskInfo = info
        }
    }

    // MARK: - Scanning

    func startSmartScan() {
        guard !scanState.isActive else { return }

        scanState = .scanning(progress: 0, currentCategory: "Preparing...")
        categoryResults = [:]
        totalJunkSize = 0
        scanProgress = 0
        itemSelection.clear()

        Task {
            let categories = CleaningCategory.scannable
            let total = categories.count

            for (index, category) in categories.enumerated() {
                let progress = Double(index) / Double(total)
                scanProgress = progress
                currentScanCategory = category.rawValue
                scanState = .scanning(progress: progress, currentCategory: category.rawValue)

                let result = await scanEngine.scanCategory(category)
                categoryResults[category] = result
                totalJunkSize += result.totalSize
            }

            scanProgress = 1.0
            scanState = .completed
            loadDiskInfo()
        }
    }

    func scanSingleCategory(_ category: CleaningCategory) {
        guard !scanState.isActive else { return }

        scanState = .scanning(progress: 0, currentCategory: category.rawValue)
        scanProgress = 0

        Task {
            scanProgress = 0.5
            itemSelection.clear()
            let result = await scanEngine.scanCategory(category)
            categoryResults[category] = result

            // Recalculate total
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            scanProgress = 1.0
            scanState = .completed
        }
    }

    // MARK: - Cleaning

    func cleanAll() {
        requestCleanAll()
    }

    func cleanCategory(_ category: CleaningCategory) {
        requestCleanCategory(category)
    }

    func requestCleanAll() {
        guard !scanState.isActive else { return }

        let items = selectedItemsForAll()
        guard !items.isEmpty else { return }

        pendingCleanAction = .all(items: items)
        showCleanConfirmation = true
    }

    func requestCleanCategory(_ category: CleaningCategory) {
        guard !scanState.isActive else { return }

        let items = selectedItems(in: category)
        guard !items.isEmpty else { return }

        pendingCleanAction = .category(category, items: items)
        showCleanConfirmation = true
    }

    func cancelClean() {
        pendingCleanAction = nil
        showCleanConfirmation = false
    }

    func confirmClean() {
        let action = pendingCleanAction
        pendingCleanAction = nil
        showCleanConfirmation = false

        switch action {
        case .all(let items):
            performCleanAll(itemsToClean: items)
        case .category(let category, let items):
            performCleanCategory(category, itemsToClean: items)
        case nil:
            break
        }
    }

    private func performCleanAll(
        itemsToClean providedItems: [CleanableItem]? = nil,
        limitingTo categories: Set<CleaningCategory>? = nil
    ) {
        guard !scanState.isActive else { return }

        let itemsToClean: [CleanableItem]
        if let providedItems {
            itemsToClean = providedItems
        } else {
            let resultsToClean = allResults.filter { result in
                categories?.contains(result.category) ?? true
            }
            itemsToClean = resultsToClean.flatMap { $0.items }.filter { isItemSelected($0) }
        }

        guard !itemsToClean.isEmpty else { return }

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            let result = await cleaningEngine.cleanItems(itemsToClean) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            totalFreedSpace = result.freedSpace
            lastCleanedDate = Date()

            if let categories {
                for category in categories {
                    categoryResults.removeValue(forKey: category)
                }
                totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            } else {
                categoryResults = [:]
                totalJunkSize = 0
            }

            itemSelection.clear()
            scanState = .cleaned
            loadDiskInfo()

            // Reset state after delay
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    private func performCleanCategory(
        _ category: CleaningCategory,
        itemsToClean providedItems: [CleanableItem]? = nil
    ) {
        guard !scanState.isActive else { return }

        let selectedItems: [CleanableItem]
        if let providedItems {
            selectedItems = providedItems
        } else {
            guard let result = categoryResults[category] else { return }
            selectedItems = result.items.filter { isItemSelected($0) }
        }

        guard !selectedItems.isEmpty else { return }

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            let cleanResult = await cleaningEngine.cleanItems(selectedItems) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            totalFreedSpace = cleanResult.freedSpace
            lastCleanedDate = Date()

            categoryResults.removeValue(forKey: category)
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            itemSelection.clear()
            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    // MARK: - Purgeable

    func purgePurgeable() {
        guard !scanState.isActive else { return }

        scanState = .cleaning(progress: 0)

        Task {
            scanState = .cleaning(progress: 0.5)
            let freed = await cleaningEngine.purgePurgeableSpace()
            totalFreedSpace = freed
            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    // MARK: - Scheduled Scan

    private func runScheduledScan() async {
        let categories = scheduler.config.categoriesToScan.filter { $0.isAutomaticCleaningAllowed }
        var totalFound: Int64 = 0

        for category in categories {
            let result = await scanEngine.scanCategory(category)
            categoryResults[category] = result
            totalFound += result.totalSize
        }

        totalJunkSize = totalFound

        if scheduler.config.autoClean && totalFound >= scheduler.config.minimumCleanSize {
            performCleanAll(limitingTo: Set(categories))
        }

        if scheduler.config.autoPurge {
            _ = await cleaningEngine.purgePurgeableSpace()
        }

        if scheduler.config.notifyOnCompletion {
            sendNotification(freed: totalFound)
        }
    }

    private func sendNotification(freed: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "PureMac"
        let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        content.body = String(format: NSLocalizedString("Found %@ of junk files.", comment: ""), sizeStr)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func selectedItemsForAll() -> [CleanableItem] {
        allResults.flatMap { $0.items }.filter { isItemSelected($0) }
    }

    private func selectedItems(in category: CleaningCategory) -> [CleanableItem] {
        guard let result = categoryResults[category] else { return [] }
        return result.items.filter { isItemSelected($0) }
    }

}

import UserNotifications
