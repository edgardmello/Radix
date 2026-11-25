import Foundation
import Testing

@testable import RadixCore

struct CleanupScannerTests {
    @Test
    func categorizesJunkWithoutDoubleCountingBrowserCaches() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        )

        let results = try scanner.scan()
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

        let userCaches = try #require(byID[.userCaches])
        #expect(userCaches.items.map { $0.url.lastPathComponent } == ["com.example.app"])

        let browserCaches = try #require(byID[.browserCaches])
        #expect(browserCaches.items.contains { $0.url.path.hasSuffix("Google/Chrome") })
        #expect(browserCaches.totalSize > 0)

        let systemLogs = try #require(byID[.systemLogs])
        #expect(systemLogs.items.map { $0.url.lastPathComponent } == ["diag.log", "system.log"])

        let xcodeJunk = try #require(byID[.xcodeJunk])
        #expect(xcodeJunk.items.map { $0.url.lastPathComponent } == ["ProjA"])

        let xcodeArchives = try #require(byID[.xcodeArchives])
        #expect(xcodeArchives.items.map { $0.url.lastPathComponent } == ["App.xcarchive"])

        let packageCaches = try #require(byID[.packageCaches])
        #expect(packageCaches.items.contains { $0.url.path.hasSuffix(".npm/_cacache") })

        #expect(try #require(byID[.mailAttachments]).isEmpty)
        #expect(try #require(byID[.docker]).isEmpty)
        #expect(try #require(byID[.iosBackups]).isEmpty)
    }

    @Test
    func oldDownloadsRespectAgeThreshold() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        )

        let results = try scanner.scan(options: CleanupScanOptions(oldDownloadDays: 30))
        let oldDownloads = try #require(results.first { $0.id == .oldDownloads })
        #expect(oldDownloads.items.map { $0.url.lastPathComponent } == ["old.bin"])

        let relaxed = try scanner.scan(options: CleanupScanOptions(oldDownloadDays: 0))
        let allDownloads = try #require(relaxed.first { $0.id == .oldDownloads })
        #expect(allDownloads.items.count > oldDownloads.items.count)
    }

    @Test
    func duplicateDownloadsRequireMatchingOriginal() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        )

        let results = try scanner.scan()
        let duplicates = try #require(results.first { $0.id == .duplicateDownloads })
        #expect(duplicates.items.map { $0.url.lastPathComponent } == ["report (1).pdf"])
    }

    @Test
    func largeFilesRespectThreshold() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        )

        var options = CleanupScanOptions.default
        options.largeFileThresholdBytes = 1024
        let results = try scanner.scan(options: options)
        let largeFiles = try #require(results.first { $0.id == .largeFiles })
        #expect(largeFiles.items.map { $0.url.lastPathComponent } == ["big.iso"])

        let defaultResults = try scanner.scan()
        #expect(try #require(defaultResults.first { $0.id == .largeFiles }).isEmpty)
    }

    @Test
    func trashContentsAreListed() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        )

        let results = try scanner.scan()
        let trash = try #require(results.first { $0.id == .trash })
        #expect(trash.items.map { $0.url.lastPathComponent } == ["trashed.txt"])
        #expect(trash.totalSize > 0)
    }

    @Test
    func scanStopsWhenCancelled() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CleanupScanner(
            homeDirectory: home,
            systemLogsDirectory: home.appending(path: "SystemLogs", directoryHint: .isDirectory)
        )

        await #expect(throws: CancellationError.self) {
            try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try scanner.scan()
            }.value
        }
    }

    @Test
    func copyNameParsing() {
        #expect(CleanupScanner.originalName(forCopyNamed: "report copy.pdf") == "report.pdf")
        #expect(CleanupScanner.originalName(forCopyNamed: "report copy 2.pdf") == "report.pdf")
        #expect(CleanupScanner.originalName(forCopyNamed: "report (1).pdf") == "report.pdf")
        #expect(CleanupScanner.originalName(forCopyNamed: "report 2.pdf") == "report.pdf")
        #expect(CleanupScanner.originalName(forCopyNamed: "report.pdf") == nil)
        #expect(CleanupScanner.originalName(forCopyNamed: "copy.pdf") == nil)
        #expect(CleanupScanner.originalName(forCopyNamed: "report copy") == "report")
    }

    // MARK: - Fixture

    private func makeFixtureHome() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appending(path: "CleanupScannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = try #require(base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let home = URL(filePath: canonical, directoryHint: .isDirectory)

        try writeFile(home.appending(path: "Library/Caches/com.example.app/cache.bin"), bytes: 100)
        try writeFile(home.appending(path: "Library/Caches/Google/Chrome/Default/Cache/data.bin"), bytes: 200)
        try writeFile(home.appending(path: "Library/Logs/diag.log"), bytes: 50)
        try writeFile(home.appending(path: "SystemLogs/system.log"), bytes: 20)
        try writeFile(home.appending(path: "Library/Developer/Xcode/DerivedData/ProjA/Build/out.o"), bytes: 300)
        try writeFile(home.appending(path: "Library/Developer/Xcode/Archives/App.xcarchive/Info.plist"), bytes: 10)
        try writeFile(home.appending(path: ".npm/_cacache/content-v2/sha"), bytes: 150)

        let oldDownload = home.appending(path: "Downloads/old.bin")
        try writeFile(oldDownload, bytes: 64)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 86_400)],
            ofItemAtPath: oldDownload.path
        )
        try writeFile(home.appending(path: "Downloads/new.bin"), bytes: 64)
        try writeFile(home.appending(path: "Downloads/report.pdf"), bytes: 128)
        try writeFile(home.appending(path: "Downloads/report (1).pdf"), bytes: 128)
        try writeFile(home.appending(path: "Downloads/orphan (1).pdf"), bytes: 128)
        try writeFile(home.appending(path: "Downloads/big.iso"), bytes: 4096)
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
