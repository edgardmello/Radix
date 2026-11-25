import SwiftUI

/// Cleanup sheet: scan junk categories, review sizes, and move the selection
/// to the Trash. Every category is available without restriction.
struct CleanupView: View {
    @ObservedObject var flow: CleanupFlowController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cleanup")
                .font(.title3.weight(.semibold))

            Text("Clear junk files to free up space. Cleaning moves files to the Trash.")
                .font(.callout)
                .foregroundStyle(.secondary)

            content

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 660, height: 620)
        .onAppear {
            if flow.phase == .idle {
                flow.scan()
            }
        }
        .alert("Some items could not be cleaned.", isPresented: failuresPresented) {
            Button("OK", role: .cancel) { flow.dismissFailures() }
        } message: {
            Text(flow.failures.prefix(5).map { "\($0.url.lastPathComponent): \($0.message)" }
                .joined(separator: "\n"))
        }
        .alert("Scan Failed", isPresented: scanErrorPresented) {
            Button("OK", role: .cancel) { flow.dismissScanError() }
        } message: {
            Text(flow.scanError ?? "")
        }
        .confirmationDialog("Empty Trash?", isPresented: emptyTrashPresented, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { flow.confirmEmptyTrash() }
            Button("Cancel", role: .cancel) { flow.cancelEmptyTrash() }
        } message: {
            Text("Items already in the Trash are removed permanently.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .idle, .scanning:
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning junk categories…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .cleaning:
            if flow.results.allSatisfy(\.isEmpty) {
                ContentUnavailableView(
                    "Nothing to clean",
                    systemImage: "checkmark.circle",
                    description: Text("No junk was found in the scanned categories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                categoryList
            }
        }
    }

    private var categoryList: some View {
        List {
            ForEach(CleanupCategory.all) { category in
                categoryRow(category)
            }

            Section("Options") {
                Stepper(value: $flow.options.oldDownloadDays, in: 1...365) {
                    Text("Older than \(flow.options.oldDownloadDays) days")
                }
                .disabled(flow.phase == .cleaning)

                Stepper(value: largeFileThresholdMB, in: 10...10_000, step: 10) {
                    Text("Larger than \(largeFileThresholdMB.wrappedValue) MB")
                }
                .disabled(flow.phase == .cleaning)
            }
        }
        .listStyle(.inset)
    }

    private var largeFileThresholdMB: Binding<Int> {
        Binding(
            get: { Int(flow.options.largeFileThresholdBytes / (1024 * 1024)) },
            set: { flow.options.largeFileThresholdBytes = Int64($0) * 1024 * 1024 }
        )
    }

    @ViewBuilder
    private func categoryRow(_ category: CleanupCategory) -> some View {
        let result = flow.result(for: category.id)
        let size = result?.totalSize ?? 0
        let count = result?.items.count ?? 0

        if category.id == .trash {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash")
                    Text("Items already in the Trash are removed permanently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(RadixFormatters.size(size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Empty Trash") { flow.requestEmptyTrash() }
                    .disabled(!flow.canEmptyTrash)
            }
            .padding(.vertical, 2)
        } else {
            Toggle(isOn: selectionBinding(for: category.id)) {
                HStack(spacing: 10) {
                    Image(systemName: Self.iconName(for: category.id))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(for: category.id))
                        Text(Self.subtitle(for: category.id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(RadixFormatters.size(size))
                            .monospacedDigit()
                        if count > 0 {
                            Text("\(count) items • \(RadixFormatters.size(size))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    safetyBadge(category.safety)
                }
            }
            .disabled(result?.isEmpty ?? true || flow.phase == .cleaning)
            .padding(.vertical, 2)
        }
    }

    private func selectionBinding(for id: CleanupCategoryID) -> Binding<Bool> {
        Binding(
            get: { flow.selectedIDs.contains(id) },
            set: { _ in flow.toggleSelection(id) }
        )
    }

    private func safetyBadge(_ level: CleanupSafetyLevel) -> some View {
        let color: Color = switch level {
        case .safe: .green
        case .review: .blue
        case .caution: .orange
        case .permanent: .red
        }
        return Text(Self.badgeTitle(for: level))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Smart Free Space") { flow.selectSmartFreeSpace() }
                .disabled(flow.phase != .ready)
                .help("Select all safe categories")

            Spacer()

            if flow.phase == .cleaning {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { flow.cancelCleaning() }
            } else {
                if flow.freedBytes > 0 {
                    Text("Freed \(RadixFormatters.size(flow.freedBytes))")
                        .foregroundStyle(.secondary)
                }

                Button("Done", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                cleanButton
            }
        }
    }

    private var cleanButton: some View {
        let count = flow.selectedItems.count
        return Button {
            flow.cleanSelected()
        } label: {
            if count > 0 {
                Text(String(localized: "Move \(count) Items to Trash"))
            } else {
                Text("Move to Trash")
            }
        }
        .disabled(!flow.canClean)
    }

    // MARK: - Alert bindings

    private var failuresPresented: Binding<Bool> {
        Binding(
            get: { !flow.failures.isEmpty },
            set: { if !$0 { flow.dismissFailures() } }
        )
    }

    private var scanErrorPresented: Binding<Bool> {
        Binding(
            get: { flow.scanError != nil },
            set: { if !$0 { flow.dismissScanError() } }
        )
    }

    private var emptyTrashPresented: Binding<Bool> {
        Binding(
            get: { flow.isConfirmingEmptyTrash },
            set: { if !$0 { flow.cancelEmptyTrash() } }
        )
    }

    // MARK: - Presentation mapping

    static func iconName(for id: CleanupCategoryID) -> String {
        switch id {
        case .userCaches: "shippingbox"
        case .systemLogs: "doc.text"
        case .browserCaches: "globe"
        case .xcodeJunk: "hammer"
        case .xcodeArchives: "archivebox"
        case .packageCaches: "shippingbox.fill"
        case .oldDownloads: "arrow.down.circle"
        case .duplicateDownloads: "doc.on.doc"
        case .largeFiles: "scalemass"
        case .mailAttachments: "envelope"
        case .docker: "cube"
        case .iosBackups: "iphone"
        case .trash: "trash"
        }
    }

    static func title(for id: CleanupCategoryID) -> LocalizedStringKey {
        switch id {
        case .userCaches: "User Caches"
        case .systemLogs: "System Logs"
        case .browserCaches: "Browser Caches"
        case .xcodeJunk: "Xcode Junk"
        case .xcodeArchives: "Xcode Archives"
        case .packageCaches: "Package Caches"
        case .oldDownloads: "Old Downloads"
        case .duplicateDownloads: "Duplicate Downloads"
        case .largeFiles: "Large Files"
        case .mailAttachments: "Mail Attachments"
        case .docker: "Docker"
        case .iosBackups: "iOS Backups"
        case .trash: "Trash"
        }
    }

    static func subtitle(for id: CleanupCategoryID) -> LocalizedStringKey {
        switch id {
        case .userCaches: "Application caches that apps rebuild as needed."
        case .systemLogs: "Diagnostic logs kept by macOS and apps."
        case .browserCaches: "Cached web content from Safari, Chrome, and other browsers."
        case .xcodeJunk: "DerivedData and simulator caches Xcode rebuilds."
        case .xcodeArchives: "App archives that cannot be recreated."
        case .packageCaches: "Download caches for npm, Yarn, pnpm, Homebrew, Gradle, and more."
        case .oldDownloads: "Downloads untouched for the configured number of days."
        case .duplicateDownloads: "Copies of downloads whose original is still present."
        case .largeFiles: "Files above the configured size in your user folders."
        case .mailAttachments: "Attachments saved by Mail. Handle with care."
        case .docker: "Docker Desktop VM disk. Removing it deletes containers and images."
        case .iosBackups: "Device backups that cannot be recreated."
        case .trash: "Items already in the Trash are removed permanently."
        }
    }

    static func badgeTitle(for level: CleanupSafetyLevel) -> LocalizedStringKey {
        switch level {
        case .safe: "Safe"
        case .review: "Review"
        case .caution: "Handle with care"
        case .permanent: "Permanent"
        }
    }
}
