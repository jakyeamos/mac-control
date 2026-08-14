import CryptoKit
import Foundation

/// The exact process identity recorded by the disposable VS Code fixture.
/// A bundle identifier alone is insufficient because a user may already have
/// another VS Code window or process running.
public struct VSCodeFixtureTarget: Codable, Equatable {
    public let fixtureID: String
    public let bundleID: String
    public let processID: Int32
    public let appPath: String?
    public let workspacePath: String
    public let windowTitle: String

    public init(
        fixtureID: String,
        bundleID: String,
        processID: Int32,
        appPath: String? = nil,
        workspacePath: String,
        windowTitle: String
    ) {
        self.fixtureID = fixtureID
        self.bundleID = bundleID
        self.processID = processID
        self.appPath = appPath
        self.workspacePath = workspacePath
        self.windowTitle = windowTitle
    }
}

public struct VSCodeFixtureDescriptor: Codable, Equatable {
    public let schemaVersion: Int
    public let fixtureID: String
    public let state: String
    public let bundleID: String
    public let processID: Int32?
    public let appPath: String?
    public let workspacePath: String
    public let profilePath: String
    public let extensionPath: String
    public let windowTitle: String

    public init(
        schemaVersion: Int = 1,
        fixtureID: String,
        state: String,
        bundleID: String,
        processID: Int32?,
        appPath: String?,
        workspacePath: String,
        profilePath: String,
        extensionPath: String,
        windowTitle: String
    ) {
        self.schemaVersion = schemaVersion
        self.fixtureID = fixtureID
        self.state = state
        self.bundleID = bundleID
        self.processID = processID
        self.appPath = appPath
        self.workspacePath = workspacePath
        self.profilePath = profilePath
        self.extensionPath = extensionPath
        self.windowTitle = windowTitle
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureID = "fixture_id"
        case state
        case bundleID = "bundle_id"
        case processID = "pid"
        case appPath = "app_path"
        case workspacePath = "workspace_path"
        case profilePath = "profile_path"
        case extensionPath = "extension_path"
        case windowTitle = "window_title"
    }
}

public struct VSCodeDiagnosticRecord: Codable, Equatable {
    public let severity: String
    public let source: String?
    public let code: String?
    public let line: Int
    public let column: Int

    public init(
        severity: String,
        source: String? = nil,
        code: String? = nil,
        line: Int,
        column: Int
    ) {
        self.severity = severity
        self.source = source
        self.code = code
        self.line = line
        self.column = column
    }

    private enum CodingKeys: String, CodingKey {
        case severity, source, code, line, column
    }
}

public struct VSCodeDiagnosticsSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let provider: String
    public let fixtureID: String
    public let bundleID: String
    public let workspaceDigest: String
    public let generatedAt: Date
    public let diagnostics: [VSCodeDiagnosticRecord]

    public init(
        schemaVersion: Int = 1,
        provider: String,
        fixtureID: String,
        bundleID: String,
        workspaceDigest: String,
        generatedAt: Date,
        diagnostics: [VSCodeDiagnosticRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.fixtureID = fixtureID
        self.bundleID = bundleID
        self.workspaceDigest = workspaceDigest
        self.generatedAt = generatedAt
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provider
        case fixtureID = "fixture_id"
        case bundleID = "bundle_id"
        case workspaceDigest = "workspace_digest"
        case generatedAt = "generated_at"
        case diagnostics
    }
}

public enum VSCodeDiagnosticsError: Error, LocalizedError, Equatable {
    case invalidFixtureID
    case fixtureDescriptorMissing
    case fixtureNotReady
    case snapshotMissing
    case invalidSnapshot
    case identityMismatch
    case staleSnapshot
    case invalidMaxAge

    public var errorDescription: String? {
        switch self {
        case .invalidFixtureID:
            return "VS Code fixture id is invalid or attempts path traversal"
        case .fixtureDescriptorMissing:
            return "VS Code fixture descriptor is missing"
        case .fixtureNotReady:
            return "VS Code fixture is not ready; no semantic diagnostics were accepted"
        case .snapshotMissing:
            return "VS Code fixture diagnostics snapshot is missing"
        case .invalidSnapshot:
            return "VS Code fixture diagnostics snapshot is invalid or not redacted"
        case .identityMismatch:
            return "VS Code fixture process identity does not match the requested target"
        case .staleSnapshot:
            return "VS Code fixture diagnostics snapshot is stale"
        case .invalidMaxAge:
            return "VS Code diagnostics max age must be greater than zero and no more than 60 seconds"
        }
    }
}

public protocol VSCodeDiagnosticsReading {
    func target(fixtureID: String) throws -> VSCodeFixtureTarget
    func read(
        fixtureID: String,
        application: AppInfo,
        maxAge: TimeInterval
    ) throws -> AppAdapterObservation
}

/// Reads only the redacted snapshot written by the fixture extension. It does
/// not use Accessibility, keyboard input, screenshots, or the Problems panel
/// UI. The extension is the native VS Code diagnostics boundary; this file is
/// the owner-scoped, exact-process receipt boundary on the Mac Control side.
public final class FileVSCodeDiagnosticsReader: VSCodeDiagnosticsReading {
    public static let defaultMaxAge: TimeInterval = 10
    public static let supportedBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders"
    ]

    private let rootURL: URL
    private let now: () -> Date

    public init(
        rootURL: URL = MacCtlPaths.vscodeFixturesDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.now = now
    }

    public static func isValidFixtureID(_ fixtureID: String) -> Bool {
        let bytes = Array(fixtureID.utf8)
        guard (1...48).contains(bytes.count),
              let first = bytes.first,
              ((48...57).contains(first) || (97...122).contains(first)) else {
            return false
        }
        return bytes.allSatisfy {
            $0 == 45 || $0 == 95 || (48...57).contains($0) || (97...122).contains($0)
        }
    }

    public func target(fixtureID: String) throws -> VSCodeFixtureTarget {
        guard Self.isValidFixtureID(fixtureID) else { throw VSCodeDiagnosticsError.invalidFixtureID }
        let directory = try fixtureDirectory(fixtureID)
        let descriptorURL = directory.appendingPathComponent("fixture.json")
        guard FileManager.default.fileExists(atPath: descriptorURL.path) else {
            throw VSCodeDiagnosticsError.fixtureDescriptorMissing
        }
        let descriptor: VSCodeFixtureDescriptor
        do {
            descriptor = try JSONCodec.decode(
                VSCodeFixtureDescriptor.self,
                from: Data(contentsOf: descriptorURL)
            )
        } catch {
            throw VSCodeDiagnosticsError.fixtureDescriptorMissing
        }
        let markerData = try? Data(contentsOf: directory.appendingPathComponent("fixture-marker.json"))
        guard descriptor.schemaVersion == 1,
              descriptor.fixtureID == fixtureID,
              descriptor.state == "ready",
              Self.supportedBundleIDs.contains(descriptor.bundleID),
              let processID = descriptor.processID,
              processID > 0,
              let appPath = descriptor.appPath,
              !appPath.isEmpty,
              path(descriptor.workspacePath, isInside: directory),
              path(descriptor.profilePath, isInside: directory),
              !descriptor.extensionPath.isEmpty,
              descriptor.windowTitle.contains(fixtureID),
              let markerData,
              Self.validFixtureMarker(markerData, fixtureID: fixtureID, descriptor: descriptor) else {
            throw VSCodeDiagnosticsError.fixtureNotReady
        }
        return VSCodeFixtureTarget(
            fixtureID: descriptor.fixtureID,
            bundleID: descriptor.bundleID,
            processID: processID,
            appPath: appPath,
            workspacePath: descriptor.workspacePath,
            windowTitle: descriptor.windowTitle
        )
    }

    public func read(
        fixtureID: String,
        application: AppInfo,
        maxAge: TimeInterval = FileVSCodeDiagnosticsReader.defaultMaxAge
    ) throws -> AppAdapterObservation {
        guard (0...60).contains(maxAge), maxAge > 0 else {
            throw VSCodeDiagnosticsError.invalidMaxAge
        }
        let target = try target(fixtureID: fixtureID)
        guard application.processID == target.processID,
              application.bundleID == target.bundleID,
              target.appPath == nil || target.appPath == application.path else {
            throw VSCodeDiagnosticsError.identityMismatch
        }
        let directory = try fixtureDirectory(fixtureID)
        let snapshotURL = directory.appendingPathComponent("diagnostics.json")
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw VSCodeDiagnosticsError.snapshotMissing
        }
        let snapshotData: Data
        do {
            snapshotData = try Data(contentsOf: snapshotURL)
        } catch {
            throw VSCodeDiagnosticsError.invalidSnapshot
        }
        guard Self.isRedactedSnapshot(snapshotData) else {
            throw VSCodeDiagnosticsError.invalidSnapshot
        }
        let snapshot: VSCodeDiagnosticsSnapshot
        do {
            snapshot = try JSONCodec.decode(
                VSCodeDiagnosticsSnapshot.self,
                from: snapshotData
            )
        } catch {
            throw VSCodeDiagnosticsError.invalidSnapshot
        }
        guard snapshot.schemaVersion == 1,
              snapshot.provider == "vscode.languages.getDiagnostics",
              snapshot.fixtureID == target.fixtureID,
              snapshot.bundleID == target.bundleID,
              snapshot.workspaceDigest == expectedWorkspaceDigest(
                  fixtureID: target.fixtureID,
                  workspacePath: target.workspacePath,
                  directory: directory
              ),
              snapshot.generatedAt <= now().addingTimeInterval(1),
              now().timeIntervalSince(snapshot.generatedAt) <= maxAge,
              snapshot.diagnostics.allSatisfy(Self.validRecord) else {
            if snapshot.generatedAt < now().addingTimeInterval(-maxAge) {
                throw VSCodeDiagnosticsError.staleSnapshot
            }
            throw VSCodeDiagnosticsError.invalidSnapshot
        }

        let counts = Dictionary(grouping: snapshot.diagnostics, by: { $0.severity.lowercased() })
        let digest = (try? JSONCodec.encode(snapshot.diagnostics)).map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } ?? ""
        return AppAdapterObservation(
            adapterID: "vscode",
            operation: "diagnostics.summary",
            application: application.name,
            state: "ready",
            fields: [
                "fixture_id": .string(target.fixtureID),
                "workspace_digest": .string(snapshot.workspaceDigest),
                "error_count": .number(Double(counts["error"]?.count ?? 0)),
                "warning_count": .number(Double(counts["warning"]?.count ?? 0)),
                "info_count": .number(Double(counts["info"]?.count ?? 0)),
                "hint_count": .number(Double(counts["hint"]?.count ?? 0)),
                "diagnostic_digest": .string(digest),
                "generated_at": .string(snapshot.generatedAt.ISO8601Format())
            ]
        )
    }

    private func fixtureDirectory(_ fixtureID: String) throws -> URL {
        let directory = rootURL.appendingPathComponent(fixtureID, isDirectory: true)
            .standardizedFileURL
        guard path(directory.path, isInside: rootURL) else {
            throw VSCodeDiagnosticsError.invalidFixtureID
        }
        return directory
    }

    private func path(_ candidate: String, isInside root: URL) -> Bool {
        let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        return candidateURL.path == root.standardizedFileURL.path
            || candidateURL.path.hasPrefix(rootPath)
    }

    private func expectedWorkspaceDigest(
        fixtureID: String,
        workspacePath: String,
        directory: URL
    ) -> String? {
        let markerURL = directory.appendingPathComponent("fixture-marker.json")
        guard let markerData = try? Data(contentsOf: markerURL) else { return nil }
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        var payload = Data("\(fixtureID)|\(workspace)|".utf8)
        payload.append(markerData)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func validRecord(_ record: VSCodeDiagnosticRecord) -> Bool {
        ["error", "warning", "info", "hint"].contains(record.severity.lowercased())
            && record.line >= 0
            && record.column >= 0
            && (record.source?.count ?? 0) <= 80
            && (record.code?.count ?? 0) <= 80
    }

    private static func validFixtureMarker(
        _ data: Data,
        fixtureID: String,
        descriptor: VSCodeFixtureDescriptor
    ) -> Bool {
        guard let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["schema_version"] as? Int == 1,
              marker["fixture_id"] as? String == fixtureID,
              marker["purpose"] as? String == "macctl-vscode-problems-fixture",
              let workspacePath = marker["workspace_path"] as? String,
              URL(fileURLWithPath: workspacePath).standardizedFileURL.path
                  == URL(fileURLWithPath: descriptor.workspacePath).standardizedFileURL.path,
              marker["window_title"] as? String == descriptor.windowTitle else {
            return false
        }
        return true
    }

    private static func isRedactedSnapshot(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let diagnostics = object["diagnostics"] as? [[String: Any]] else {
            return false
        }
        let snapshotKeys: Set<String> = [
            "schema_version", "provider", "fixture_id", "bundle_id",
            "workspace_digest", "generated_at", "diagnostics"
        ]
        let recordKeys: Set<String> = ["severity", "source", "code", "line", "column"]
        guard Set(object.keys).isSubset(of: snapshotKeys) else { return false }
        return diagnostics.allSatisfy { Set($0.keys).isSubset(of: recordKeys) }
    }
}
