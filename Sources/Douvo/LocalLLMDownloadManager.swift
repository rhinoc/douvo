import Combine
import Foundation

enum LocalLLMDownloadState: Equatable, Sendable {
    case downloading(startedAt: TimeInterval)
    case failed(message: String)
}

enum LocalLLMDownloadManagerError: LocalizedError {
    case downloadedModelUnavailable(LocalLLMModel)

    var errorDescription: String? {
        switch self {
        case .downloadedModelUnavailable(let model):
            "Downloaded files for \(model.displayName) are not usable yet. Please try again."
        }
    }
}

@MainActor
final class LocalLLMDownloadManager: ObservableObject, @unchecked Sendable {
    typealias DownloadOperation = @Sendable (LocalLLMModel) async throws -> Void

    @Published private(set) var downloadErrors: [LocalLLMModel: String] = [:]
    @Published private(set) var downloadFailureMessages: [LocalLLMModel: String] = [:]
    @Published private(set) var downloadStates: [LocalLLMModel: LocalLLMDownloadState] = [:]

    private let download: DownloadOperation
    private let now: @Sendable () -> TimeInterval
    private let validateDownloadedModel: @Sendable (LocalLLMModel) -> Bool
    private var tasks: [LocalLLMModel: DownloadTask] = [:]

    private struct DownloadTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    init(
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        validateDownloadedModel: @escaping @Sendable (LocalLLMModel) -> Bool = { $0.isDownloaded },
        download: @escaping DownloadOperation
    ) {
        self.now = now
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
        downloadStates[model] = .downloading(startedAt: startedAt)
        AppLog.info("Local LLM download manager start model=\(model.repositoryID) cache_path=\(model.cacheURL?.path ?? "none") cache_exists=\(model.cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")

        let download = download
        let validateDownloadedModel = validateDownloadedModel
        let task = Task { [weak self, download, downloadID] in
            guard let manager = self else { return }
            do {
                try await download(model)
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
        tasks[model] = DownloadTask(id: downloadID, task: task)
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
        tasks.removeValue(forKey: model)
        downloadErrors.removeValue(forKey: model)
        downloadFailureMessages.removeValue(forKey: model)
        downloadStates.removeValue(forKey: model)
        AppLog.info("Local LLM download manager finish model=\(model.repositoryID) downloaded=\(model.isDownloaded) duration_ms=\(durationMilliseconds) cache_path=\(model.cacheURL?.path ?? "none") cache_exists=\(model.cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
    }

    private func failDownload(_ model: LocalLLMModel, error: Error, id: UUID) {
        guard isCurrentTask(for: model, id: id) else { return }
        let durationMilliseconds = millisecondsSinceDownloadStarted(for: model)
        tasks.removeValue(forKey: model)
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
        tasks.removeValue(forKey: model)
        downloadErrors.removeValue(forKey: model)
        downloadFailureMessages.removeValue(forKey: model)
        downloadStates.removeValue(forKey: model)
    }

    private func isCurrentTask(for model: LocalLLMModel, id: UUID) -> Bool {
        tasks[model]?.id == id
    }

    private func downloadStartedAt(for model: LocalLLMModel) -> TimeInterval? {
        guard case .downloading(let startedAt) = downloadStates[model] else {
            return nil
        }
        return startedAt
    }

    private func millisecondsSinceDownloadStarted(for model: LocalLLMModel) -> Int {
        guard let startedAt = downloadStartedAt(for: model) else { return 0 }
        return Int(((now() - startedAt) * 1_000).rounded())
    }
}
