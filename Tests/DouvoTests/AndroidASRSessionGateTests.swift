import Foundation
import XCTest
@testable import Douvo

final class AndroidASRSessionGateTests: XCTestCase {
    func testDisconnectSignalWaitsUntilConnectionIsReleased() async {
        let signal = AndroidASRDisconnectSignal()
        signal.reset()
        let state = DisconnectWaitState()

        let waiter = Task {
            await signal.wait()
            state.markResumed()
        }

        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.hasResumed)

        signal.complete()
        await waiter.value
        XCTAssertTrue(state.hasResumed)
    }

    func testGateAllowsOnlyOneActiveAndroidSession() async throws {
        let gate = AndroidASRSessionGate()
        let first = try await gate.acquire()

        do {
            _ = try await gate.acquire()
            XCTFail("Expected active session to reject concurrent acquisition")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "Douvo.AndroidASR")
            XCTAssertEqual(nsError.code, AndroidASRSessionGate.busyErrorCode)
        }

        gate.release(first)
        _ = try await gate.acquire()
    }

    func testGateWaitsAsynchronouslyWhilePreviousConnectionIsClosing() async throws {
        let gate = AndroidASRSessionGate()
        let first = try await gate.acquire()
        gate.beginClosing(first)
        let state = DisconnectWaitState()

        let waiter = Task {
            let lease = try await gate.acquire()
            state.markResumed()
            return lease
        }

        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.hasResumed)

        gate.release(first)
        _ = try await waiter.value
        XCTAssertTrue(state.hasResumed)
    }

    func testGateReturnsToBusyStateWhenFallbackReusesLeaseAfterClose() async throws {
        let gate = AndroidASRSessionGate()
        let lease = try await gate.acquire()
        gate.beginClosing(lease)
        gate.resumeAfterClose(lease)

        do {
            _ = try await gate.acquire()
            XCTFail("Expected retained fallback lease to reject another session")
        } catch {
            XCTAssertEqual((error as NSError).code, AndroidASRSessionGate.busyErrorCode)
        }

        gate.release(lease)
    }

    func testCloseAcknowledgementReleasesSlotOnlyAfterAcknowledgement() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.requestClose(hasTask: true), .sendClose)
        XCTAssertFalse(coordinator.slotReleased)
        XCTAssertEqual(coordinator.receiveCloseAcknowledgement(), .releaseSlot)
        XCTAssertTrue(coordinator.closeAcknowledged)
        XCTAssertTrue(coordinator.slotReleased)
        XCTAssertEqual(coordinator.transportDidComplete(), .none)
    }

    func testUnrequestedCloseIsTerminalFailure() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.receiveCloseAcknowledgement(), .unexpectedClose)
        XCTAssertFalse(coordinator.closeRequested)
        XCTAssertTrue(coordinator.slotReleased)
        XCTAssertEqual(coordinator.transportDidComplete(), .none)
    }

    func testCloseTimeoutForcesTransportShutdownBeforeSlotRelease() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.requestClose(hasTask: true), .sendClose)
        XCTAssertEqual(coordinator.closeAcknowledgementDidTimeOut(), .forceTransportShutdown)
        XCTAssertFalse(coordinator.slotReleased)
        XCTAssertEqual(coordinator.transportDidComplete(), .releaseSlot)
        XCTAssertTrue(coordinator.slotReleased)
    }

    func testTransportCompletionBeforeCloseAcknowledgementDoesNotReleaseSlot() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.requestClose(hasTask: true), .sendClose)
        XCTAssertEqual(coordinator.transportDidComplete(), .none)
        XCTAssertFalse(coordinator.slotReleased)
        XCTAssertEqual(coordinator.receiveCloseAcknowledgement(), .releaseSlot)
    }

    func testUnrequestedTransportCompletionIsTerminalFailure() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.transportDidComplete(), .unexpectedClose)
        XCTAssertFalse(coordinator.closeRequested)
        XCTAssertTrue(coordinator.slotReleased)
    }

    func testCloseWithoutTaskReleasesSlotImmediately() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.requestClose(hasTask: false), .releaseSlot)
        XCTAssertTrue(coordinator.slotReleased)
    }

    func testQuotaFallbackStartsOnlyAfterAcknowledgedClose() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")

        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .closeThenRetry
        )
        XCTAssertTrue(coordinator.isRetryPending)
        XCTAssertFalse(coordinator.fallbackUsed)
        XCTAssertEqual(
            coordinator.transportDidRelease(closeAcknowledged: true),
            AndroidASRAppKeyFallbackCoordinator.fallbackAppKey
        )
        XCTAssertFalse(coordinator.isRetryPending)
        XCTAssertTrue(coordinator.fallbackUsed)
        XCTAssertEqual(coordinator.attempt, .fallback)
    }

    func testQuotaFallbackDoesNotStartWithoutCloseAcknowledgement() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")
        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .closeThenRetry
        )

        XCTAssertNil(coordinator.transportDidRelease(closeAcknowledged: false))
        XCTAssertFalse(coordinator.fallbackUsed)
    }

    func testQuotaFallbackRunsAtMostOnce() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")
        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .closeThenRetry
        )
        _ = coordinator.transportDidRelease(closeAcknowledged: true)

        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .reportFailure
        )
        XCTAssertNil(coordinator.transportDidRelease(closeAcknowledged: true))
    }

    func testQuotaFallbackSkipsWhenPrimaryAlreadyUsesFallbackKey() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: AndroidASRAppKeyFallbackCoordinator.fallbackAppKey)

        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .reportFailure
        )
    }

    func testQuotaFallbackDoesNotRunAfterSessionHasOpened() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")

        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: false
            ),
            .reportFailure
        )
    }

    func testNonQuotaServerErrorDoesNotTriggerFallback() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")

        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: 40_000_000,
                message: "no access right",
                sessionIsConnecting: true
            ),
            .reportFailure
        )
    }

    func testQuotaFallbackCanBeCancelledWhileSocketIsClosing() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")
        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .closeThenRetry
        )

        coordinator.cancel()

        XCTAssertFalse(coordinator.isRetryPending)
        XCTAssertNil(coordinator.transportDidRelease(closeAcknowledged: true))
        XCTAssertFalse(coordinator.canStartFallback)
    }

    func testFallbackRetryRemainsPendingWhileOldSocketCloses() {
        var coordinator = AndroidASRAppKeyFallbackCoordinator()
        coordinator.reset(primaryAppKey: "RTIHIRzbwS")

        XCTAssertEqual(
            coordinator.receiveServerError(
                statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
                message: "concurrency quota exceeded",
                sessionIsConnecting: true
            ),
            .closeThenRetry
        )

        XCTAssertTrue(coordinator.isRetryPending)
    }

    func testLateCloseTimeoutDoesNothingAfterAcknowledgement() {
        var coordinator = AndroidASRSocketCloseCoordinator()

        XCTAssertEqual(coordinator.requestClose(hasTask: true), .sendClose)
        XCTAssertEqual(coordinator.receiveCloseAcknowledgement(), .releaseSlot)

        XCTAssertEqual(coordinator.closeAcknowledgementDidTimeOut(), .none)
    }
}

private final class DisconnectWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    var hasResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    func markResumed() {
        lock.lock()
        resumed = true
        lock.unlock()
    }
}
