import Foundation

/// One filesystem entry offered for cleanup. Sizes use allocated bytes so the
/// freed-space estimate matches what the volume actually reports.
nonisolated struct CleanupItem: Sendable, Equatable, Identifiable {
    let url: URL
    let size: Int64
    let isDirectory: Bool

    var id: URL { url }
}

nonisolated struct CleanupCategoryResult: Sendable, Equatable {
    let id: CleanupCategoryID
    let items: [CleanupItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty }
}

nonisolated struct CleanupScanOptions: Sendable, Equatable {
    /// Downloads untouched for at least this many days are offered as old.
    var oldDownloadDays: Int = 30
    /// Files at least this large are offered in the large-files category.
    var largeFileThresholdBytes: Int64 = 100 * 1024 * 1024

    static let `default` = CleanupScanOptions()
}

/// Resolves cleanup category locations and measures their contents off the
/// main actor. Unreadable locations are skipped instead of failing the scan,
/// so partial Full Disk Access still produces useful results.
nonisolated struct CleanupScanner: Sendable {
    let homeDirectory: URL
    let trashDirectory: URL
    let systemLogsDirectory: URL
    private var fileManager: FileManager { .default }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashDirectory: URL? = nil,
        systemLogsDirectory: URL = URL(fileURLWithPath: "/Library/Logs", isDirectory: true)
    ) {
        self.homeDirectory = homeDirectory
        self.trashDirectory = trashDirectory
            ?? homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory)
        self.systemLogsDirectory = systemLogsDirectory
    }

    func scan(options: CleanupScanOptions = .default) throws -> [CleanupCategoryResult] {
        try CleanupCategoryID.allCases.map { id in
            try Task.checkCancellation()
            return CleanupCategoryResult(id: id, items: try items(for: id, options: options))
        }
    }

    // MARK: - Category resolution

    private func items(
        for id: CleanupCategoryID,
        options: CleanupScanOptions
    ) throws -> [CleanupItem] {
        switch id {
        case .userCaches:
            return try children(of: libraryCachesDirectory)
                .filter { !Self.browserCacheDirectoryNames.contains($0.lastPathComponent) }
                .compactMap { try item(at: $0) }
        case .systemLogs:
            let userLogs = try children(of: homeDirectory.appending(path: "Library/Logs", directoryHint: .isDirectory))
            let systemLogs = try children(of: systemLogsDirectory)
            return try (userLogs + systemLogs).compactMap { try item(at: $0) }
        case .browserCaches:
            return try Self.browserCachePaths(relativeTo: homeDirectory)
                .compactMap { try item(at: $0) }
        case .xcodeJunk:
            let derivedData = homeDirectory.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
            let simulatorCaches = homeDirectory.appending(path: "Library/Developer/CoreSimulator/Caches", directoryHint: .isDirectory)
            return try (children(of: derivedData) + children(of: simulatorCaches))
                .compactMap { try item(at: $0) }
        case .xcodeArchives:
            let archives = homeDirectory.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory)
            return try children(of: archives).compactMap { try item(at: $0) }
        case .packageCaches:
            return try Self.packageCachePaths(relativeTo: homeDirectory)
                .compactMap { try item(at: $0) }
        case .oldDownloads:
            let cutoff = Date().addingTimeInterval(-Double(max(0, options.oldDownloadDays)) * 86_400)
            return try children(of: downloadsDirectory).compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified <= cutoff else { return nil }
                return try item(at: url)
            }
        case .duplicateDownloads:
            return try duplicateItems(in: downloadsDirectory)
        case .largeFiles:
            return try largeFileItems(threshold: options.largeFileThresholdBytes)
        case .mailAttachments:
            let containerDownloads = homeDirectory.appending(
                path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                directoryHint: .isDirectory
            )
            let legacyDownloads = homeDirectory.appending(path: "Library/Mail Downloads", directoryHint: .isDirectory)
            let directory = fileManager.fileExists(atPath: containerDownloads.path)
                ? containerDownloads
                : legacyDownloads
            return try children(of: directory).compactMap { try item(at: $0) }
        case .docker:
            return try Self.dockerDiskPaths(relativeTo: homeDirectory)
                .compactMap { try item(at: $0) }
        case .iosBackups:
            let backups = homeDirectory.appending(path: "Library/Application Support/MobileSync/Backup", directoryHint: .isDirectory)
            return try children(of: backups).compactMap { try item(at: $0) }
        case .trash:
            return try children(of: trashDirectory).compactMap { try item(at: $0) }
        }
    }

    private var libraryCachesDirectory: URL {
        homeDirectory.appending(path: "Library/Caches", directoryHint: .isDirectory)
    }

    private var downloadsDirectory: URL {
        homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    /// Top-level `~/Library/Caches` entries owned by browsers. They are
    /// reported under browser caches instead of user caches so the same bytes
    /// are never offered twice.
    static let browserCacheDirectoryNames: Set<String> = [
        "Google", "Chromium", "com.apple.Safari", "Firefox",
        "Microsoft Edge", "BraveSoftware", "Arc",
    ]

    static func browserCachePaths(relativeTo home: URL) -> [URL] {
        [
            "Library/Caches/Google/Chrome",
            "Library/Caches/Google/Chrome Canary",
            "Library/Caches/Chromium",
            "Library/Caches/com.apple.Safari",
            "Library/Caches/Firefox",
            "Library/Caches/Microsoft Edge",
            "Library/Caches/BraveSoftware",
            "Library/Caches/Arc",
        ].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    static func packageCachePaths(relativeTo home: URL) -> [URL] {
        [
            ".npm/_cacache",
            "Library/Caches/Yarn",
            "Library/pnpm/store",
            ".pnpm-store",
            "Library/Caches/Homebrew",
            ".gradle/caches",
            "Library/Caches/pip",
            ".cargo/registry/cache",
            ".cache",
            "Library/Caches/CocoaPods",
        ].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    static func dockerDiskPaths(relativeTo home: URL) -> [URL] {
        [
            "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "Library/Containers/com.docker.docker/Data/vms/0/Docker.raw",
        ].map { home.appending(path: $0, directoryHint: .notDirectory) }
    }

    // MARK: - Enumeration helpers

    private func children(of directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
    }

    private func item(at url: URL) throws -> CleanupItem? {
        try Task.checkCancellation()
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
        ]) else { return nil }
        let isDirectory = values.isDirectory ?? false
        let size: Int64
        if isDirectory {
            size = try directorySize(at: url)
        } else {
            size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return CleanupItem(url: url, size: size, isDirectory: isDirectory)
    }

    private func directorySize(at directory: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 256 == 0 {
                try Task.checkCancellation()
            }
            guard let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileSizeKey,
            ]) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// A download is offered as a duplicate only when its name carries a copy
    /// suffix and the presumed original exists beside it with the same size.
    private func duplicateItems(in directory: URL) throws -> [CleanupItem] {
        let entries = try children(of: directory)
        var sizesByName: [String: Int64] = [:]
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else { continue }
            sizesByName[url.lastPathComponent] = Int64(values.fileSize ?? 0)
        }
        var duplicates: [CleanupItem] = []
        for url in entries {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            guard let originalName = Self.originalName(forCopyNamed: name),
                  let copySize = sizesByName[name],
                  sizesByName[originalName] == copySize,
                  let item = try item(at: url) else { continue }
            duplicates.append(item)
        }
        return duplicates
    }

    /// Strips trailing copy markers such as " copy", " (2)", or " 2" from a
    /// filename, keeping the extension. Returns nil when no marker is present.
    static func originalName(forCopyNamed name: String) -> String? {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let pattern = #"( copy( \d+)?| \(\d+\)| \d+)$"#
        guard let range = base.range(of: pattern, options: .regularExpression) else { return nil }
        let originalBase = String(base[..<range.lowerBound])
        guard !originalBase.isEmpty else { return nil }
        return ext.isEmpty ? originalBase : originalBase + "." + ext
    }

    private func largeFileItems(threshold: Int64) throws -> [CleanupItem] {
        let roots = ["Downloads", "Documents", "Desktop", "Movies"].map {
            homeDirectory.appending(path: $0, directoryHint: .isDirectory)
        }
        var items: [CleanupItem] = []
        var visited = 0
        for root in roots {
            guard fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                      at: root,
                      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else { continue }
            for case let url as URL in enumerator {
                visited += 1
                if visited % 256 == 0 {
                    try Task.checkCancellation()
                }
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true,
                      let size = values.fileSize.map(Int64.init),
                      size >= threshold else { continue }
                let allocated = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize.map(Int64.init)
                items.append(CleanupItem(url: url, size: allocated ?? size, isDirectory: false))
            }
        }
        return items
    }
}
