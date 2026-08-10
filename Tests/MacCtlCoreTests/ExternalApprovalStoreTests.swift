import Foundation
import XCTest
@testable import MacCtlCore

final class ExternalApprovalStoreTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testExternalApprovalIsDigestBoundShortLivedAndSingleUse() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let store = ExternalApprovalStore(lifetime: 120, now: { now })
        let prepared = store.prepare(
            provider: "browser_control",
            providerInstanceID: "profile_test",
            planID: "plan_test",
            planDigest: digest,
            summary: "Group three tabs",
            risk: .reversible
        )

        XCTAssertEqual(prepared.state, .pending)
        XCTAssertEqual(prepared.record.provider, "browser_control")
        XCTAssertEqual(prepared.record.planDigest, digest)
        XCTAssertEqual(prepared.record.expiresAt.timeIntervalSince(now), 120, accuracy: 0.001)
        XCTAssertTrue(prepared.record.token.hasPrefix("mce_"))

        _ = try store.approve(token: prepared.record.token)
        XCTAssertThrowsError(try store.consume(
            operationID: prepared.record.operationID,
            provider: "browser_control",
            providerInstanceID: "profile_test",
            planID: "plan_test",
            planDigest: String(repeating: "b", count: 64)
        )) { XCTAssertEqual($0 as? ExternalApprovalStoreError, .mismatch) }

        let consumed = try store.consume(
            operationID: prepared.record.operationID,
            provider: "browser_control",
            providerInstanceID: "profile_test",
            planID: "plan_test",
            planDigest: digest
        )
        XCTAssertEqual(consumed.state, .consumed)
        XCTAssertThrowsError(try store.consume(
            operationID: prepared.record.operationID,
            provider: "browser_control",
            providerInstanceID: "profile_test",
            planID: "plan_test",
            planDigest: digest
        )) { XCTAssertEqual($0 as? ExternalApprovalStoreError, .alreadyUsed) }

        let expiring = store.prepare(
            provider: "browser_control",
            providerInstanceID: "profile_test",
            planID: "plan_expiring",
            planDigest: digest,
            summary: "Navigate one tab",
            risk: .sensitive
        )
        now = now.addingTimeInterval(121)
        XCTAssertThrowsError(try store.approve(token: expiring.record.token)) {
            XCTAssertEqual($0 as? ExternalApprovalStoreError, .expired)
        }
    }

    func testServiceProjectsExternalApprovalWithoutExposingControlCenterToken() throws {
        let store = ExternalApprovalStore()
        let service = MacCtlService(permissionContext: "test", externalApprovalStore: store)
        let prepared = service.handle(RequestEnvelope(
            method: "approval.external.prepare",
            params: [
                "provider": .string("browser_control"),
                "provider_instance_id": .string("profile_test"),
                "plan_id": .string("plan_test"),
                "plan_digest": .string(digest),
                "summary": .string("Create a Resume group for three tabs"),
                "risk": .string("reversible")
            ]
        ))

        XCTAssertEqual(prepared.status, .prepared)
        XCTAssertEqual(prepared.result["state"]?.stringValue, "pending")
        XCTAssertNil(prepared.result["token"])
        let record = try XCTUnwrap(service.pendingApprovalRecords().first)
        XCTAssertEqual(record.provider, "browser_control")
        XCTAssertEqual(record.planDigest, digest)
        let projected = try XCTUnwrap(service.controlCenterSnapshot().approvals.first)
        XCTAssertEqual(projected.provider, "browser_control")
        XCTAssertEqual(projected.planDigest, digest)

        let pendingStatus = service.handle(RequestEnvelope(
            method: "approval.external.status",
            params: ["operation_id": .string(record.operationID)]
        ))
        XCTAssertEqual(pendingStatus.status, .prepared)
        XCTAssertEqual(pendingStatus.result["state"]?.stringValue, "pending")

        let approved = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(record.token), "source": .string("control_center")]
        ))
        XCTAssertEqual(approved.status, .succeeded)
        XCTAssertNil(approved.result["token"])

        let consumed = service.handle(RequestEnvelope(
            method: "approval.external.consume",
            params: [
                "operation_id": .string(record.operationID),
                "provider": .string("browser_control"),
                "provider_instance_id": .string("profile_test"),
                "plan_id": .string("plan_test"),
                "plan_digest": .string(digest)
            ]
        ))
        XCTAssertEqual(consumed.status, .succeeded)
        XCTAssertEqual(consumed.result["state"]?.stringValue, "consumed")
        XCTAssertNil(consumed.result["token"])

        let replay = service.handle(RequestEnvelope(
            method: "approval.external.consume",
            params: [
                "operation_id": .string(record.operationID),
                "provider": .string("browser_control"),
                "provider_instance_id": .string("profile_test"),
                "plan_id": .string("plan_test"),
                "plan_digest": .string(digest)
            ]
        ))
        XCTAssertEqual(replay.status, .blocked)
        XCTAssertEqual(replay.error?.code, MacCtlErrorCode.approvalAlreadyUsed.rawValue)
    }

    func testDeniedExternalApprovalCannotBeConsumed() throws {
        let store = ExternalApprovalStore()
        let service = MacCtlService(permissionContext: "test", externalApprovalStore: store)
        _ = service.handle(RequestEnvelope(
            method: "approval.external.prepare",
            params: [
                "provider": .string("browser_control"),
                "provider_instance_id": .string("profile_test"),
                "plan_id": .string("plan_denied"),
                "plan_digest": .string(digest),
                "summary": .string("Move one tab"),
                "risk": .string("reversible")
            ]
        ))
        let record = try XCTUnwrap(service.pendingApprovalRecords().first)
        let denied = service.handle(RequestEnvelope(
            method: "approval.deny",
            params: ["token": .string(record.token), "source": .string("control_center")]
        ))
        XCTAssertEqual(denied.status, .succeeded)

        let consume = service.handle(RequestEnvelope(
            method: "approval.external.consume",
            params: [
                "operation_id": .string(record.operationID),
                "provider": .string("browser_control"),
                "provider_instance_id": .string("profile_test"),
                "plan_id": .string("plan_denied"),
                "plan_digest": .string(digest)
            ]
        ))
        XCTAssertEqual(consume.status, .denied)
    }
}
