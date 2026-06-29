import Combine
import Foundation

enum LocalLLMDownloadState: Equatable, Sendable {
    case downloading(startedAt: TimeInterval, progress: Double)
    case failed(message: String)
}

enum LocalLLMDownloadManagerError: LocalizedError {
    case downloadedModelUnavailable(LocalLLMModel)
    case progressStalled(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .downloadedModelUnavailable(let model):
            "Downloaded files for \(model.displayName) are not usable yet. Please try again."
        case .progressStalled(let timeout):
            "Download did not make progress for \(max(1, Int(timeout.rounded(.up)))) seconds. Please check your connection and retry."
        }
    }
}

@MainActor
final class LocalLLMDownloadManager: ObservableObject, @unchecked Sendable {
    typealias ProgressHandler = @MainActor @Sendable (Double) -> Void
    typealias DownloadOperation = @Sendable (LocalLLMModel, @escaping ProgressHandler) async throws -> Void

    @Published private(set) var downloadErrors: [LocalLLMModel: String] = [:]
    @Published private(set) var downloadFailureMessages: [LocalLLMModel: String] = [:]
    @Published private(set) var downloadStates: [LocalLLMModel: LocalLLMDownloadState] = [:]

    private let download: DownloadOperation
    private let now: @Sendable () -> TimeInterval
    private let progressStallTimeout: TimeInterval?
    private let progressStallCheckInterval: TimeInterval
    private let validateDownloadedModel: @Sendable (LocalLLMModel) -> Bool
    private var tasks: [LocalLLMModel: DownloadTask] = [:]

    private struct DownloadTask {
        let id: UUID
        let task: Task<Void, Never>
        var monitorTask: Task<Void, Never>?
        var lastProgressAt: TimeInterval
        var lastPublishedProgressAt: TimeInterval
    }

    init(
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        progressStallTimeout: TimeInterval? = 120,
        progressStallCheckInterval: TimeInterval = 5,
        validateDownloadedModel: @escaping @Sendable (LocalLLMModel) -> Bool = { $0.isDownloaded },
        download: @escaping DownloadOperation
    ) {
        self.now = now
        self.progressStallTimeout = progressStallTimeout
        self.progressStallCheckInterval = max(0.25, progressStallCheckInterval)
        self.validateDownloadedModel = validateDownloadedModel
        self.download = download
    }

    var activeDownloadCount: Int {
        tasks.count
    }

    func isDownloading(_ model: LocalLLMModel) -> Bool {
        tasks[model] != nil
    }

    func startDownload(_ model: LocalLLMModel) {
        guard model.isHuggingFaceModel, tasks[model] == nil else { return }
        if validateDownloadedModel(model) {
            downloadErrors.removeValue(forKey: model)
            downloadFailureMessages.removeValue(forKey: model)
            downloadStates.removeValue(forKey: model)
            return
        }

        let downloadID = UUID()
        let startedAt = now()
        downloadErrors.removeValue(forKey: model)
        downloadFailureMessages.removeValue(forKey: model)
        downloadStates[model] = .downloading(startedAt: startedAt, progress: 0)
        AppLog.info("Local LLM download manager start model=\(model.repositoryID) cache_path=\(model.cacheURL?.path ?? "none") cache_exists=\(model.cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")

        let download = download
        let validateDownloadedModel = validateDownloadedModel
        let task = Task { [weak self, download, downloadID] in
            guard let manager = self else { return }
            do {
                let progressHandler: ProgressHandler = { [weak manager] progress in
                    manager?.updateDownloadProgress(model, id: downloadID, progress: progress)
                }
                try await download(model, progressHandler)
                try Task.checkCancellation()
                let isDownloaded = validateDownloadedModel(model)
                guard isDownloaded else {
                    throw LocalLLMDownloadManagerError.downloadedModelUnavailable(model)
                }
                await MainActor.run {
                    manager.finishDownload(model, id: downloadID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    manager.clearDownload(model, id: downloadID)
                }
            } catch {
                await MainActor.run {
                    manager.failDownload(model, error: error, id: downloadID)
                }
            }
        }
        tasks[model] = DownloadTask(
            id: downloadID,
            task: task,
            lastProgressAt: startedAt,
            lastPublishedProgressAt: startedAt
        )
        startProgressStallMonitor(model, id: downloadID)
    }

    func cancelDownload(_ model: LocalLLMModel) {
        AppLog.info("Local LLM download manager cancel model=\(model.repositoryID)")
        tasks[model]?.task.cancel()
        clearDownload(model)
    }

    func clearError(_ model: LocalLLMModel) {
        downloadErrors.removeValue(forKey: model)
    }

    private func finishDownload(_ model: LocalLLMModel, id: UUID) {
        guard isCurrentTask(for: model, id: id) else { return }
        let durationMilliseconds = millisecondsSinceDownloadStarted(for: model)
        removeTask(for: model)
        downloadErrors.removeValue(forKey: model)
        downloadFailureMessages.removeValue(forKey: model)
        downloadStates.removeValue(forKey: model)
        AppLog.info("Local LLM download manager finish model=\(model.repositoryID) downloaded=\(model.isDownloaded) duration_ms=\(durationMilliseconds) cache_path=\(model.cacheURL?.path ?? "none") cache_exists=\(model.cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
    }

    private func failDownload(_ model: LocalLLMModel, error: Error, id: UUID) {
        guard isCurrentTask(for: model, id: id) else { return }
        let durationMilliseconds = millisecondsSinceDownloadStarted(for: model)
        removeTask(for: model)
        let message = error.localizedDescription
        downloadErrors[model] = message
        downloadFailureMessages[model] = message
        downloadStates[model] = .failed(message: message)
        AppLog.error("Local LLM download manager fail model=\(model.repositoryID) downloaded=\(model.isDownloaded) duration_ms=\(durationMilliseconds) cache_path=\(model.cacheURL?.path ?? "none") cache_exists=\(model.cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) error=\(message)")
    }

    private func clearDownload(_ model: LocalLLMModel, id: UUID) {
        guard isCurrentTask(for: model, id: id) else { return }
        clearDownload(model)
    }

    private func clearDownload(_ model: LocalLLMModel) {
        removeTask(for: model)
        downloadErrors.removeValue(forKey: model)
        downloadFailureMessages.removeValue(forKey: model)
        downloadStates.removeValue(forKey: model)
    }

    private func removeTask(for model: LocalLLMModel) {
        let removedTask = tasks.removeValue(forKey: model)
        removedTask?.monitorTask?.cancel()
    }

    private func isCurrentTask(for model: LocalLLMModel, id: UUID) -> Bool {
        tasks[model]?.id == id
    }

    private func startProgressStallMonitor(_ model: LocalLLMModel, id: UUID) {
        guard let progressStallTimeout else { return }
        let interval = min(progressStallCheckInterval, max(0.25, progressStallTimeout / 4))
        let nanoseconds = UInt64((interval * 1_000_000_000).rounded())
        let monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                self?.failDownloadIfProgressStalled(model, id: id)
            }
        }
        tasks[model]?.monitorTask = monitorTask
    }

    private func failDownloadIfProgressStalled(_ model: LocalLLMModel, id: UUID) {
        guard let progressStallTimeout,
              isCurrentTask(for: model, id: id),
              let task = tasks[model],
              case .downloading(_, let progress) = downloadStates[model],
              progress < 1
        else {
            return
        }
        guard now() - task.lastProgressAt >= progressStallTimeout else { return }
        task.task.cancel()
        failDownload(model, error: LocalLLMDownloadManagerError.progressStalled(progressStallTimeout), id: id)
    }

    private func updateDownloadProgress(_ model: LocalLLMModel, id: UUID, progress: Double) {
        guard isCurrentTask(for: model, id: id),
              case .downloading(let startedAt, let currentProgress) = downloadStates[model]
        else {
            return
        }
        let clampedProgress = max(0, min(1, progress))
        guard clampedProgress > currentProgress else { return }
        let updatedAt = now()
        let lastPublishedAt = tasks[model]?.lastPublishedProgressAt ?? updatedAt
        let shouldPublish = clampedProgress >= 1
            || clampedProgress - currentProgress >= 0.001
            || updatedAt - lastPublishedAt >= 0.25

        tasks[model]?.lastProgressAt = updatedAt
        guard shouldPublish else { return }
        if clampedProgress > currentProgress {
            tasks[model]?.lastPublishedProgressAt = updatedAt
        }
        downloadStates[model] = .downloading(startedAt: startedAt, progress: clampedProgress)
    }

    private func downloadStartedAt(for model: LocalLLMModel) -> TimeInterval? {
        guard case .downloading(let startedAt, _) = downloadStates[model] else {
            return nil
        }
        return startedAt
    }

    private func millisecondsSinceDownloadStarted(for model: LocalLLMModel) -> Int {
        guard let startedAt = downloadStartedAt(for: model) else { return 0 }
        return Int(((now() - startedAt) * 1_000).rounded())
    }
}
