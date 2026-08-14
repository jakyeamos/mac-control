import Foundation
import XCTest
@testable import MacCtlCore

final class CrossProviderTraceTests: XCTestCase {
    func testJoinedTraceIsRedactedIdempotentAndProvenanceExplicit() throws {
        let root = temporaryDirectory("joined")
        defer { try? FileManager.default.removeItem(at: root) }
        let receiptDirectory = root.appendingPathComponent("receipts", isDirectory: true)
        let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
        let receiptStore = OperationReceiptStore(directory: receiptDirectory)
        let pendingStore = CrossProviderTracePendingStore(directory: pendingDirectory)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MacCtlService(
            receiptStore: receiptStore,
            crossProviderTraceStore: pendingStore,
            permissionContext: "test",
            lifecycleNow: { now }
        )
        let privateSelector = "PRIVATE PAGE TITLE https://example.invalid/account"

        let begin = service.handle(RequestEnvelope(
            requestID: "browser-source-request",
            method: "receipts.trace.begin",
            params: [
                "source_method": .string("control.perform"),
                "source_request_id": .string("browser-control-request"),
                "source_started_at_ms": .number((now.timeIntervalSince1970 - 0.025) * 1_000),
                "app": .string("chrome"),
                "action": .string("click"),
                "target_surface": .string("web_content"),
                "focus_policy": .string("automatic"),
                "task": .string("trace-contract-test"),
                "selector": .object(["title": .string(privateSelector)])
            ]
        ))

        XCTAssertEqual(begin.status, .succeeded)
        let context = try decode(CrossProviderTraceContext.self, from: try XCTUnwrap(begin.result["trace"]))
        XCTAssertEqual(context.provider, "browser_dom")
        XCTAssertEqual(context.provenance, .orchestratorDeclared)
        XCTAssertTrue(context.completionToken.hasPrefix("mctr_"))

        let open = try decode(
            CrossProviderTraceView.self,
            from: service.handle(RequestEnvelope(
                method: "receipts.trace",
                params: ["trace_id": .string(context.traceID)]
            )).result
        )
        XCTAssertEqual(open.state, .open)
        XCTAssertEqual(open.observations.count, 1)
        XCTAssertNil(open.observations[0].targetSurface)
        XCTAssertEqual(open.observations[0].providerTargetSurface, .webContent)
        XCTAssertEqual(open.observations[0].providerProvenance, .macControlAttested)
        XCTAssertEqual(open.observations[0].foregroundState, .preserved)
        XCTAssertEqual(open.metrics.focusInterruptionCount, 0)

        now = now.addingTimeInterval(1.2)
        let completionParams: [String: JSONValue] = [
            "trace_id": .string(context.traceID),
            "completion_token": .string(context.completionToken),
            "provider": .string("browser_dom"),
            "provider_observation_id": .string("RAW-BROWSER-OBSERVATION"),
            "provider_session_id": .string("RAW-BROWSER-SESSION"),
            "provider_turn_id": .string("RAW-BROWSER-TURN"),
            "provider_tab_id": .string("RAW-BROWSER-TAB"),
            "status": .string("verified"),
            "verification_kind": .string("dom_postcondition"),
            "foreground_state": .string("preserved")
        ]
        let completedResponse = service.handle(RequestEnvelope(
            method: "receipts.trace.complete",
            params: completionParams
        ))
        XCTAssertEqual(completedResponse.status, .succeeded)
        let completed = try decode(CrossProviderTraceView.self, from: completedResponse.result)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.observations.count, 2)
        XCTAssertEqual(completed.observations[1].providerProvenance, .orchestratorDeclared)
        XCTAssertEqual(completed.observations[1].providerObservationDigest?.count, 64)
        XCTAssertEqual(completed.metrics.focusInterruptionCount, 0)
        XCTAssertGreaterThanOrEqual(completed.metrics.handoffToCompletionMilliseconds ?? 0, 1_200)

        let duplicate = service.handle(RequestEnvelope(
            method: "receipts.trace.complete",
            params: completionParams
        ))
        XCTAssertEqual(duplicate.status, .succeeded)
        XCTAssertEqual(try receiptStore.trace(context.traceID).count, 2)
        XCTAssertEqual(duplicate.evidence.first?.metadata["duplicate"]?.boolValue, true)

        var mismatchedParams = completionParams
        mismatchedParams["provider_observation_id"] = .string("DIFFERENT-OBSERVATION")
        let mismatch = service.handle(RequestEnvelope(
            method: "receipts.trace.complete",
            params: mismatchedParams
        ))
        XCTAssertEqual(mismatch.status, .blocked)
        XCTAssertEqual(mismatch.error?.code, MacCtlErrorCode.crossProviderTraceMismatch.rawValue)

        var statusReplay = completionParams
        statusReplay["status"] = .string("failed")
        let statusMismatch = service.handle(RequestEnvelope(
            method: "receipts.trace.complete",
            params: statusReplay
        ))
        XCTAssertEqual(statusMismatch.status, .blocked)
        XCTAssertEqual(statusMismatch.error?.code, MacCtlErrorCode.crossProviderTraceMismatch.rawValue)

        let receiptBytes = try serializedFiles(in: receiptDirectory)
        let pendingBytes = try serializedFiles(in: pendingDirectory)
        for forbidden in [
            privateSelector,
            context.completionToken,
            "RAW-BROWSER-OBSERVATION",
            "RAW-BROWSER-SESSION",
            "RAW-BROWSER-TURN",
            "RAW-BROWSER-TAB"
        ] {
            XCTAssertFalse(receiptBytes.contains(forbidden))
            XCTAssertFalse(pendingBytes.contains(forbidden))
        }
        XCTAssertTrue(pendingBytes.contains(CrossProviderCompletionRequest.digest(context.completionToken)))
    }

    func testCompletionSchemaRejectsBrowserContentAndExpiredCredentials() throws {
        let root = temporaryDirectory("completion-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrossProviderTracePendingStore(directory: root)
        let traceID = String(repeating: "a", count: 32)
        let context = try store.prepare(
            traceID: traceID,
            rootSpanID: String(repeating: "b", count: 16),
            rootOperationID: "operation",
            now: Date(timeIntervalSince1970: 100),
            lifetime: 2
        )
        let valid = try CrossProviderCompletionRequest(
            traceID: traceID,
            completionToken: context.completionToken,
            provider: "browser_dom",
            providerObservationID: "observation",
            status: .verified,
            verificationKind: "dom_postcondition"
        )
        XCTAssertThrowsError(try store.complete(valid, now: Date(timeIntervalSince1970: 103))) {
            XCTAssertEqual($0 as? CrossProviderTraceError, .expired)
        }

        var params: [String: JSONValue] = [
            "trace_id": .string(traceID),
            "completion_token": .string(context.completionToken),
            "provider": .string("browser_dom"),
            "provider_observation_id": .string("observation"),
            "status": .string("verified"),
            "verification_kind": .string("dom_postcondition"),
            "url": .string("https://example.invalid/private")
        ]
        XCTAssertThrowsError(try CrossProviderCompletionRequest.from(params: params)) {
            XCTAssertEqual($0 as? CrossProviderTraceError, .unexpectedField("url"))
        }
        params.removeValue(forKey: "url")
        params["provider"] = .string("computer_use")
        XCTAssertThrowsError(try CrossProviderCompletionRequest.from(params: params)) {
            XCTAssertEqual($0 as? CrossProviderTraceError, .invalidField("provider"))
        }
    }

    func testPendingStoreIsOwnerOnlyAndBoundedWithoutEvictingActiveTraces() throws {
        let root = temporaryDirectory("bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrossProviderTracePendingStore(directory: root, maximumRecords: 2)
        let first = String(repeating: "1", count: 32)
        let second = String(repeating: "2", count: 32)
        let third = String(repeating: "3", count: 32)
        let fourth = String(repeating: "4", count: 32)
        let start = Date(timeIntervalSince1970: 200)

        _ = try store.prepare(
            traceID: first,
            rootSpanID: String(repeating: "a", count: 16),
            rootOperationID: "first",
            now: start,
            lifetime: 60
        )
        _ = try store.prepare(
            traceID: second,
            rootSpanID: String(repeating: "b", count: 16),
            rootOperationID: "second",
            now: start,
            lifetime: 60
        )
        XCTAssertThrowsError(try store.prepare(
            traceID: third,
            rootSpanID: String(repeating: "c", count: 16),
            rootOperationID: "third",
            now: start,
            lifetime: 60
        ))

        _ = try store.prepare(
            traceID: fourth,
            rootSpanID: String(repeating: "d", count: 16),
            rootOperationID: "fourth",
            now: start.addingTimeInterval(61),
            lifetime: 60
        )
        XCTAssertEqual(try traceFiles(in: root).count, 2)
        XCTAssertNoThrow(try store.record(traceID: fourth))
        let directoryMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        let fileMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: traceFiles(in: root)[0].path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testLegacyReceiptWithoutTraceFieldsStillDecodes() throws {
        let receipt = OperationReceipt(
            operationID: "operation",
            requestID: "request",
            method: "status",
            workflowID: nil,
            targetSurface: nil,
            risk: nil,
            planDigest: nil,
            runtimeIdentity: RuntimeIdentity(
                processID: 1,
                executablePath: nil,
                bundlePath: nil,
                bundleIdentifier: nil,
                bundleVersion: nil
            ),
            permissionContext: "test",
            permissions: [],
            status: .succeeded,
            errorCode: nil,
            evidence: [],
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            schemaVersion: 3
        )
        let decoded = try JSONCodec.decode(OperationReceipt.self, from: JSONCodec.encode(receipt))
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertNil(decoded.traceID)
        XCTAssertNil(decoded.providerProvenance)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONCodec.decode(type, from: JSONCodec.encode(value))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-cross-provider-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func traceFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("trace-") && $0.pathExtension == "json" }
    }

    private func serializedFiles(in directory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.sorted { $0.path < $1.path }.map {
            String(decoding: try Data(contentsOf: $0), as: UTF8.self)
        }.joined(separator: "\n")
    }
}
