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

        let service = discoveryService(reader: reader)
        let discovery = service.handle(RequestEnvelope(method: "adapter.capabilities", params: [
            "adapter_id": .string("vscode"), "operation": .string("diagnostics.summary"),
            "fixture_id": .string(fixtureID)
        ]))
        XCTAssertEqual(discovery.status, .succeeded)
        XCTAssertEqual(discovery.result["availability"]?.arrayValue?.first?["state"], .string("available"))
        let manifest = try XCTUnwrap(discovery.result["manifests"]?.arrayValue?.first)
        let contract = try XCTUnwrap(manifest["operations"]?.arrayValue?.first?["contract"])
        let properties = try XCTUnwrap(contract["inputSchema"]?["properties"]?.objectValue)
        var parameters = properties.compactMapValues { $0["const"] }
        parameters["fixture_id"] = .string(fixtureID)
        let method = try XCTUnwrap(contract["method"]?.stringValue)
        let response = service.handle(RequestEnvelope(method: method, params: parameters))
        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["observation"]?["fields"]?["error_count"], .number(1))
        XCTAssertEqual(response.result["observation"]?["fields"]?["warning_count"], .number(1))
        let fieldsSchema = try XCTUnwrap(contract["outputSchema"]?["properties"]?["observation"]?["properties"]?["fields"])
        let outputFields = try XCTUnwrap(response.result["observation"]?["fields"]?.objectValue)
        XCTAssertEqual(Set(outputFields.keys), Set(fieldsSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        for (key, value) in outputFields {
            let type = fieldsSchema["properties"]?[key]?["type"]?.stringValue
            if key.hasSuffix("_count") {
                XCTAssertEqual(type, "integer")
                XCTAssertNotNil(value.doubleValue)
            } else {
                XCTAssertEqual(type, "string")
                XCTAssertNotNil(value.stringValue)
            }
        }
        let stale = VSCodeDiagnosticsSnapshot(
            provider: snapshot.provider, fixtureID: fixtureID, bundleID: snapshot.bundleID,
            workspaceDigest: workspaceDigest, generatedAt: now.addingTimeInterval(-11), diagnostics: snapshot.diagnostics
        )
        try JSONCodec.encode(stale).write(to: fixtureDirectory.appendingPathComponent("diagnostics.json"))
        let retry = service.handle(RequestEnvelope(method: method, params: parameters))
        XCTAssertEqual(retry.status, .blocked)
        XCTAssertEqual(retry.error?.details["reason"], .string("stale_snapshot"))
    }

    func testScopedDiscoveryReportsDeclarationAndCurrentBlockers() throws {
        let reader = DiscoveryDiagnosticsReader()
        let service = discoveryService(reader: reader)
        let scope: [String: JSONValue] = ["adapter_id": .string("vscode"), "operation": .string("diagnostics.summary")]
        let declaration = service.handle(RequestEnvelope(method: "adapter.capabilities", params: scope))
        XCTAssertEqual(declaration.result["manifests"]?.arrayValue?.count, 1)
        XCTAssertEqual(declaration.result["manifests"]?.arrayValue?.first?["adapterID"], .string("vscode"))
        XCTAssertEqual(declaration.result["availability"]?.arrayValue?.first?["state"], .string("declared"))
        XCTAssertEqual(reader.reads, 0)
        var parameters = scope
        parameters["fixture_id"] = .string("problems_fixture")
        for (error, reason) in [(VSCodeDiagnosticsError.fixtureDescriptorMissing, "fixture_descriptor_missing"), (.staleSnapshot, "stale_snapshot")] {
            reader.error = error
            let response = service.handle(RequestEnvelope(method: "adapter.capabilities", params: parameters))
            XCTAssertEqual(response.status, .succeeded)
            XCTAssertEqual(response.result["availability"]?.arrayValue?.first?["state"], .string("blocked"))
            XCTAssertEqual(response.result["availability"]?.arrayValue?.first?["reason"], .string(reason))
        }
        let unknown = service.handle(RequestEnvelope(method: "adapter.capabilities", params: ["adapter_id": .string("missing")]))
        XCTAssertNotEqual(unknown.status, .succeeded)
        let ambiguous = service.handle(RequestEnvelope(method: "adapter.capabilities", params: ["fixture_id": .string("problems_fixture")]))
        XCTAssertNotEqual(ambiguous.status, .succeeded)
    }

    func testDiagnosticsAdmissionAgreesAcrossDiscoveryExecutionAndTasks() {
        let reader = DiscoveryDiagnosticsReader()
        let service = discoveryService(reader: reader)
        let base: [String: JSONValue] = [
            "adapter_id": .string("vscode"), "operation": .string("diagnostics.summary"),
            "fixture_id": .string("problems_fixture")
        ]
        let invalid: [(String, JSONValue?)] = [
            ("fixture_id", nil), ("fixture_id", .string("../outside")), ("fixture_id", .string("fixture\n")),
            ("max_age_seconds", .number(0)), ("max_age_seconds", .number(61)),
            ("max_age_seconds", .string("10")), ("snapshot_path", .string("/tmp/untrusted"))
        ]
        for (key, value) in invalid {
            var parameters = base
            parameters[key] = value
            let plan = TaskPlan(id: "diagnostics", name: "Diagnostics", summary: "Read fixture diagnostics", steps: [
                TaskStep(id: "read", action: ActionSpec(kind: .adapter, surface: .macApp, parameters: parameters))
            ])
            XCTAssertFalse(TaskPlanValidator.validate(plan).valid, "Accepted invalid \(key)")
            let execution = service.handle(RequestEnvelope(method: "adapter.diagnostics", params: parameters))
            XCTAssertEqual(execution.status, .failed, "Accepted invalid \(key)")
            if parameters["fixture_id"] != nil {
                let discovery = service.handle(RequestEnvelope(method: "adapter.capabilities", params: parameters))
                XCTAssertEqual(discovery.status, .failed, "Accepted invalid discovery \(key)")
            }
        }
        XCTAssertEqual(reader.reads, 0, "Invalid input reached the reader")
    }

    private func discoveryService(reader: VSCodeDiagnosticsReading) -> MacCtlService {
        let application = RunningApplicationDescriptor(
            name: "Visual Studio Code", bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app", processID: 4242, launchDate: nil
        )
        return MacCtlService(
            appController: AppController(runningApplicationProvider: { [application] }),
            permissionContext: "test", vscodeDiagnosticsReader: reader
        )
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

private final class DiscoveryDiagnosticsReader: VSCodeDiagnosticsReading {
    var reads = 0
    var error = VSCodeDiagnosticsError.fixtureDescriptorMissing

    func target(fixtureID: String) throws -> VSCodeFixtureTarget {
        if error == .fixtureDescriptorMissing { throw error }
        return VSCodeFixtureTarget(fixtureID: fixtureID, bundleID: "com.microsoft.VSCode", processID: 4242,
                                   workspacePath: "/tmp/fixture", windowTitle: "fixture")
    }

    func read(fixtureID: String, application: AppInfo, maxAge: TimeInterval) throws -> AppAdapterObservation {
        reads += 1
        throw error
    }
}
