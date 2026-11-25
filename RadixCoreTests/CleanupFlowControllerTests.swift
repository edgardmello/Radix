import Foundation
import Testing

@testable import RadixCore

@MainActor
struct CleanupFlowControllerTests {
    @Test
    func smartPresetSelectsOnlyNonEmptySafeCategories() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let flow = CleanupFlowController(scanner: CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        ))

        flow.scan()
        try await waitForPhase(flow, differentFrom: .scanning)
        #expect(flow.phase == .ready)

        flow.selectSmartFreeSpace()
        #expect(flow.selectedIDs == Set(CleanupCategory.smartFreeSpaceIDs))
        #expect(!flow.selectedIDs.contains(.trash))
        #expect(!flow.selectedIDs.contains(.xcodeArchives))
        #expect(!flow.selectedIDs.contains(.oldDownloads))
        #expect(flow.selectedSize > 0)
    }

    @Test
    func toggleSelectionIgnoresTrash() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let flow = CleanupFlowController(scanner: CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        ))

        flow.scan()
        try await waitForPhase(flow, differentFrom: .scanning)

        flow.toggleSelection(.trash)
        #expect(flow.selectedIDs.isEmpty)

        flow.toggleSelection(.userCaches)
        #expect(flow.selectedIDs == [.userCaches])
        flow.toggleSelection(.userCaches)
        #expect(flow.selectedIDs.isEmpty)
    }

    @Test
    func cleanSelectedMovesItemsToTrashAndUpdatesResults() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let moved = URLBox()
        let flow = CleanupFlowController(
            scanner: CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        ),
            trashItem: { url in
                moved.append(url)
                try FileManager.default.removeItem(at: url)
            }
        )

        flow.scan()
        try await waitForPhase(flow, differentFrom: .scanning)
        flow.toggleSelection(.userCaches)
        #expect(flow.canClean)

        flow.cleanSelected()
        try await waitForPhase(flow, differentFrom: .cleaning)

        #expect(flow.phase == .ready)
        #expect(moved.snapshot.map { $0.lastPathComponent } == ["com.example.app"])
        #expect(flow.cleanedItemCount == 1)
        #expect(flow.freedBytes > 0)
        #expect(flow.failures.isEmpty)
        #expect(flow.result(for: .userCaches)?.isEmpty == true)
        #expect(flow.selectedIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Library/Caches/com.example.app").path))
    }

    @Test
    func protectedItemsAreNotMoved() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cacheDirectory = home.appending(path: "Library/Caches/com.example.app", directoryHint: .isDirectory)
        let policy = TrashSafetyPolicy(
            homeDirectory: cacheDirectory,
            mountedVolumeURLs: [],
            firmlinkEntries: []
        )
        let moved = URLBox()
        let flow = CleanupFlowController(
            scanner: CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        ),
            safetyPolicy: { policy },
            trashItem: { url in
                moved.append(url)
                try FileManager.default.removeItem(at: url)
            }
        )

        flow.scan()
        try await waitForPhase(flow, differentFrom: .scanning)
        flow.toggleSelection(.userCaches)
        flow.cleanSelected()
        try await waitForPhase(flow, differentFrom: .cleaning)

        #expect(moved.snapshot.isEmpty)
        #expect(flow.cleanedItemCount == 0)
        #expect(flow.failures.count == 1)
        #expect(flow.result(for: .userCaches)?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    @Test
    func emptyTrashRequiresConfirmationAndRemovesContents() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let removed = URLBox()
        let flow = CleanupFlowController(
            scanner: CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        ),
            removeItem: { url in
                removed.append(url)
                try FileManager.default.removeItem(at: url)
            }
        )

        flow.scan()
        try await waitForPhase(flow, differentFrom: .scanning)
        #expect(flow.canEmptyTrash)

        flow.requestEmptyTrash()
        #expect(flow.isConfirmingEmptyTrash)
        flow.cancelEmptyTrash()
        #expect(!flow.isConfirmingEmptyTrash)
        #expect(removed.snapshot.isEmpty)

        flow.requestEmptyTrash()
        flow.confirmEmptyTrash()
        try await waitForPhase(flow, differentFrom: .cleaning)

        #expect(removed.snapshot.map { $0.lastPathComponent } == ["trashed.txt"])
        #expect(flow.freedBytes > 0)
        #expect(flow.result(for: .trash)?.isEmpty == true)
        #expect(!flow.canEmptyTrash)
    }

    @Test
    func emptyTrashSkipsSymlinkEscape() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = home.appending(path: "sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        let escape = home.appending(path: ".Trash/escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sentinel)

        let removed = URLBox()
        let flow = CleanupFlowController(
            scanner: CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        ),
            removeItem: { url in
                removed.append(url)
                try FileManager.default.removeItem(at: url)
            }
        )

        flow.scan()
        try await waitForPhase(flow, differentFrom: .scanning)
        flow.requestEmptyTrash()
        flow.confirmEmptyTrash()
        try await waitForPhase(flow, differentFrom: .cleaning)

        #expect(!removed.snapshot.contains(escape))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: escape.path)) != nil)
        #expect(flow.failures.contains { $0.url == escape })
    }

    // MARK: - Helpers

    private func waitForPhase(
        _ flow: CleanupFlowController,
        differentFrom phase: CleanupFlowController.Phase
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while flow.phase == phase {
            if Date() > deadline {
                Issue.record("Cleanup flow stayed in phase \(phase) too long.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeFixtureHome() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appending(path: "CleanupFlowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = try #require(base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let home = URL(filePath: canonical, directoryHint: .isDirectory)

        try writeFile(home.appending(path: "Library/Caches/com.example.app/cache.bin"), bytes: 100)
        try writeFile(home.appending(path: "Library/Caches/Google/Chrome/Default/Cache/data.bin"), bytes: 200)
        try writeFile(home.appending(path: "Library/Logs/diag.log"), bytes: 50)
        try writeFile(home.appending(path: "Library/Developer/Xcode/DerivedData/ProjA/Build/out.o"), bytes: 300)
        try writeFile(home.appending(path: "Library/Developer/Xcode/Archives/App.xcarchive/Info.plist"), bytes: 10)
        try writeFile(home.appending(path: ".npm/_cacache/content-v2/sha"), bytes: 150)
        try writeFile(home.appending(path: "Downloads/old.bin"), bytes: 64)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 86_400)],
            ofItemAtPath: home.appending(path: "Downloads/old.bin").path
        )
        try writeFile(home.appending(path: ".Trash/trashed.txt"), bytes: 32)
        return home
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }
}

private nonisolated final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var snapshot: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
