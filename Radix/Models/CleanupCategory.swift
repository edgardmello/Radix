import Foundation

/// Identifiers for the junk categories surfaced by the Cleanup feature.
/// Every category is fully available; there is no licensing or tier gating.
nonisolated enum CleanupCategoryID: String, CaseIterable, Identifiable, Sendable {
    case userCaches
    case systemLogs
    case browserCaches
    case xcodeJunk
    case xcodeArchives
    case packageCaches
    case oldDownloads
    case duplicateDownloads
    case largeFiles
    case mailAttachments
    case docker
    case iosBackups
    case trash

    var id: String { rawValue }
}

/// How much caution a category deserves before its contents are cleaned.
nonisolated enum CleanupSafetyLevel: String, Sendable {
    /// Rebuildable data such as caches, logs, and build artifacts.
    case safe
    /// User files that deserve a look before they go to the Trash.
    case review
    /// Data that cannot be recreated, such as archives, backups, and VM disks.
    case caution
    /// Emptying the Trash removes items permanently.
    case permanent
}

nonisolated struct CleanupCategory: Identifiable, Sendable {
    let id: CleanupCategoryID
    let safety: CleanupSafetyLevel

    static let all: [CleanupCategory] = [
        CleanupCategory(id: .userCaches, safety: .safe),
        CleanupCategory(id: .systemLogs, safety: .safe),
        CleanupCategory(id: .browserCaches, safety: .safe),
        CleanupCategory(id: .xcodeJunk, safety: .safe),
        CleanupCategory(id: .packageCaches, safety: .safe),
        CleanupCategory(id: .oldDownloads, safety: .review),
        CleanupCategory(id: .duplicateDownloads, safety: .review),
        CleanupCategory(id: .largeFiles, safety: .review),
        CleanupCategory(id: .xcodeArchives, safety: .caution),
        CleanupCategory(id: .mailAttachments, safety: .caution),
        CleanupCategory(id: .docker, safety: .caution),
        CleanupCategory(id: .iosBackups, safety: .caution),
        CleanupCategory(id: .trash, safety: .permanent),
    ]

    static func category(for id: CleanupCategoryID) -> CleanupCategory {
        all.first { $0.id == id } ?? CleanupCategory(id: id, safety: .caution)
    }

    /// Categories whose contents can be cleared without reviewing user data.
    static var smartFreeSpaceIDs: [CleanupCategoryID] {
        all.filter { $0.safety == .safe }.map(\.id)
    }
}
