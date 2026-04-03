import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppUpdateManager: NSObject, URLSessionDownloadDelegate {
    static let shared = AppUpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case updateAvailable(version: String)
        case downloading(version: String)
        case installing(version: String)
        case upToDate
        case failed(String)
    }

    struct ReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    struct ReleaseInfo: Decodable {
        let tagName: String
        let assets: [ReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private let owner = "Dimense-Studio"
    private let repo = "MLV"
    private let checkIntervalSeconds: UInt64 = 60 * 60

    private var updateLoopTask: Task<Void, Never>?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadedFileURL: URL?
    private var expectedDownloadAssetName: String?

    var state: State = .idle
    var progress: Double = 0
    var latestRemoteVersion: String?
    var autoUpdateEnabled: Bool {
        AppSettingsStore.shared.autoUpdateEnabled
    }

    private override init() {
        super.init()
    }

    func start() {
        updateLoopTask?.cancel()
        guard autoUpdateEnabled else {
            state = .idle
            return
        }
        updateLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.checkAndUpdateIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.checkIntervalSeconds * 1_000_000_000)
                if Task.isCancelled { return }
                guard self.autoUpdateEnabled else { continue }
                await self.checkAndUpdateIfNeeded()
            }
        }
    }

    func checkNow() {
        Task { [weak self] in
            await self?.checkAndUpdateIfNeeded()
        }
    }

    private func checkAndUpdateIfNeeded() async {
        guard autoUpdateEnabled else { return }
        state = .checking
        progress = 0
        do {
            let release = try await fetchLatestRelease()
            let remoteVersion = normalizedVersion(release.tagName)
            latestRemoteVersion = remoteVersion

            guard isRemoteVersionNewer(remoteVersion) else {
                state = .upToDate
                return
            }

            state = .updateAvailable(version: remoteVersion)
            AppNotifications.shared.notify(
                id: "update-available-\(remoteVersion)",
                title: "MLV update available",
                body: "Version \(remoteVersion) found. Downloading now.",
                minimumInterval: 300
            )

            let asset = try selectAsset(from: release.assets)
            state = .downloading(version: remoteVersion)
            let downloadedURL = try await downloadAsset(asset)
            state = .installing(version: remoteVersion)
            progress = 1
            try await installFromDownloadedAsset(downloadedURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MLV-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AppUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "GitHub release lookup failed"])
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    private func selectAsset(from assets: [ReleaseAsset]) throws -> ReleaseAsset {
        if let preferred = assets.first(where: { $0.name.lowercased().hasSuffix(".app.zip") }) {
            return preferred
        }
        if let zip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
            return zip
        }
        throw NSError(domain: "AppUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "No zip asset found in latest release"])
    }

    private func downloadAsset(_ asset: ReleaseAsset) async throws -> URL {
        guard continuation == nil else {
            throw NSError(domain: "AppUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Another download is already running"])
        }
        progress = 0
        downloadedFileURL = nil
        expectedDownloadAssetName = asset.name

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        guard let url = URL(string: asset.browserDownloadURL) else {
            throw NSError(domain: "AppUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
        }

        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session?.downloadTask(with: url).resume()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.progress = min(1, max(0, value))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            do {
                let ext = (self.expectedDownloadAssetName as NSString?)?.pathExtension ?? "zip"
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mlv-update-\(UUID().uuidString)")
                    .appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                self.downloadedFileURL = destination
            } catch {
                self.downloadedFileURL = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            defer {
                self.continuation = nil
                self.session?.invalidateAndCancel()
                self.session = nil
            }
            if let error {
                self.continuation?.resume(throwing: error)
                return
            }
            guard let fileURL = self.downloadedFileURL else {
                self.continuation?.resume(throwing: NSError(domain: "AppUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: "Download finished without file"]))
                return
            }
            self.continuation?.resume(returning: fileURL)
        }
    }

    private func installFromDownloadedAsset(_ archiveURL: URL) async throws {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mlv-update-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archiveURL.path, stagingRoot.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "AppUpdate", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to unpack update archive"])
        }

        guard let newApp = findAppBundle(in: stagingRoot) else {
            throw NSError(domain: "AppUpdate", code: 7, userInfo: [NSLocalizedDescriptionKey: "No .app found in update package"])
        }

        let desktopMLVDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("MLV", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopMLVDir, withIntermediateDirectories: true)
        let targetApp = desktopMLVDir.appendingPathComponent("MLV.app")

        let updaterScript = """
        #!/bin/zsh
        set -e
        NEW_APP="\(newApp.path)"
        TARGET_APP="\(targetApp.path)"
        mkdir -p "$(dirname "$TARGET_APP")"
        for _ in {1..40}; do
          if pgrep -x "MLV" >/dev/null; then
            sleep 0.25
          else
            break
          fi
        done
        rm -rf "$TARGET_APP"
        cp -R "$NEW_APP" "$TARGET_APP"
        open "$TARGET_APP"
        """

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("mlv-self-update-\(UUID().uuidString).sh")
        try updaterScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptURL.path]
        try chmod.run()
        chmod.waitUntilExit()
        guard chmod.terminationStatus == 0 else {
            throw NSError(domain: "AppUpdate", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not prepare updater script"])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [scriptURL.path]
        try proc.run()

        AppNotifications.shared.notify(
            id: "update-installing",
            title: "MLV update installing",
            body: "Installing update and restarting app.",
            minimumInterval: 30
        )
        NSApp.terminate(nil)
    }

    private func findAppBundle(in root: URL) -> URL? {
        if root.pathExtension.lowercased() == "app" { return root }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension.lowercased() == "app", next.lastPathComponent == "MLV.app" {
                return next
            }
        }
        return nil
    }

    private func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored, .caseInsensitive])
    }

    private func isRemoteVersionNewer(_ remote: String) -> Bool {
        let local = normalizedVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        return compareVersions(remote, local) == .orderedDescending
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(left.count, right.count)
        for idx in 0..<maxCount {
            let l = idx < left.count ? left[idx] : 0
            let r = idx < right.count ? right[idx] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return .orderedSame
    }
}
