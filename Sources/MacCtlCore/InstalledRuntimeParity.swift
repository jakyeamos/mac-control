import CryptoKit
import Darwin
import Foundation

public struct InstalledRuntimeBuildManifest: Codable, Equatable {
    public let schemaVersion: String
    public let sourceRevision: String
    public let builtArtifactSHA256: String
    public let installedArtifactSHA256: String
    public let installedAt: Date

    public init(
        sourceRevision: String,
        builtArtifactSHA256: String,
        installedArtifactSHA256: String,
        installedAt: Date = Date(),
        schemaVersion: String = InstalledRuntimeParity.installSchema
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRevision = sourceRevision
        self.builtArtifactSHA256 = builtArtifactSHA256
        self.installedArtifactSHA256 = installedArtifactSHA256
        self.installedAt = installedAt
    }
}

public struct InstalledRuntimeProcessManifest: Codable, Equatable {
    public let schemaVersion: String
    public let sourceRevision: String
    public let runningArtifactSHA256: String
    public let processID: Int32
    public let startedAt: Date

    public init(
        sourceRevision: String,
        runningArtifactSHA256: String,
        processID: Int32,
        startedAt: Date = Date(),
        schemaVersion: String = InstalledRuntimeParity.processSchema
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRevision = sourceRevision
        self.runningArtifactSHA256 = runningArtifactSHA256
        self.processID = processID
        self.startedAt = startedAt
    }
}

public struct InstalledRuntimeParityStatus: Codable, Equatable {
    public let state: String
    public let message: String
    public let sourceRevision: String?
    public let processID: Int32?

    public init(state: String, message: String, sourceRevision: String? = nil, processID: Int32? = nil) {
        self.state = state
        self.message = message
        self.sourceRevision = sourceRevision
        self.processID = processID
    }
}

public enum InstalledRuntimeParity {
    public static let installSchema = "installed-runtime-build/v1"
    public static let processSchema = "installed-runtime-process/v1"

    public static func artifactSHA256(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func discoverSourceRevision(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let revision = environment["MACCTL_SOURCE_REVISION"], validRevision(revision) {
            return revision.lowercased()
        }
        guard let result = try? ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", FileManager.default.currentDirectoryPath, "rev-parse", "HEAD"]
        ) else { return "unknown" }
        let revision = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && validRevision(revision) ? revision.lowercased() : "unknown"
    }

    public static func recordInstallation(
        sourceRevision: String,
        builtArtifactSHA256: String,
        installedExecutable: URL,
        destination: URL = MacCtlPaths.runtimeParityInstallManifestURL,
        fileManager: FileManager = .default
    ) throws -> InstalledRuntimeBuildManifest {
        let manifest = InstalledRuntimeBuildManifest(
            sourceRevision: sourceRevision,
            builtArtifactSHA256: builtArtifactSHA256,
            installedArtifactSHA256: try artifactSHA256(at: installedExecutable)
        )
        try OwnerOnlyFileStore.write(try JSONCodec.encode(manifest), to: destination, fileManager: fileManager)
        return manifest
    }

    @discardableResult
    public static func publishRunningProcess(
        executable: URL? = Bundle.main.executableURL,
        processID: Int32 = getpid(),
        installManifestURL: URL = MacCtlPaths.runtimeParityInstallManifestURL,
        destination: URL = MacCtlPaths.runtimeParityProcessManifestURL,
        fileManager: FileManager = .default
    ) throws -> InstalledRuntimeProcessManifest {
        guard let executable else {
            throw NSError(domain: "MacCtlRuntimeParity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Running executable path is unavailable"])
        }
        let install = try JSONCodec.decode(
            InstalledRuntimeBuildManifest.self,
            from: Data(contentsOf: installManifestURL)
        )
        let manifest = InstalledRuntimeProcessManifest(
            sourceRevision: install.sourceRevision,
            runningArtifactSHA256: try artifactSHA256(at: executable),
            processID: processID
        )
        try OwnerOnlyFileStore.write(try JSONCodec.encode(manifest), to: destination, fileManager: fileManager)
        return manifest
    }

    public static func removeRunningProcess(
        processID: Int32 = getpid(),
        manifestURL: URL = MacCtlPaths.runtimeParityProcessManifestURL,
        fileManager: FileManager = .default
    ) {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONCodec.decode(InstalledRuntimeProcessManifest.self, from: data),
              manifest.processID == processID else { return }
        try? fileManager.removeItem(at: manifestURL)
    }

    public static func evaluate(
        installManifestURL: URL = MacCtlPaths.runtimeParityInstallManifestURL,
        processManifestURL: URL = MacCtlPaths.runtimeParityProcessManifestURL,
        expectedExecutable: URL = MacCtlPaths.daemonAppExecutableURL,
        expectedProcessID: Int32? = nil,
        processProbe: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> InstalledRuntimeParityStatus {
        guard let installData = try? Data(contentsOf: installManifestURL),
              let install = try? JSONCodec.decode(InstalledRuntimeBuildManifest.self, from: installData),
              install.schemaVersion == installSchema,
              validRevision(install.sourceRevision),
              validDigest(install.builtArtifactSHA256),
              validDigest(install.installedArtifactSHA256) else {
            return .init(state: "unverifiable", message: "Installed build identity is missing or invalid")
        }
        guard let processData = try? Data(contentsOf: processManifestURL),
              let process = try? JSONCodec.decode(InstalledRuntimeProcessManifest.self, from: processData),
              process.schemaVersion == processSchema,
              validDigest(process.runningArtifactSHA256) else {
            return .init(state: "not_running", message: "Running daemon identity is missing or invalid", sourceRevision: install.sourceRevision)
        }
        let pidMatches = expectedProcessID.map { $0 == process.processID } ?? true
        guard pidMatches && processProbe(process.processID) else {
            return .init(state: "not_running", message: "Recorded daemon PID is not the active LaunchAgent process", sourceRevision: install.sourceRevision, processID: process.processID)
        }
        guard process.sourceRevision == install.sourceRevision,
              process.runningArtifactSHA256 == install.installedArtifactSHA256 else {
            return .init(state: "restart_required", message: "Running daemon does not match the installed build", sourceRevision: install.sourceRevision, processID: process.processID)
        }
        guard (try? artifactSHA256(at: expectedExecutable)) == install.installedArtifactSHA256 else {
            return .init(state: "install_stale", message: "Live installed daemon differs from its recorded identity", sourceRevision: install.sourceRevision, processID: process.processID)
        }
        return .init(
            state: "current",
            message: "Packaged provenance is recorded and installed and running daemon identities match",
            sourceRevision: install.sourceRevision,
            processID: process.processID
        )
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func validRevision(_ value: String) -> Bool {
        (7...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}
