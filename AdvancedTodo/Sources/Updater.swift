import Foundation
import SwiftUI
import AppKit

struct BackupArchiveInfo: Identifiable, Equatable {
    let id: String
    let url: URL
    let createdAt: Date
    let sizeBytes: Int64

    var displayName: String {
        url.lastPathComponent
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

struct UpdateAssetInfo: Equatable {
    let name: String
    let url: URL
    let sizeBytes: Int

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(sizeBytes))
    }
}

struct AppUpdateInfo: Equatable {
    let currentVersion: String
    let newVersion: String
    let changelog: String
    let publishedAt: Date?
    let asset: UpdateAssetInfo?

    var isInstallable: Bool {
        asset != nil
    }
}

final class UpdateManager: ObservableObject {
    @Published var isChecking = false
    @Published var isPresentingSheet = false
    @Published var installConfirmationVisible = false
    @Published var updatePromptVisible = false
    @Published var statusMessage = ""
    @Published var updateInfo: AppUpdateInfo?
    @Published var stagedUpdateAppURL: URL?
    @Published var stagedBackupURL: URL?
    @Published var isInstalling = false
    @Published var isRestoringBackup = false
    @Published var restoreConfirmationVisible = false
    @Published var availableBackups: [BackupArchiveInfo] = []
    @Published var selectedBackupID: String?
    @Published var canRestartAfterRestore = false

    private let repo: String

    init(repo: String? = Bundle.main.object(forInfoDictionaryKey: "UpdateRepo") as? String) {
        self.repo = repo ?? "Sekai0NI0itamio/TodoApp"
        refreshBackups()
    }

    func refreshBackups() {
        let fileManager = FileManager.default
        let backupRoot = backupRootURL()
        try? fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let backups = (try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let records: [BackupArchiveInfo] = backups.compactMap { url in
            guard url.pathExtension.lowercased() == "zip",
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }

            let createdAt = values.creationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)
            return BackupArchiveInfo(id: url.path, url: url, createdAt: createdAt, sizeBytes: size)
        }
        .sorted(by: { $0.createdAt > $1.createdAt })

        availableBackups = records
        if let selected = selectedBackupID, records.contains(where: { $0.id == selected }) {
            return
        }
        selectedBackupID = records.first?.id
    }

    func requestRestoreSelectedBackup() {
        guard selectedBackup() != nil else {
            statusMessage = "No backup selected to restore."
            return
        }
        restoreConfirmationVisible = true
    }

    func restoreSelectedBackup() {
        guard let selected = selectedBackup() else {
            statusMessage = "No backup selected to restore."
            return
        }

        isRestoringBackup = true
        canRestartAfterRestore = false
        statusMessage = "Restoring backup \(selected.displayName)..."

        Task {
            do {
                try restoreBackup(from: selected.url)
                await MainActor.run {
                    self.isRestoringBackup = false
                    self.statusMessage = "Backup restored successfully. Restarting the app is recommended."
                    self.canRestartAfterRestore = true
                    self.refreshBackups()
                }
            } catch {
                await MainActor.run {
                    self.isRestoringBackup = false
                    self.statusMessage = "Restore failed: \(error.localizedDescription)"
                    self.canRestartAfterRestore = false
                }
            }
        }
    }

    func revealBackupFolder() {
        let url = backupRootURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func restartAppNow() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        }
    }

    func checkForUpdates() {
        checkForUpdates(showSheetWhileChecking: true, showPromptWhenUpdateFound: false)
    }

    func checkForUpdates(showSheetWhileChecking: Bool, showPromptWhenUpdateFound: Bool) {
        isChecking = true
        statusMessage = "Checking for updates..."
        if showSheetWhileChecking {
            isPresentingSheet = true
        }

        Task {
            do {
                let info = try await fetchLatestUpdateInfo()
                await MainActor.run {
                    self.updateInfo = info
                    self.isChecking = false
                    if info == nil {
                        self.statusMessage = "You are on the latest version."
                        if showSheetWhileChecking {
                            self.updatePromptVisible = false
                        }
                    } else {
                        self.statusMessage = "A new update is available."
                        if showPromptWhenUpdateFound {
                            self.updatePromptVisible = true
                        }
                        if showSheetWhileChecking {
                            self.isPresentingSheet = true
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isChecking = false
                    self.statusMessage = "Update check failed: \(error.localizedDescription)"
                    self.updatePromptVisible = false
                    if !showSheetWhileChecking {
                        self.isPresentingSheet = false
                    }
                }
            }
        }
    }

    func beginGuidedUpdateFromPrompt() {
        updatePromptVisible = false
        isPresentingSheet = true
        prepareInstall()
    }

    func prepareInstall() {
        guard let info = updateInfo, let asset = info.asset else {
            statusMessage = "No installable update asset found."
            return
        }

        isInstalling = true
        statusMessage = "Preparing update..."

        Task {
            do {
                await MainActor.run {
                    self.statusMessage = "Creating safety backup..."
                }
                let backup = try backupAppData()

                await MainActor.run {
                    self.statusMessage = "Downloading \(asset.name)..."
                }
                let stagedApp = try await downloadAndStage(asset: asset)

                await MainActor.run {
                    self.stagedBackupURL = backup
                    self.stagedUpdateAppURL = stagedApp
                    self.installConfirmationVisible = true
                    self.isInstalling = false
                    self.statusMessage = "Backup created and update downloaded. Ready to install."
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.statusMessage = "Update preparation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func installStagedUpdate() {
        guard let stagedUpdateAppURL, let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            statusMessage = "No staged update available."
            return
        }

        let currentAppURL = Bundle.main.bundleURL
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("advancedtodo-install.sh")

        let script = """
        #!/bin/bash
        set -euo pipefail

        NEW_APP=\"$1\"
        TARGET_APP=\"$2\"

        # Wait briefly for old app to close.
        for _ in {1..30}; do
          if ! pgrep -f \"$TARGET_APP/Contents/MacOS/\(appName)\" >/dev/null; then
            break
          fi
          sleep 1
        done

        rm -rf \"$TARGET_APP\"
        cp -R \"$NEW_APP\" \"$TARGET_APP\"
        xattr -dr com.apple.quarantine \"$TARGET_APP\" 2>/dev/null || true
        open \"$TARGET_APP\"
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path, stagedUpdateAppURL.path, currentAppURL.path]
            try process.run()

            NSApp.terminate(nil)
        } catch {
            statusMessage = "Install failed to start: \(error.localizedDescription)"
        }
    }

    private func fetchLatestUpdateInfo() async throws -> AppUpdateInfo? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        guard let release = releases.first(where: { !$0.draft && !$0.prerelease }) else {
            return nil
        }

        let latestVersion = normalizedVersion(from: release.tagName)
        let currentVersion = currentAppVersion()

        guard compareVersions(latestVersion, currentVersion) == .orderedDescending else {
            return nil
        }

        let selectedAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })

        return AppUpdateInfo(
            currentVersion: currentVersion,
            newVersion: latestVersion,
            changelog: release.body.isEmpty ? "No changelog provided." : release.body,
            publishedAt: ISO8601DateFormatter().date(from: release.publishedAt),
            asset: selectedAsset.map { asset in
                UpdateAssetInfo(name: asset.name, url: URL(string: asset.browserDownloadURL)!, sizeBytes: asset.size)
            }
        )
    }

    private func currentAppVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private func normalizedVersion(from tag: String) -> String {
        tag.replacingOccurrences(of: "v", with: "", options: [.anchored])
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return .orderedSame
    }

    private func selectedBackup() -> BackupArchiveInfo? {
        guard let selectedBackupID else { return nil }
        return availableBackups.first(where: { $0.id == selectedBackupID })
    }

    private func backupRootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AdvancedTodoBackups", isDirectory: true)
    }

    private func backupAppData() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dataDirectory = appSupport.appendingPathComponent("AdvancedTodo", isDirectory: true)
        let backupRoot = backupRootURL()
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupZip = backupRoot.appendingPathComponent("AdvancedTodo-backup-\(timestamp).zip")

        if fileManager.fileExists(atPath: dataDirectory.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dataDirectory.path, backupZip.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "AdvancedTodo", code: 1201, userInfo: [NSLocalizedDescriptionKey: "Backup process failed."])
            }
        } else {
            try Data().write(to: backupZip)
        }

        return backupZip
    }

    private func restoreBackup(from backupZip: URL) throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dataDirectory = appSupport.appendingPathComponent("AdvancedTodo", isDirectory: true)

        // Safety snapshot before restore.
        _ = try? backupAppData()

        if let attrs = try? fileManager.attributesOfItem(atPath: backupZip.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue == 0 {
            try? fileManager.removeItem(at: dataDirectory)
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            return
        }

        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("AdvancedTodoRestore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipProcess.arguments = ["-x", "-k", backupZip.path, tempRoot.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        if unzipProcess.terminationStatus != 0 {
            throw NSError(domain: "AdvancedTodo", code: 1301, userInfo: [NSLocalizedDescriptionKey: "Could not extract backup archive."])
        }

        let restoredDirectory: URL
        let candidate = tempRoot.appendingPathComponent("AdvancedTodo", isDirectory: true)
        if fileManager.fileExists(atPath: candidate.path) {
            restoredDirectory = candidate
        } else if let found = findDirectoryNamed("AdvancedTodo", in: tempRoot) {
            restoredDirectory = found
        } else {
            throw NSError(domain: "AdvancedTodo", code: 1302, userInfo: [NSLocalizedDescriptionKey: "Backup does not contain AdvancedTodo data."])
        }

        try? fileManager.removeItem(at: dataDirectory)
        try fileManager.copyItem(at: restoredDirectory, to: dataDirectory)
    }

    private func downloadAndStage(asset: UpdateAssetInfo) async throws -> URL {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("AdvancedTodoUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let zipURL = tempRoot.appendingPathComponent(asset.name)
        let (downloadedURL, _) = try await URLSession.shared.download(from: asset.url)
        try fileManager.moveItem(at: downloadedURL, to: zipURL)

        let unzipDirectory = tempRoot.appendingPathComponent("unzipped", isDirectory: true)
        try fileManager.createDirectory(at: unzipDirectory, withIntermediateDirectories: true)

        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipProcess.arguments = ["-x", "-k", zipURL.path, unzipDirectory.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        if unzipProcess.terminationStatus != 0 {
            throw NSError(domain: "AdvancedTodo", code: 1202, userInfo: [NSLocalizedDescriptionKey: "Unable to unzip downloaded update."])
        }

        guard let appURL = findAppBundle(in: unzipDirectory) else {
            throw NSError(domain: "AdvancedTodo", code: 1203, userInfo: [NSLocalizedDescriptionKey: "No .app found in downloaded package."])
        }

        return appURL
    }

    private func findAppBundle(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "app" {
                return fileURL
            }
        }
        return nil
    }

    private func findDirectoryNamed(_ name: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue,
               fileURL.lastPathComponent == name {
                return fileURL
            }
        }
        return nil
    }
}

private struct GitHubRelease: Codable {
    let tagName: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let size: Int
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
    }
}

struct UpdateSheetView: View {
    @EnvironmentObject var updater: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update Center")
                .font(.title3.bold())

            if updater.isChecking {
                ProgressView("Checking GitHub releases...")
            }

            if updater.isInstalling {
                ProgressView("Downloading and preparing update...")
            }

            Text(updater.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)

            GroupBox("Restore From Backup") {
                VStack(alignment: .leading, spacing: 8) {
                    if updater.availableBackups.isEmpty {
                        Text("No backup archives found in the app backup folder.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Detected Backups", selection: Binding(
                            get: { updater.selectedBackupID ?? "" },
                            set: { updater.selectedBackupID = $0.isEmpty ? nil : $0 }
                        )) {
                            ForEach(updater.availableBackups) { backup in
                                Text("\(backup.displayName) - \(backup.formattedDate) - \(backup.formattedSize)")
                                    .tag(backup.id)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack {
                            Button("Refresh Backups") {
                                updater.refreshBackups()
                            }
                            Button("Reveal Backup Folder") {
                                updater.revealBackupFolder()
                            }
                            Button("Restore Selected") {
                                updater.requestRestoreSelectedBackup()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.selectedBackupID == nil || updater.isRestoringBackup)
                        }

                        if updater.canRestartAfterRestore {
                            Button("Restart App Now") {
                                updater.restartAppNow()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let info = updater.updateInfo {
                GroupBox("Version") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current: \(info.currentVersion)")
                        Text("Available: \(info.newVersion)")
                        if let asset = info.asset {
                            Text("Download: \(asset.name)")
                            Text("Size: \(asset.formattedSize)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Changelog / New Features") {
                    ScrollView {
                        Text(info.changelog)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120)
                }

                if info.isInstallable {
                    HStack {
                        Button("Update Now") {
                            updater.prepareInstall()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.isInstalling)

                        if let backup = updater.stagedBackupURL {
                            Text("Backup: \(backup.lastPathComponent)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close") {
                    updater.isPresentingSheet = false
                }
            }
        }
        .padding()
        .frame(width: 560, height: 460)
        .onAppear {
            updater.refreshBackups()
        }
        .alert("Install Update", isPresented: $updater.installConfirmationVisible) {
            Button("Install And Replace App", role: .destructive) {
                updater.installStagedUpdate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup has been created. Install the new version and replace this app now? Your old app will be removed and the new one will relaunch.")
        }
        .alert("Restore Backup", isPresented: $updater.restoreConfirmationVisible) {
            Button("Restore Now", role: .destructive) {
                updater.restoreSelectedBackup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restore the selected backup into your app data folder? A safety backup of current data will be created first.")
        }
    }
}
