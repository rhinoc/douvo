import XCTest
@testable import Douvo

@MainActor
final class LocalLLMDownloadManagerTests: XCTestCase {
    func testBuiltInMLXRepositoryIDsCanBeParsedForDownloads() {
        XCTAssertNotNil(LocalLLMModel.hubRepoID(from: "mlx-community/Qwen3.5-0.8B-MLX-4bit"))
        XCTAssertNotNil(LocalLLMModel.hubRepoID(from: "mlx-community/Qwen3.5-0.8B-8bit"))
        XCTAssertNil(LocalLLMModel.hubRepoID(from: "missing-namespace"))
    }

    func testDownloadSnapshotPatternsIncludeCommonTokenizerAssets() {
        let patterns = Set(LocalLLMModel.downloadSnapshotFilePatterns)

        XCTAssertTrue(patterns.contains("*.safetensors"))
        XCTAssertTrue(patterns.contains("*.json"))
        XCTAssertTrue(patterns.contains("tokenizer.model"))
        XCTAssertTrue(patterns.contains("merges.txt"))
        XCTAssertTrue(patterns.contains("vocab.txt"))
    }

    func testDifferentModelsCanDownloadAtTheSameTime() async throws {
        let probe = DownloadProbe()
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { model in
            await probe.markStarted(model)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        defer {
            manager.cancelDownload(.light)
            manager.cancelDownload(.quality)
        }

        manager.startDownload(.light)
        manager.startDownload(.quality)
        await probe.waitForStartedCount(2)

        XCTAssertTrue(manager.isDownloading(.light))
        XCTAssertTrue(manager.isDownloading(.quality))
        XCTAssertEqual(manager.activeDownloadCount, 2)
        guard case .downloading? = manager.downloadStates[.light] else {
            return XCTFail("Expected light model to stay in downloading state")
        }
    }

    func testStartingSameModelTwiceReusesExistingDownload() async throws {
        let probe = DownloadProbe()
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { model in
            await probe.markStarted(model)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        defer {
            manager.cancelDownload(.light)
        }

        manager.startDownload(.light)
        manager.startDownload(.light)
        await probe.waitForStartedCount(1)
        let startedModels = await probe.startedModels()

        XCTAssertTrue(manager.isDownloading(.light))
        XCTAssertEqual(manager.activeDownloadCount, 1)
        XCTAssertEqual(startedModels, [.light])
    }

    func testStaleCancelledDownloadCannotClearRestartedDownload() async throws {
        let releaseFirst = ReleaseGate()
        let probe = DownloadProbe()
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { model in
            await probe.markStarted(model)
            if await probe.startedCount == 1 {
                await releaseFirst.wait()
            } else {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        defer {
            manager.cancelDownload(.light)
        }

        manager.startDownload(.light)
        await probe.waitForStartedCount(1)
        manager.cancelDownload(.light)
        manager.startDownload(.light)
        await probe.waitForStartedCount(2)
        await releaseFirst.release()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(manager.isDownloading(.light))
        XCTAssertEqual(manager.activeDownloadCount, 1)
    }

    func testDownloadErrorCanBeConsumed() async throws {
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { _ in
            throw NSError(domain: "test", code: 7)
        }

        manager.startDownload(.light)
        while manager.isDownloading(.light) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNotNil(manager.downloadErrors[.light])
        XCTAssertNotNil(manager.downloadFailureMessages[.light])
        manager.clearError(.light)
        XCTAssertNil(manager.downloadErrors[.light])
        XCTAssertNotNil(manager.downloadFailureMessages[.light])
    }

    func testDownloadStaysInDownloadingStateUntilOperationFinishes() async throws {
        let clock = TestClock(10)
        let release = ReleaseGate()
        let manager = LocalLLMDownloadManager(
            now: { clock.value },
            validateDownloadedModel: { _ in false }
        ) { _ in
            await release.wait()
        }

        manager.startDownload(.light)

        guard case .downloading(let startedAt)? = manager.downloadStates[.light] else {
            return XCTFail("Expected downloading state")
        }
        XCTAssertEqual(startedAt, 10)
        XCTAssertTrue(manager.isDownloading(.light))

        manager.cancelDownload(.light)
        await release.release()
    }

    func testAlreadyDownloadedModelDoesNotStartDownloadTask() async throws {
        let probe = DownloadProbe()
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in true }) { model in
            await probe.markStarted(model)
        }

        manager.startDownload(.light)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(manager.isDownloading(.light))
        XCTAssertEqual(manager.activeDownloadCount, 0)
        XCTAssertNil(manager.downloadStates[.light])
        let startedCount = await probe.startedCount
        XCTAssertEqual(startedCount, 0)
    }

    func testDownloadThatDoesNotProduceUsableModelReportsError() async throws {
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { _ in }

        manager.startDownload(.light)
        while manager.isDownloading(.light) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNotNil(manager.downloadErrors[.light])
        XCTAssertNotNil(manager.downloadFailureMessages[.light])
        guard case .failed(let message)? = manager.downloadStates[.light] else {
            return XCTFail("Expected validation failure to leave a persistent failed state")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testRetryClearsPreviousDownloadFailure() async throws {
        let release = ReleaseGate()
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { _ in
            await release.wait()
        }

        manager.startDownload(.light)
        await release.release()
        while manager.isDownloading(.light) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(manager.downloadFailureMessages[.light])

        manager.startDownload(.light)

        XCTAssertNil(manager.downloadFailureMessages[.light])
        guard case .downloading? = manager.downloadStates[.light] else {
            return XCTFail("Expected retry to re-enter downloading state")
        }
        manager.cancelDownload(.light)
    }

    func testCancelClearsDownloadState() async throws {
        let release = ReleaseGate()
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in false }) { _ in
            await release.wait()
        }

        manager.startDownload(.light)
        guard case .downloading? = manager.downloadStates[.light] else {
            return XCTFail("Expected active download state")
        }

        manager.cancelDownload(.light)

        XCTAssertNil(manager.downloadStates[.light])
        await release.release()
    }

    func testSuccessClearsDownloadStateAndFailure() async throws {
        let shouldValidate = TestFlag(false)
        let manager = LocalLLMDownloadManager(validateDownloadedModel: { _ in shouldValidate.value }) { _ in }

        manager.startDownload(.light)
        while manager.isDownloading(.light) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(manager.downloadStates[.light])

        shouldValidate.value = true
        manager.startDownload(.light)
        while manager.isDownloading(.light) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(manager.downloadStates[.light])
        XCTAssertNil(manager.downloadFailureMessages[.light])
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval

    init(_ value: TimeInterval) {
        storedValue = value
    }

    var value: TimeInterval {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock {
                storedValue = newValue
            }
        }
    }
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock {
                storedValue = newValue
            }
        }
    }
}

private actor DownloadProbe {
    private var models: [LocalLLMModel] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func startedModels() -> [LocalLLMModel] {
        models
    }

    func markStarted(_ model: LocalLLMModel) {
        models.append(model)
        resumeReadyWaiters()
    }

    func waitForStartedCount(_ count: Int) async {
        if models.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
            resumeReadyWaiters()
        }
    }

    var startedCount: Int {
        models.count
    }

    private func resumeReadyWaiters() {
        let ready = waiters.filter { models.count >= $0.0 }
        waiters.removeAll { models.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor ReleaseGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
