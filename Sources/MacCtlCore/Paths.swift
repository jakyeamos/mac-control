import Foundation

public enum MacCtlPaths {
    public static let launchAgentLabel = "com.jakyeamos.macctl.daemon"

    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macctl", isDirectory: true)
    }

    public static var socketURL: URL {
        applicationSupportDirectory.appendingPathComponent("macctld.sock")
    }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/macctl", isDirectory: true)
    }

    public static var logURL: URL {
        logDirectory.appendingPathComponent("macctld.log")
    }

    public static var workflowDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("workflows", isDirectory: true)
    }

    public static var receiptsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("receipts", isDirectory: true)
    }

    /// Short-lived cross-provider handoff state. Raw completion credentials
    /// are never written here; only their digests and replay guards persist.
    public static var crossProviderTracesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("cross-provider-traces", isDirectory: true)
    }

    /// Durable task checkpoints are intentionally separate from operation receipts.
    public static var taskCheckpointsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("task-checkpoints", isDirectory: true)
    }

    /// App/task/target-specific measured route manifests.  These are kept
    /// separate from receipts so a stale benchmark can never masquerade as a
    /// completed operation.
    public static var warmPathsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("warm-paths", isDirectory: true)
    }

    /// Broad, read-only AX/provider capability profiles. These are separate
    /// from warm-path route manifests so a capability audit can never become
    /// latency-ranking authority.
    public static var capabilityProfilesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("capability-profiles", isDirectory: true)
    }

    /// Resumable, per-application read-only capability audit runs. These
    /// receipts are separate from individual capability profiles so a batch
    /// can resume without changing the hot-path cache contract.
    public static var capabilityAuditBatchesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("capability-audit-batches", isDirectory: true)
    }

    /// Exact shortcut targets are owner-only because provisioning requires
    /// retaining static menu paths. Receipts expose only binding digests.
    public static var shortcutBindingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("shortcut-bindings", isDirectory: true)
    }

    /// Agent-reported limitation candidates are kept apart from the reviewed
    /// source ledger. They are append-only observations, never execution
    /// authority or automatic ledger updates.
    public static var limitationProposalsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("limitation-proposals", isDirectory: true)
    }

    public static var signingIdentityURL: URL {
        applicationSupportDirectory.appendingPathComponent("signing-identity.json")
    }

    public static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    public static var userLocalBinDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    public static var daemonDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/macctl", isDirectory: true)
    }

    public static var daemonAppURL: URL {
        daemonDataDirectory.appendingPathComponent("macctld.app", isDirectory: true)
    }

    public static var daemonAppExecutableURL: URL {
        daemonAppURL.appendingPathComponent("Contents/MacOS/macctld")
    }

    public static var runtimeParityInstallManifestURL: URL {
        daemonDataDirectory.appendingPathComponent("runtime-parity-install.json")
    }

    public static var runtimeParityProcessManifestURL: URL {
        applicationSupportDirectory.appendingPathComponent("runtime-parity-process.json")
    }

    public static var legacyDaemonExecutableURL: URL {
        userLocalBinDirectory.appendingPathComponent("macctld")
    }

    @discardableResult
    public static func ensureDirectories() throws -> [URL] {
        let directories = [
            applicationSupportDirectory,
            logDirectory,
            workflowDirectory,
            receiptsDirectory,
            crossProviderTracesDirectory,
            taskCheckpointsDirectory,
            warmPathsDirectory,
            capabilityProfilesDirectory,
            capabilityAuditBatchesDirectory,
            shortcutBindingsDirectory,
            limitationProposalsDirectory
        ]
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        return directories
    }

    public static func ownerOnlySocketPath() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: socketURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o777 == 0o600
    }
}

public enum JSONCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

public final class SafeLog {
    private let lock = NSLock()

    public init() {}

    public func record(event: String, metadata: [String: String] = [:]) {
        guard let data = try? MacCtlPaths.ensureDirectories() else { return }
        _ = data
        var fields = ["event": event, "timestamp": ISO8601DateFormatter().string(from: Date())]
        for (key, value) in metadata {
            fields[key] = LogRedactor.redact(value: value, key: key)
        }
        let line = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: " ")
            + "\n"
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: MacCtlPaths.logURL.path) {
            fileManager.createFile(
                atPath: MacCtlPaths.logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: MacCtlPaths.logURL.path
        )
        guard let handle = try? FileHandle(forWritingTo: MacCtlPaths.logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    public func tail(limit: Int = 80) -> [String] {
        guard let data = try? Data(contentsOf: MacCtlPaths.logURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit))
            .map(String.init)
    }
}

public enum LogRedactor {
    private static let sensitiveFragments = [
        "password", "passcode", "credential", "secret", "token", "cookie", "authorization",
        "text", "ocr", "screenshot", "image", "body", "message"
    ]

    public static func redact(value: String, key: String) -> String {
        let normalizedKey = key.lowercased()
        if sensitiveFragments.contains(where: { normalizedKey.contains($0) }) {
            return "[REDACTED]"
        }
        return value
    }
}
