import Foundation
import XCTest
@testable import MacCtlCore

final class AuthorizationNoticeTests: XCTestCase {
    func testRequestEnvelopeDoesNotSerializeTransportIdentity() throws {
        let request = RequestEnvelope(
            requestID: "wire-request",
            method: "control.authorization.list",
            transportPeerIdentity: UnixSocketPeerIdentity(
                userID: 501,
                processID: 42,
                executablePath: "/usr/local/bin/macctl"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONCodec.encode(request)) as? [String: Any]
        )
        XCTAssertNil(object["transport_peer_identity"])
        XCTAssertNil(object["peer_identity"])
        XCTAssertEqual(request.withTransportPeerIdentity(nil).transportPeerIdentity, nil)
    }

    func testStoreRedactsSensitiveSummaryAndRejectsUnallowlistedSource() throws {
        let store = AuthorizationNoticeStore()
        let request = AuthorizationNoticeRequest(
            kind: .credential,
            project: "Pronto",
            sourceReference: "codex://thread/abc-123",
            requestingExecutable: "/usr/local/bin/macctl",
            targetService: "github.com",
            action: "read credential",
            summary: "git credential fill token=super-secret-value"
        )

        let prepared = try store.prepare(
            request,
            observedPeer: UnixSocketPeerIdentity(
                processID: 12,
                executablePath: "/usr/local/bin/macctl"
            )
        )
        XCTAssertFalse(prepared.notice.summary.contains("super-secret-value"))
        XCTAssertFalse(prepared.notice.summary.contains("token="))
        XCTAssertEqual(prepared.notice.sourceReference, "codex://thread/abc-123")
        XCTAssertEqual(prepared.notice.provenance, AuthorizationNoticeProvenance.attested)

        XCTAssertThrowsError(try store.prepare(
            AuthorizationNoticeRequest(
                project: "Pronto",
                sourceReference: "https://example.com/private",
                action: "read credential",
                summary: "safe summary"
            )
        )) { error in
            XCTAssertEqual(error as? AuthorizationNoticeStoreError, .invalidSourceReference)
        }
    }

    func testMissingAndMismatchedPeerIdentityDowngradeProvenance() throws {
        let request = AuthorizationNoticeRequest(
            project: "Project",
            requestingExecutable: "codex",
            action: "read credential",
            summary: "Read credential for github.com"
        )
        let declared = try AuthorizationNoticeStore().prepare(
            request,
            observedPeer: UnixSocketPeerIdentity(processID: 1, executablePath: "/usr/bin/helper")
        )
        XCTAssertEqual(declared.notice.provenance, AuthorizationNoticeProvenance.unverified)

        let noPeer = try AuthorizationNoticeStore().prepare(request)
        XCTAssertEqual(noPeer.notice.provenance, AuthorizationNoticeProvenance.unverified)

        let noDeclaredExecutable = try AuthorizationNoticeStore().prepare(
            AuthorizationNoticeRequest(
                project: "Project",
                action: "read credential",
                summary: "Read credential for github.com"
            ),
            observedPeer: UnixSocketPeerIdentity(processID: 1, executablePath: "/usr/bin/helper")
        )
        XCTAssertEqual(noDeclaredExecutable.notice.provenance, .declared)
    }

    func testDuplicateBindResolveAndReplayAreExplicit() throws {
        let store = AuthorizationNoticeStore()
        let request = AuthorizationNoticeRequest(
            project: "Project",
            threadID: "thread-1",
            requestingExecutable: "macctl",
            action: "read credential",
            summary: "Read credential for github.com"
        )
        let first = try store.prepare(
            request,
            observedPeer: UnixSocketPeerIdentity(processID: 10, executablePath: "/bin/macctl"),
            requestID: "notice-1"
        )
        let duplicate = try store.prepare(
            request,
            observedPeer: UnixSocketPeerIdentity(processID: 10, executablePath: "/bin/macctl"),
            requestID: "notice-2"
        )
        XCTAssertFalse(first.deduplicated)
        XCTAssertTrue(duplicate.deduplicated)
        XCTAssertEqual(duplicate.notice.requestID, "notice-1")

        let bound = try store.bind(requestID: "notice-1", processID: 99)
        XCTAssertEqual(bound.boundProcessID, 99)
        XCTAssertThrowsError(try store.bind(requestID: "notice-1", processID: 100)) { error in
            XCTAssertEqual(error as? AuthorizationNoticeStoreError, .alreadyBound)
        }

        let resolved = try store.resolve(requestID: "notice-1", outcome: .completed)
        XCTAssertEqual(resolved.state, .resolved)
        XCTAssertEqual(resolved.outcome, .completed)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.resolve(requestID: "notice-1", outcome: .failed)) { error in
            XCTAssertEqual(error as? AuthorizationNoticeStoreError, .alreadyResolved)
        }
    }

    func testExpiryIsNotReplayableAsPending() throws {
        final class Clock {
            var date = Date(timeIntervalSince1970: 10_000)
        }
        let clock = Clock()
        let store = AuthorizationNoticeStore(
            defaultTTL: 2,
            maximumTTL: 10,
            now: { clock.date }
        )
        _ = try store.prepare(
            AuthorizationNoticeRequest(
                project: "Project",
                action: "read credential",
                summary: "Read credential",
                expiresIn: 2
            ),
            requestID: "expiring"
        )
        clock.date = clock.date.addingTimeInterval(3)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.resolve(requestID: "expiring", outcome: .timeout)) { error in
            XCTAssertEqual(error as? AuthorizationNoticeStoreError, .expired)
        }
    }

    func testActiveSafetyPresentationOutranksAuthorizationAndDoesNotExposeItsContext() {
        let now = Date(timeIntervalSince1970: 10_000)
        let notice = AuthorizationNotice(
            requestID: "notice",
            kind: .keychain,
            project: "Pronto",
            repository: "github.com/example/pronto",
            taskID: "task-1",
            taskTitle: "Run checks",
            threadID: "thread-1",
            threadTitle: "Fix build",
            sourceReference: "codex://thread/thread-1",
            requestingExecutable: "macctl",
            requestingHelper: "codex",
            targetService: "github.com",
            action: "read credential",
            summary: "Read credential for github.com",
            createdAt: now,
            expiresAt: now.addingTimeInterval(30),
            provenance: .unverified,
            observedIdentity: nil
        )
        let presentation = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: ControlCenterExecution(
                    executionID: "execution",
                    taskID: nil,
                    summary: "Command",
                    applicationName: nil,
                    physicalInputMode: .shared,
                    acquiredAt: now,
                    expiresAt: now.addingTimeInterval(300)
                ),
                permissions: [],
                authorizationNotices: [notice]
            ),
            now: now
        )
        XCTAssertEqual(presentation.state, .leased)
        XCTAssertEqual(presentation.authorizationCount, 1)
        XCTAssertTrue(presentation.showsStatusItem)
        XCTAssertFalse(presentation.tooltip.contains("unverified source"))
        XCTAssertFalse(presentation.tooltip.contains("credential"))
        XCTAssertFalse(presentation.tooltip.contains("Allow"))
        XCTAssertFalse(presentation.tooltip.contains("Deny"))

        let noticeOnly = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: nil,
                permissions: [],
                authorizationNotices: [notice]
            ),
            now: now
        )
        XCTAssertEqual(noticeOnly.state, .authorization)
        XCTAssertFalse(noticeOnly.showsStatusItem)
    }
}
