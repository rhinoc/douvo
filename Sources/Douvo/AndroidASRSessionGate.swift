import Foundation

final class AndroidASRDisconnectSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func reset() {
        lock.lock()
        isComplete = false
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isComplete {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func complete() {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()

        waiters.forEach { $0.resume() }
    }
}

final class AndroidASRSessionGate: @unchecked Sendable {
    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
    }

    static let shared = AndroidASRSessionGate()
    static let busyErrorCode = 4

    private let lock = NSLock()
    private var activeLeaseID: UUID?
    private var isClosing = false

    func acquire() async throws -> Lease {
        while true {
            try Task.checkCancellation()
            let attempt = lock.withLock { () -> (lease: Lease?, shouldWait: Bool) in
                if activeLeaseID == nil {
                    let lease = Lease(id: UUID())
                    activeLeaseID = lease.id
                    isClosing = false
                    return (lease, false)
                }
                return (nil, isClosing)
            }
            if let lease = attempt.lease { return lease }

            guard attempt.shouldWait else {
                throw NSError(
                    domain: "Douvo.AndroidASR",
                    code: Self.busyErrorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Another Android recognition session is still active"
                    ]
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func beginClosing(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeaseID == lease.id else { return }
        isClosing = true
    }

    func resumeAfterClose(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeaseID == lease.id else { return }
        isClosing = false
    }

    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeaseID == lease.id else { return }
        activeLeaseID = nil
        isClosing = false
    }
}

enum AndroidASRSocketCloseAction: Equatable {
    case none
    case sendClose
    case forceTransportShutdown
    case releaseSlot
    case unexpectedClose
}

struct AndroidASRSocketCloseCoordinator {
    private(set) var closeRequested = false
    private(set) var closeAcknowledged = false
    private(set) var forcedTransportShutdown = false
    private(set) var slotReleased = false

    mutating func requestClose(hasTask: Bool) -> AndroidASRSocketCloseAction {
        guard !closeRequested, !slotReleased else { return .none }
        closeRequested = true
        guard hasTask else {
            slotReleased = true
            return .releaseSlot
        }
        return .sendClose
    }

    mutating func receiveCloseAcknowledgement() -> AndroidASRSocketCloseAction {
        guard !slotReleased else { return .none }
        guard closeRequested else {
            slotReleased = true
            return .unexpectedClose
        }
        closeRequested = true
        closeAcknowledged = true
        slotReleased = true
        return .releaseSlot
    }

    mutating func closeAcknowledgementDidTimeOut() -> AndroidASRSocketCloseAction {
        guard closeRequested, !closeAcknowledged, !slotReleased else { return .none }
        forcedTransportShutdown = true
        return .forceTransportShutdown
    }

    mutating func transportDidComplete() -> AndroidASRSocketCloseAction {
        guard !slotReleased else { return .none }
        guard closeRequested else {
            slotReleased = true
            return .unexpectedClose
        }
        guard closeAcknowledged || forcedTransportShutdown else {
            return .none
        }
        slotReleased = true
        return .releaseSlot
    }
}

enum AndroidASRAppKeyAttempt: String, Equatable {
    case primary
    case fallback
}

enum AndroidASRAppKeyFallbackAction: Equatable {
    case reportFailure
    case closeThenRetry
}

struct AndroidASRAppKeyFallbackCoordinator {
    static let fallbackAppKey = "OrnqKvSSrs"

    private(set) var attempt: AndroidASRAppKeyAttempt = .primary
    private(set) var fallbackUsed = false
    private(set) var triggerStatusCode: Int?
    private var primaryAppKey = ""
    private var retryPending = false
    private var isCancelled = false

    mutating func reset(primaryAppKey: String) {
        attempt = .primary
        fallbackUsed = false
        triggerStatusCode = nil
        self.primaryAppKey = primaryAppKey
        retryPending = false
        isCancelled = false
    }

    mutating func receiveServerError(
        statusCode: Int,
        message: String,
        sessionIsConnecting: Bool
    ) -> AndroidASRAppKeyFallbackAction {
        guard sessionIsConnecting,
              attempt == .primary,
              primaryAppKey != Self.fallbackAppKey,
              AndroidASRErrorClassifier.isConcurrencyQuotaExceeded(
                  statusCode: statusCode,
                  message: message
              ) else {
            return .reportFailure
        }

        retryPending = true
        triggerStatusCode = statusCode
        return .closeThenRetry
    }

    mutating func transportDidRelease(closeAcknowledged: Bool) -> String? {
        guard retryPending, closeAcknowledged, !isCancelled else {
            retryPending = false
            return nil
        }
        retryPending = false
        fallbackUsed = true
        attempt = .fallback
        return Self.fallbackAppKey
    }

    mutating func cancel() {
        retryPending = false
        isCancelled = true
    }

    var isRetryPending: Bool {
        retryPending && !isCancelled
    }

    var canStartFallback: Bool {
        fallbackUsed && attempt == .fallback && !isCancelled
    }
}
