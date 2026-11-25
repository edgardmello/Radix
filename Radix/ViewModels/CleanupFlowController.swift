import Combine
import Foundation

/// Owns the Cleanup feature: scanning junk categories, selecting what to
/// clear, and moving the selection to the Trash. Emptying the Trash is a
/// separate, explicitly confirmed permanent action. All categories are
/// available without restriction; there is no licensing or tier gating.
@MainActor
final class CleanupFlowController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case cleaning
    }

    struct Failure: Identifiable, Equatable {
        let url: URL
        let message: String

        var id: URL { url }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [CleanupCategoryResult] = []
    @Published private(set) var selectedIDs: Set<CleanupCategoryID> = []
    @Published private(set) var failures: [Failure] = []
    @Published private(set) var scanError: String?
    @Published private(set) var freedBytes: Int64 = 0
    @Published private(set) var cleanedItemCount = 0
    @Published private(set) var isConfirmingEmptyTrash = false
    @Published var options = CleanupScanOptions.default

    private let scanner: CleanupScanner
    private let safetyPolicy: @Sendable () -> TrashSafetyPolicy
    private let trashItem: @Sendable (URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    init(
        scanner: CleanupScanner = CleanupScanner(),
        safetyPolicy: @escaping @Sendable () -> TrashSafetyPolicy = { .live() },
        trashItem: (@Sendable (URL) throws -> Void)? = nil,
        removeItem: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.scanner = scanner
        self.safetyPolicy = safetyPolicy
        self.trashItem = trashItem ?? { url in
            var resultingItemURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
        }
        self.removeItem = removeItem ?? { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Derived state

    func result(for id: CleanupCategoryID) -> CleanupCategoryResult? {
        results.first { $0.id == id }
    }

    var selectedItems: [CleanupItem] {
        results
            .filter { selectedIDs.contains($0.id) && $0.id != .trash }
            .flatMap(\.items)
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    var canClean: Bool {
        phase == .ready && !selectedItems.isEmpty
    }

    var canEmptyTrash: Bool {
        phase == .ready && result(for: .trash)?.isEmpty == false
    }

    // MARK: - Scanning

    func scan() {
        guard phase != .scanning, phase != .cleaning else { return }
        scanTask?.cancel()
        phase = .scanning
        scanError = nil
        failures = []
        freedBytes = 0
        cleanedItemCount = 0
        let scanner = scanner
        let options = options
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let results = try scanner.scan(options: options)
                await self?.applyScanResults(results)
            } catch is CancellationError {
                await self?.finishCancelledScan()
            } catch {
                await self?.finishFailedScan(error)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func applyScanResults(_ results: [CleanupCategoryResult]) {
        guard phase == .scanning else { return }
        self.results = results
        selectedIDs = []
        phase = .ready
    }

    private func finishCancelledScan() {
        guard phase == .scanning else { return }
        phase = results.isEmpty ? .idle : .ready
    }

    private func finishFailedScan(_ error: any Error) {
        guard phase == .scanning else { return }
        scanError = error.localizedDescription
        phase = results.isEmpty ? .idle : .ready
    }

    // MARK: - Selection

    func toggleSelection(_ id: CleanupCategoryID) {
        guard id != .trash else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// One-click selection of every rebuildable category that has contents —
    /// the safe way to reclaim space without reviewing user files.
    func selectSmartFreeSpace() {
        guard phase == .ready else { return }
        selectedIDs = Set(CleanupCategory.smartFreeSpaceIDs.filter { id in
            result(for: id)?.isEmpty == false
        })
    }

    func clearSelection() {
        selectedIDs = []
    }

    // MARK: - Cleaning (move to Trash)

    func cleanSelected() {
        guard canClean else { return }
        phase = .cleaning
        failures = []
        freedBytes = 0
        cleanedItemCount = 0
        let items = selectedItems
        let policy = safetyPolicy()
        let trashItem = trashItem
        cleanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var movedURLs: Set<URL> = []
            var freed: Int64 = 0
            var failures: [Failure] = []
            for item in items {
                if Task.isCancelled { break }
                if policy.blockReason(for: item.url) != nil {
                    failures.append(Failure(
                        url: item.url,
                        message: String(localized: "This item is in a protected location.")
                    ))
                    continue
                }
                do {
                    try trashItem(item.url)
                    movedURLs.insert(item.url)
                    freed += item.size
                } catch {
                    failures.append(Failure(url: item.url, message: error.localizedDescription))
                }
            }
            await self?.applyCleanOutcome(movedURLs: movedURLs, freed: freed, failures: failures)
        }
    }

    func cancelCleaning() {
        cleanTask?.cancel()
    }

    private func applyCleanOutcome(movedURLs: Set<URL>, freed: Int64, failures: [Failure]) {
        guard phase == .cleaning else { return }
        results = results.map { result in
            CleanupCategoryResult(
                id: result.id,
                items: result.items.filter { !movedURLs.contains($0.url) }
            )
        }
        selectedIDs = []
        freedBytes = freed
        cleanedItemCount = movedURLs.count
        self.failures = failures
        phase = .ready
    }

    // MARK: - Empty Trash (permanent, confirmed)

    func requestEmptyTrash() {
        guard canEmptyTrash else { return }
        isConfirmingEmptyTrash = true
    }

    func cancelEmptyTrash() {
        isConfirmingEmptyTrash = false
    }

    func confirmEmptyTrash() {
        guard isConfirmingEmptyTrash, canEmptyTrash,
              let trashResult = result(for: .trash) else { return }
        isConfirmingEmptyTrash = false
        phase = .cleaning
        failures = []
        freedBytes = 0
        cleanedItemCount = 0
        let urls = trashResult.items.map(\.url)
        let sizes = Dictionary(uniqueKeysWithValues: trashResult.items.map { ($0.url, $0.size) })
        let trashDirectory = scanner.trashDirectory
        let removeItem = removeItem
        let policy = safetyPolicy()
        cleanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let trashRoot = trashDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            var removedURLs: Set<URL> = []
            var freed: Int64 = 0
            var failures: [Failure] = []
            for url in urls {
                if Task.isCancelled { break }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(trashRoot + "/"),
                      policy.blockReason(for: url) == nil else {
                    failures.append(Failure(
                        url: url,
                        message: String(localized: "This item is in a protected location.")
                    ))
                    continue
                }
                do {
                    try removeItem(url)
                    removedURLs.insert(url)
                    freed += sizes[url] ?? 0
                } catch {
                    failures.append(Failure(url: url, message: error.localizedDescription))
                }
            }
            await self?.applyCleanOutcome(movedURLs: removedURLs, freed: freed, failures: failures)
        }
    }

    func dismissFailures() {
        failures = []
    }

    func dismissScanError() {
        scanError = nil
    }
}
