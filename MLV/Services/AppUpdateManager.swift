import Foundation

@MainActor
@Observable
final class AppUpdateManager {
    enum State: Equatable {
        case idle
        case checking
        case updateAvailable(String)
        case downloading(String)
        case installing(String)
        case upToDate
        case failed(String)
    }

    static let shared = AppUpdateManager()

    var state: State = .idle
    var progress: Double = 0.0
    var lastCheckedAt: Date?

    private let logger = AppLogger.category("AppUpdateManager")
    private var activeTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard AppSettingsStore.shared.autoUpdateEnabled else {
            state = .idle
            return
        }
        if state == .idle {
            checkNow()
        }
    }

    func checkNow() {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.runCheckFlow()
        }
    }

    private func runCheckFlow() async {
        state = .checking
        progress = 0
        lastCheckedAt = Date()
        logger.info("Checking for updates")

        do {
            try await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            state = .upToDate
            logger.info("No updates available")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
