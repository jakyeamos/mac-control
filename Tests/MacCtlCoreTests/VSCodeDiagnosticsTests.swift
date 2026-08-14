import CryptoKit
import Foundation
import XCTest
@testable import MacCtlCore

final class VSCodeDiagnosticsTests: XCTestCase {
    func testVSCodeManifestDeclaresNativeRedactedDiagnosticsRoute() throws {
        let manifest = try XCTUnwrap(AppAdapterRegistry().manifest(adapterID: "vscode"))
        let operation = try XCTUnwrap(manifest.operation(named: "diagnostics.summary"))

        XCTAssertEqual(manifest.supportedBundleIdentifiers, ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"])
        XCTAssertFalse(operation.mutating)
        XCTAssertEqual(operation.routes, [.native])
        XCTAssertEqual(operation.focusSupport, .backgroundSafe)
        XCTAssertTrue(operation.redactedObservationSchema.contains("error_count"))
        XCTAssertFalse(operation.redactedObservationSchema.contains("message"))
    }

    func testReaderAcceptsExactFreshFixtureAndReturnsOnlyRedactedSummary() throws {
        let root = temporaryDirectory("vscode-positive")
        let fixtureID = "problems_fixture"
        let now = Date(timeIntervalSince1970: 10_000)
        let workspace = root.appendingPathComponent(fixtureID).appendingPathComponent("workspace")
        let fixtureDirectory = workspace.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let marker = Data("{\"fixture_id\":\"problems_fixture\",\"purpose\":\"macctl-vscode-problems-fixture\",\"schema_version\":1,\"window_title\":\"macctl VS Code Problems Fixture — problems_fixture\",\"workspace_path\":\"\(workspace.path)\"}\n".utf8)
        try marker.write(to: fixtureDirectory.appendingPathComponent("fixture-marker.json"))
        var digestPayload = Data("\(fixtureID)|\(workspace.path)|".utf8)
        digestPayload.append(marker)
        let workspaceDigest = SHA256.hash(data: digestPayload).map { String(format: "%02x", $0) }.joined()
        let descriptor = VSCodeFixtureDescriptor(
            fixtureID: fixtureID,
            state: "ready",
            bundleID: "com.microsoft.VSCode",
            processID: 4242,
            appPath: "/Applications/Visual Studio Code.app",
            workspacePath: workspace.path,
            profilePath: fixtureDirectory.appendingPathComponent("profile").path,
            extensionPath: "/tmp/macctl-vscode-extension",
            windowTitle: "macctl VS Code Problems Fixture — problems_fixture"
        )
        let snapshot = VSCodeDiagnosticsSnapshot(
            provider: "vscode.languages.getDiagnostics",
            fixtureID: fixtureID,
            bundleID: "com.microsoft.VSCode",
            workspaceDigest: workspaceDigest,
            generatedAt: now,
            diagnostics: [
                VSCodeDiagnosticRecord(severity: "error", source: "macctl-fixture", code: "MACCTL", line: 0, column: 0),
                VSCodeDiagnosticRecord(severity: "warning", source: "macctl-fixture", code: "MACCTL", line: 1, column: 0)
            ]
        )
        try JSONCodec.encode(descriptor).write(to: fixtureDirectory.appendingPathComponent("fixture.json"))
        try JSONCodec.encode(snapshot).write(to: fixtureDirectory.appendingPathComponent("diagnostics.json"))

        let reader = FileVSCodeDiagnosticsReader(rootURL: root, now: { now })
        let application = AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: 4242,
            bundleVersion: "1.0"
        )
        let observation = try reader.read(fixtureID: fixtureID, application: application, maxAge: 10)

        XCTAssertEqual(observation.state, "ready")
        XCTAssertEqual(observation.fields["error_count"]?.doubleValue, 1)
        XCTAssertEqual(observation.fields["warning_count"]?.doubleValue, 1)
        let encoded = String(decoding: try JSONCodec.encode(observation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("message"))
        XCTAssertFalse(encoded.contains("Fixture error"))
    }

    func testReaderRejectsWrongIdentityStaleSnapshotAndPrivateMessageFields() throws {
        let root = temporaryDirectory("vscode-negative")
        let fixtureID = "problems_fixture"
        let now = Date(timeIntervalSince1970: 10_000)
        let fixtureDirectory = root.appendingPathComponent(fixtureID)
        let workspace = fixtureDirectory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let descriptor = VSCodeFixtureDescriptor(
            fixtureID: fixtureID,
            state: "ready",
            bundleID: "com.microsoft.VSCode",
            processID: 4242,
            appPath: "/Applications/Visual Studio Code.app",
            workspacePath: workspace.path,
            profilePath: fixtureDirectory.appendingPathComponent("profile").path,
            extensionPath: "/tmp/macctl-vscode-extension",
            windowTitle: "macctl VS Code Problems Fixture — problems_fixture"
        )
        let marker = Data("{\"fixture_id\":\"problems_fixture\",\"purpose\":\"macctl-vscode-problems-fixture\",\"schema_version\":1,\"window_title\":\"macctl VS Code Problems Fixture — problems_fixture\",\"workspace_path\":\"\(workspace.path)\"}\n".utf8)
        try marker.write(to: fixtureDirectory.appendingPathComponent("fixture-marker.json"))
        try JSONCodec.encode(descriptor).write(to: fixtureDirectory.appendingPathComponent("fixture.json"))
        let application = AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: 4242,
            bundleVersion: nil
        )
        let reader = FileVSCodeDiagnosticsReader(rootURL: root, now: { now })

        XCTAssertThrowsError(try reader.read(fixtureID: fixtureID, application: application, maxAge: 0)) { error in
            XCTAssertEqual(error as? VSCodeDiagnosticsError, .invalidMaxAge)
        }

        let stale = VSCodeDiagnosticsSnapshot(
            provider: "vscode.languages.getDiagnostics",
            fixtureID: fixtureID,
            bundleID: "com.microsoft.VSCode",
            workspaceDigest: String(repeating: "b", count: 64),
            generatedAt: now.addingTimeInterval(-11),
            diagnostics: []
        )
        try JSONCodec.encode(stale).write(to: fixtureDirectory.appendingPathComponent("diagnostics.json"))
        XCTAssertThrowsError(try reader.read(fixtureID: fixtureID, application: application, maxAge: 10)) { error in
            XCTAssertEqual(error as? VSCodeDiagnosticsError, .staleSnapshot)
        }

        let wrongProcess = AppInfo(
            name: application.name,
            bundleID: application.bundleID,
            path: application.path,
            isRunning: true,
            processID: 9999,
            bundleVersion: nil
        )
        XCTAssertThrowsError(try reader.read(fixtureID: fixtureID, application: wrongProcess, maxAge: 10)) { error in
            XCTAssertEqual(error as? VSCodeDiagnosticsError, .identityMismatch)
        }

        let copiedSnapshot = VSCodeDiagnosticsSnapshot(
            provider: "vscode.languages.getDiagnostics",
            fixtureID: fixtureID,
            bundleID: "com.microsoft.VSCode",
            workspaceDigest: String(repeating: "c", count: 64),
            generatedAt: now,
            diagnostics: []
        )
        try JSONCodec.encode(copiedSnapshot).write(to: fixtureDirectory.appendingPathComponent("diagnostics.json"))
        XCTAssertThrowsError(try reader.read(fixtureID: fixtureID, application: application, maxAge: 10)) { error in
            XCTAssertEqual(error as? VSCodeDiagnosticsError, .invalidSnapshot)
        }

        let validSnapshot = VSCodeDiagnosticsSnapshot(
            provider: "vscode.languages.getDiagnostics",
            fixtureID: fixtureID,
            bundleID: "com.microsoft.VSCode",
            workspaceDigest: String(repeating: "c", count: 64),
            generatedAt: now,
            diagnostics: []
        )
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCodec.encode(validSnapshot)) as? [String: Any])
        raw["diagnostics"] = [["severity": "error", "line": 0, "column": 0, "message": "private text"]]
        try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            .write(to: fixtureDirectory.appendingPathComponent("diagnostics.json"))
        XCTAssertThrowsError(try reader.read(fixtureID: fixtureID, application: application, maxAge: 10)) { error in
            XCTAssertEqual(error as? VSCodeDiagnosticsError, .invalidSnapshot)
        }
    }

    func testFixtureIDsRejectTraversalUppercaseAndLeadingSeparators() {
        XCTAssertTrue(FileVSCodeDiagnosticsReader.isValidFixtureID("problems_fixture-1"))
        XCTAssertFalse(FileVSCodeDiagnosticsReader.isValidFixtureID("../escape"))
        XCTAssertFalse(FileVSCodeDiagnosticsReader.isValidFixtureID("_leading"))
        XCTAssertFalse(FileVSCodeDiagnosticsReader.isValidFixtureID("-leading"))
        XCTAssertFalse(FileVSCodeDiagnosticsReader.isValidFixtureID("UPPERCASE"))
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-(name)-(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
