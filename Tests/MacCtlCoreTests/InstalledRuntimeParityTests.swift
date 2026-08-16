import Foundation
import XCTest
@testable import MacCtlCore

final class InstalledRuntimeParityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-runtime-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCurrentRequiresInstalledAndRunningDigestsToMatch() throws {
        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent("macctld")
        let installURL = root.appendingPathComponent("install.json")
        let processURL = root.appendingPathComponent("process.json")
        try Data("daemon-a".utf8).write(to: executable)
        let digest = try InstalledRuntimeParity.artifactSHA256(at: executable)
        let revision = String(repeating: "a", count: 40)
        let install = InstalledRuntimeBuildManifest(
            sourceRevision: revision,
            builtArtifactSHA256: digest,
            installedArtifactSHA256: digest
        )
        let process = InstalledRuntimeProcessManifest(
            sourceRevision: revision,
            runningArtifactSHA256: digest,
            processID: 42
        )
        try JSONCodec.encode(install).write(to: installURL)
        try JSONCodec.encode(process).write(to: processURL)

        let status = InstalledRuntimeParity.evaluate(
            installManifestURL: installURL,
            processManifestURL: processURL,
            expectedExecutable: executable,
            expectedProcessID: 42,
            processProbe: { $0 == 42 }
        )
        XCTAssertEqual(status.state, "current")
    }

    func testCurrentAllowsCodeSigningToChangeInstalledArtifactDigest() throws {
        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent("macctld")
        let installURL = root.appendingPathComponent("install.json")
        let processURL = root.appendingPathComponent("process.json")
        try Data("signed-daemon".utf8).write(to: executable)
        let installedDigest = try InstalledRuntimeParity.artifactSHA256(at: executable)
        let packagedExecutable = root.appendingPathComponent("unsigned-macctld")
        try Data("unsigned-daemon".utf8).write(to: packagedExecutable)
        let packagedDigest = try InstalledRuntimeParity.artifactSHA256(at: packagedExecutable)
        let revision = String(repeating: "e", count: 40)
        try JSONCodec.encode(InstalledRuntimeBuildManifest(
            sourceRevision: revision,
            builtArtifactSHA256: packagedDigest,
            installedArtifactSHA256: installedDigest
        )).write(to: installURL)
        try JSONCodec.encode(InstalledRuntimeProcessManifest(
            sourceRevision: revision,
            runningArtifactSHA256: installedDigest,
            processID: 42
        )).write(to: processURL)

        let status = InstalledRuntimeParity.evaluate(
            installManifestURL: installURL,
            processManifestURL: processURL,
            expectedExecutable: executable,
            expectedProcessID: 42,
            processProbe: { $0 == 42 }
        )

        XCTAssertEqual(status.state, "current")
        XCTAssertEqual(status.sourceRevision, revision)
        XCTAssertEqual(status.processID, 42)
    }

    func testOldRunningDigestRequiresRestart() throws {
        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent("macctld")
        let installURL = root.appendingPathComponent("install.json")
        let processURL = root.appendingPathComponent("process.json")
        try Data("daemon-new".utf8).write(to: executable)
        let digest = try InstalledRuntimeParity.artifactSHA256(at: executable)
        let revision = String(repeating: "b", count: 40)
        try JSONCodec.encode(InstalledRuntimeBuildManifest(
            sourceRevision: revision,
            builtArtifactSHA256: digest,
            installedArtifactSHA256: digest
        )).write(to: installURL)
        try JSONCodec.encode(InstalledRuntimeProcessManifest(
            sourceRevision: revision,
            runningArtifactSHA256: String(repeating: "c", count: 64),
            processID: 42
        )).write(to: processURL)

        let status = InstalledRuntimeParity.evaluate(
            installManifestURL: installURL,
            processManifestURL: processURL,
            expectedExecutable: executable,
            expectedProcessID: 42,
            processProbe: { _ in true }
        )
        XCTAssertEqual(status.state, "restart_required")
    }

    func testUnknownSourceRevisionIsUnverifiable() throws {
        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent("macctld")
        let installURL = root.appendingPathComponent("install.json")
        try Data("daemon".utf8).write(to: executable)
        let digest = try InstalledRuntimeParity.artifactSHA256(at: executable)
        try JSONCodec.encode(InstalledRuntimeBuildManifest(
            sourceRevision: "unknown",
            builtArtifactSHA256: digest,
            installedArtifactSHA256: digest
        )).write(to: installURL)
        let status = InstalledRuntimeParity.evaluate(
            installManifestURL: installURL,
            processManifestURL: root.appendingPathComponent("missing.json"),
            expectedExecutable: executable,
            processProbe: { _ in true }
        )
        XCTAssertEqual(status.state, "unverifiable")
    }

    func testProducerPublishesOwnerOnlyInstallAndProcessManifests() throws {
        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent("macctld")
        let installURL = root.appendingPathComponent("install.json")
        let processURL = root.appendingPathComponent("process.json")
        try Data("published-daemon".utf8).write(to: executable)
        let digest = try InstalledRuntimeParity.artifactSHA256(at: executable)
        let revision = String(repeating: "d", count: 40)

        _ = try InstalledRuntimeParity.recordInstallation(
            sourceRevision: revision,
            builtArtifactSHA256: digest,
            installedExecutable: executable,
            destination: installURL
        )
        _ = try InstalledRuntimeParity.publishRunningProcess(
            executable: executable,
            processID: 73,
            installManifestURL: installURL,
            destination: processURL
        )

        for url in [installURL, processURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let process = try JSONCodec.decode(
            InstalledRuntimeProcessManifest.self,
            from: Data(contentsOf: processURL)
        )
        XCTAssertEqual(process.sourceRevision, revision)
        XCTAssertEqual(process.runningArtifactSHA256, digest)
        XCTAssertEqual(process.processID, 73)
    }
}
