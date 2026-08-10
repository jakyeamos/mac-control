import XCTest
@testable import MacCtlCore

final class DaemonLifecycleInterlockTests: XCTestCase {
    func testAtomicDrainIsPreferred() throws {
        let interlock = DaemonLifecycleInterlock(send: { request in
            XCTAssertEqual(request.method, "daemon.lifecycle.prepare")
            return ResponseEnvelope(requestID: request.requestID, status: .succeeded)
        })
        let result = try interlock.prepare(
            operation: .restart,
            launchAgentStatus: .unavailable()
        )
        XCTAssertEqual(result.mode, .atomicDrain)
    }

    func testDaemonBlockerIsPreserved() {
        let interlock = DaemonLifecycleInterlock(send: { request in
            ResponseEnvelope(
                requestID: request.requestID,
                status: .blocked,
                error: MacCtlError(
                    code: MacCtlErrorCode.daemonLifecycleBlocked.rawValue,
                    message: "active authority"
                )
            )
        })
        XCTAssertThrowsError(try interlock.prepare(
            operation: .upgrade,
            launchAgentStatus: .unavailable()
        )) { error in
            guard case LaunchAgentError.lifecycleBlocked(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "active authority")
        }
    }

    func testLegacyDaemonAllowsOnlyAnIdleSnapshot() throws {
        let snapshot = ControlCenterSnapshot(approvals: [], execution: nil, permissions: [])
        let interlock = DaemonLifecycleInterlock(allowLegacyIdleSnapshot: true, send: { request in
            if request.method == "daemon.lifecycle.prepare" {
                return ResponseEnvelope(
                    requestID: request.requestID,
                    status: .failed,
                    error: MacCtlError(
                        code: MacCtlErrorCode.unsupportedMethod.rawValue,
                        message: "unsupported"
                    )
                )
            }
            return ResponseEnvelope(
                requestID: request.requestID,
                status: .succeeded,
                result: try JSONValue.fromEncodable(snapshot)
            )
        })
        let result = try interlock.prepare(
            operation: .upgrade,
            launchAgentStatus: .unavailable()
        )
        XCTAssertEqual(result.mode, .legacyIdleSnapshot)
    }

    func testLegacySnapshotRequiresExplicitOneTimeMigrationFlag() {
        let interlock = DaemonLifecycleInterlock(send: { request in
            ResponseEnvelope(
                requestID: request.requestID,
                status: .failed,
                error: MacCtlError(
                    code: MacCtlErrorCode.unsupportedMethod.rawValue,
                    message: "unsupported"
                )
            )
        })
        XCTAssertThrowsError(try interlock.prepare(
            operation: .upgrade,
            launchAgentStatus: .unavailable()
        )) { error in
            guard case LaunchAgentError.lifecycleInterlockUnavailable(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("--allow-legacy-idle-snapshot"))
        }
    }

    func testLegacyDaemonSnapshotBlocksPendingApproval() throws {
        let record = ApprovalRecord(
            token: "must-not-escape",
            operationID: "operation",
            workflowID: "workflow",
            summary: "Pending",
            risk: .sensitive,
            focusPolicy: .foreground,
            expiresAt: Date().addingTimeInterval(60)
        )
        let snapshot = ControlCenterSnapshot(
            approvals: [ControlCenterApproval(record: record)],
            execution: nil,
            permissions: []
        )
        let interlock = DaemonLifecycleInterlock(allowLegacyIdleSnapshot: true, send: { request in
            if request.method == "daemon.lifecycle.prepare" {
                return ResponseEnvelope(
                    requestID: request.requestID,
                    status: .failed,
                    error: MacCtlError(
                        code: MacCtlErrorCode.unsupportedMethod.rawValue,
                        message: "unsupported"
                    )
                )
            }
            return ResponseEnvelope(
                requestID: request.requestID,
                status: .succeeded,
                result: try JSONValue.fromEncodable(snapshot)
            )
        })
        XCTAssertThrowsError(try interlock.prepare(
            operation: .restart,
            launchAgentStatus: .unavailable()
        )) { error in
            guard case LaunchAgentError.lifecycleBlocked(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(message.contains(record.token))
        }
    }

    func testUnavailableSocketFailsClosedOnlyForHealthyDaemon() throws {
        let interlock = DaemonLifecycleInterlock(send: { _ in
            throw UnixSocketError.connectFailed("offline")
        })
        let recovery = try interlock.prepare(
            operation: .restart,
            launchAgentStatus: .unavailable()
        )
        XCTAssertEqual(recovery.mode, .unhealthyRecovery)

        let healthy = LaunchAgentStatus(
            plistPath: "/tmp/agent.plist",
            installed: true,
            launchdLoaded: true,
            loaded: true,
            healthy: true,
            processID: 42,
            identityMatches: true
        )
        XCTAssertThrowsError(try interlock.prepare(
            operation: .restart,
            launchAgentStatus: healthy
        )) { error in
            guard case LaunchAgentError.lifecycleInterlockUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
