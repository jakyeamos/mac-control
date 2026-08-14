import Foundation
import XCTest
@testable import MacCtlCore

final class ReleaseEvidenceArchiveTests: XCTestCase {
    func testReleaseEvidenceSurvivesRollingReceiptEviction() throws {
        let directory = temporaryDirectory("retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationReceiptStore(directory: directory, maximumRecords: 1)
        let proof = receipt(
            method: "workflow.run",
            workflowID: "finder.open",
            verificationResult: "passed",
            completedAt: Date(timeIntervalSince1970: 100)
        )
        try store.record(proof)
        Thread.sleep(forTimeInterval: 0.01)
        try store.record(receipt(method: "doctor", completedAt: Date(timeIntervalSince1970: 101)))

        XCTAssertFalse(try store.list(limit: 10).contains { $0.operationID == proof.operationID })
        XCTAssertTrue(try store.listForReleaseGate().contains { $0.operationID == proof.operationID })

        let status = store.status()
        XCTAssertEqual(status.pendingPrune, 0)
        XCTAssertEqual(status.invalidReceiptCount, 0)
        XCTAssertTrue(status.directoryOwnerOnly)
        XCTAssertTrue(status.filesOwnerOnly)

        let archive = directory.appendingPathComponent(".release-evidence", isDirectory: true)
        let archiveMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(archiveMode.intValue & 0o777, 0o700)
        let files = try FileManager.default.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testNonReleaseReceiptIsNotArchived() throws {
        let directory = temporaryDirectory("non-release")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationReceiptStore(directory: directory, maximumRecords: 1)
        let ordinary = receipt(method: "doctor", completedAt: Date(timeIntervalSince1970: 100))
        try store.record(ordinary)
        Thread.sleep(forTimeInterval: 0.01)
        try store.record(receipt(method: "status", completedAt: Date(timeIntervalSince1970: 101)))

        XCTAssertFalse(try store.listForReleaseGate().contains { $0.operationID == ordinary.operationID })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".release-evidence").path
            )
        )
    }

    func testOlderProofCannotReplaceNewerArchivedProof() throws {
        let directory = temporaryDirectory("ordering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationReceiptStore(directory: directory, maximumRecords: 1)
        let newer = receipt(
            method: "shortcut.run",
            verificationResult: "passed",
            route: ShortcutRunRoute.keyboard.rawValue,
            evidence: [ReceiptEvidence(kind: "shortcut_behavior", source: "test")],
            completedAt: Date(timeIntervalSince1970: 200)
        )
        let older = receipt(
            method: "shortcut.run",
            verificationResult: "passed",
            route: ShortcutRunRoute.keyboard.rawValue,
            evidence: [ReceiptEvidence(kind: "shortcut_behavior", source: "test")],
            completedAt: Date(timeIntervalSince1970: 100)
        )
        try store.record(newer)
        try store.record(older)

        let archived = try store.listForReleaseGate().filter {
            $0.method == "shortcut.run" && $0.route == ShortcutRunRoute.keyboard.rawValue
        }
        XCTAssertTrue(archived.contains { $0.operationID == newer.operationID })
    }

    func testIndependentStoreInstancesPublishOnlyValidOwnerOnlyReceipts() throws {
        let directory = temporaryDirectory("parallel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = (0..<4).map { _ in OperationReceiptStore(directory: directory, maximumRecords: 16) }
        let queue = DispatchQueue(label: "release-evidence-test", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = NSLock()
        var errors: [Error] = []
        for index in 0..<16 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try stores[index % stores.count].record(self.receipt(
                        method: "workflow.run",
                        workflowID: "finder.open",
                        verificationResult: "passed",
                        completedAt: Date(timeIntervalSince1970: Double(index))
                    ))
                } catch {
                    failures.lock()
                    errors.append(error)
                    failures.unlock()
                }
            }
        }
        group.wait()

        XCTAssertTrue(errors.isEmpty, "Concurrent receipt errors: \(errors)")
        let status = stores[0].status()
        XCTAssertEqual(status.invalidReceiptCount, 0)
        XCTAssertEqual(status.pendingPrune, 0)
        XCTAssertTrue(status.filesOwnerOnly)
        XCTAssertFalse(try stores[0].listForReleaseGate().isEmpty)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-release-evidence-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func receipt(
        method: String,
        workflowID: String? = nil,
        verificationResult: String = "not_required",
        route: String? = nil,
        evidence: [ReceiptEvidence] = [],
        completedAt: Date
    ) -> OperationReceipt {
        OperationReceipt(
            operationID: UUID().uuidString,
            requestID: UUID().uuidString,
            method: method,
            workflowID: workflowID,
            targetSurface: .macApp,
            risk: .safe,
            executionResult: "succeeded",
            verificationResult: verificationResult,
            planDigest: nil,
            route: route,
            runtimeIdentity: RuntimeIdentity(
                processID: 1,
                executablePath: "/tmp/macctld",
                bundlePath: nil,
                bundleIdentifier: nil,
                bundleVersion: nil
            ),
            permissionContext: "test",
            permissions: [],
            status: .succeeded,
            errorCode: nil,
            evidence: evidence,
            startedAt: completedAt.addingTimeInterval(-1),
            completedAt: completedAt
        )
    }
}
