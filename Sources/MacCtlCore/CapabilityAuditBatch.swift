import Foundation

/// The batch audit is intentionally a read-only inventory operation. It does
/// not open, activate, focus, or dispatch input to an application. Targets
/// that are not already running remain resumable rather than being silently
/// launched as a discovery side effect.
public enum CapabilityAuditBatchEntryState: String, Codable, Equatable {
    case pending
    case audited
    case notObserved = "not_observed"
    case blocked
    case failed

    public var canResume: Bool {
        switch self {
        case .pending, .notObserved, .failed:
            return true
        case .audited, .blocked:
            return false
        }
    }
}

public enum CapabilityAuditBatchReason: String, Codable, Equatable {
    case pending
    case audited
    case applicationNotFound = "application_not_found"
    case applicationNotRunning = "application_not_running"
    case applicationIdentityChanged = "application_identity_changed"
    case applicationVersionChanged = "application_version_changed"
    case permissionDenied = "permission_denied"
    case auditFailed = "audit_failed"
    case profilePersistenceFailed = "profile_persistence_failed"
}

/// A batch target stores an identity descriptor when resolution succeeded and
/// only the requested selector when it did not. It never stores a process ID
/// or a live AX element reference.
public struct CapabilityAuditBatchTarget: Codable, Equatable {
    public let selector: String
    public let displayName: String
    public let identity: WarmPathApplicationIdentity?

    public init(
        selector: String,
        displayName: String? = nil,
        identity: WarmPathApplicationIdentity? = nil
    ) {
        self.selector = selector
        self.displayName = displayName ?? identity?.name ?? selector
        self.identity = identity
    }

    public init(application: AppInfo) {
        let identity = WarmPathApplicationIdentity(application: application)
        self.init(
            selector: application.bundleID ?? application.path,
            displayName: application.name,
            identity: identity
        )
    }

    public var stableKey: String {
        [
            selector,
            identity?.bundleID ?? "",
            identity?.path ?? "",
            identity?.version ?? ""
        ].joined(separator: "|")
    }
}

public struct CapabilityAuditBatchEntryReceipt: Codable, Equatable {
    public let target: CapabilityAuditBatchTarget
    public let state: CapabilityAuditBatchEntryState
    public let reason: CapabilityAuditBatchReason
    public let attempts: Int
    public let profileState: CapabilityProfileState?
    public let archetype: MacAppArchetype?
    public let treeSignature: String?
    public let treeNodeCount: Int?
    public let treeTruncated: Bool?
    public let auditAttempts: Int?
    public let effectiveMaxNodes: Int?
    public let effectiveMaxDepth: Int?
    public let traversalMode: String?
    public let windowCount: Int?
    public let pageCount: Int?
    public let coverageComplete: Bool?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        target: CapabilityAuditBatchTarget,
        state: CapabilityAuditBatchEntryState = .pending,
        reason: CapabilityAuditBatchReason = .pending,
        attempts: Int = 0,
        profileState: CapabilityProfileState? = nil,
        archetype: MacAppArchetype? = nil,
        treeSignature: String? = nil,
        treeNodeCount: Int? = nil,
        treeTruncated: Bool? = nil,
        auditAttempts: Int? = nil,
        effectiveMaxNodes: Int? = nil,
        effectiveMaxDepth: Int? = nil,
        traversalMode: String? = nil,
        windowCount: Int? = nil,
        pageCount: Int? = nil,
        coverageComplete: Bool? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.target = target
        self.state = state
        self.reason = reason
        self.attempts = max(0, attempts)
        self.profileState = profileState
        self.archetype = archetype
        self.treeSignature = treeSignature
        self.treeNodeCount = treeNodeCount
        self.treeTruncated = treeTruncated
        self.auditAttempts = auditAttempts
        self.effectiveMaxNodes = effectiveMaxNodes
        self.effectiveMaxDepth = effectiveMaxDepth
        self.traversalMode = traversalMode
        self.windowCount = windowCount
        self.pageCount = pageCount
        self.coverageComplete = coverageComplete
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var canResume: Bool { state.canResume }
}

public struct CapabilityAuditBatchRun: Codable, Equatable {
    public let schemaVersion: Int
    public let runID: String
    public let manifestID: String
    public let maxNodes: Int
    public let maxDepth: Int
    public let maxConcurrency: Int
    public let targets: [CapabilityAuditBatchTarget]
    public let entries: [CapabilityAuditBatchEntryReceipt]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        runID: String = UUID().uuidString,
        manifestID: String,
        maxNodes: Int,
        maxDepth: Int,
        maxConcurrency: Int = 1,
        targets: [CapabilityAuditBatchTarget],
        entries: [CapabilityAuditBatchEntryReceipt]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.manifestID = manifestID
        self.maxNodes = max(1, maxNodes)
        self.maxDepth = max(0, maxDepth)
        self.maxConcurrency = max(1, maxConcurrency)
        self.targets = targets
        self.entries = entries ?? targets.map { CapabilityAuditBatchEntryReceipt(target: $0) }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var remainingCount: Int {
        entries.filter(\.canResume).count
    }

    public var completed: Bool { remainingCount == 0 }

    public func replacingEntries(
        _ entries: [CapabilityAuditBatchEntryReceipt],
        updatedAt: Date = Date()
    ) -> CapabilityAuditBatchRun {
        CapabilityAuditBatchRun(
            schemaVersion: schemaVersion,
            runID: runID,
            manifestID: manifestID,
            maxNodes: maxNodes,
            maxDepth: maxDepth,
            maxConcurrency: maxConcurrency,
            targets: targets,
            entries: entries,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public func replacingTargetsAndEntries(
        _ targets: [CapabilityAuditBatchTarget],
        entries: [CapabilityAuditBatchEntryReceipt],
        updatedAt: Date = Date()
    ) -> CapabilityAuditBatchRun {
        CapabilityAuditBatchRun(
            schemaVersion: schemaVersion,
            runID: runID,
            manifestID: manifestID,
            maxNodes: maxNodes,
            maxDepth: maxDepth,
            maxConcurrency: maxConcurrency,
            targets: targets,
            entries: entries,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct CapabilityAuditBatchReport: Codable, Equatable {
    public let run: CapabilityAuditBatchRun
    public let resumed: Bool
    public let processedCount: Int
    public let remainingCount: Int
    public let readOnly: Bool
    public let launchedApplications: Bool

    public init(
        run: CapabilityAuditBatchRun,
        resumed: Bool,
        processedCount: Int,
        readOnly: Bool = true,
        launchedApplications: Bool = false
    ) {
        self.run = run
        self.resumed = resumed
        self.processedCount = max(0, processedCount)
        self.remainingCount = run.remainingCount
        self.readOnly = readOnly
        self.launchedApplications = launchedApplications
    }
}

public enum CapabilityAuditBatchStoreError: Error, LocalizedError, Equatable {
    case invalidRun(String)
    case runNotFound(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRun(let message): return "Invalid capability audit batch: \(message)"
        case .runNotFound(let runID): return "Capability audit batch run was not found: \(runID)"
        case .writeFailed(let message): return "Could not persist capability audit batch: \(message)"
        }
    }
}

public final class CapabilityAuditBatchStore {
    private let fileManager: FileManager
    private let now: () -> Date
    public let directory: URL

    public init(
        directory: URL = MacCtlPaths.capabilityAuditBatchesDirectory,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
    }

    public func create(
        targets: [CapabilityAuditBatchTarget],
        maxNodes: Int,
        maxDepth: Int,
        maxConcurrency: Int = 1
    ) throws -> CapabilityAuditBatchRun {
        guard !targets.isEmpty else {
            throw CapabilityAuditBatchStoreError.invalidRun("at least one target is required")
        }
        guard targets.count <= CapabilityAuditCatalog.maximumTargets else {
            throw CapabilityAuditBatchStoreError.invalidRun("at most \(CapabilityAuditCatalog.maximumTargets) targets are supported")
        }
        let deduplicated = deduplicate(targets)
        guard deduplicated.count == targets.count else {
            throw CapabilityAuditBatchStoreError.invalidRun("targets must be unique")
        }
        let manifestID = CapabilityProfileDigest.make(
            [
                "mac-control-capability-audit-batch/v1",
                String(maxNodes),
                String(maxDepth),
                String(maxConcurrency),
                targets.map(\.stableKey).joined(separator: "||")
            ].joined(separator: "|")
        )
        let run = CapabilityAuditBatchRun(
            manifestID: manifestID,
            maxNodes: maxNodes,
            maxDepth: maxDepth,
            maxConcurrency: maxConcurrency,
            targets: targets,
            createdAt: now(),
            updatedAt: now()
        )
        try save(run)
        return run
    }

    public func load(runID: String) throws -> CapabilityAuditBatchRun {
        guard !runID.isEmpty else {
            throw CapabilityAuditBatchStoreError.runNotFound(runID)
        }
        let url = directory.appendingPathComponent(Self.filename(for: runID))
        guard let data = try? Data(contentsOf: url) else {
            throw CapabilityAuditBatchStoreError.runNotFound(runID)
        }
        do {
            let run = try JSONCodec.decode(CapabilityAuditBatchRun.self, from: data)
            try validate(run)
            return run
        } catch let error as CapabilityAuditBatchStoreError {
            throw error
        } catch {
            throw CapabilityAuditBatchStoreError.invalidRun(error.localizedDescription)
        }
    }

    @discardableResult
    public func save(_ run: CapabilityAuditBatchRun) throws -> CapabilityAuditBatchRun {
        do {
            try validate(run)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONCodec.encode(run)
            let url = directory.appendingPathComponent(Self.filename(for: run.runID))
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return run
        } catch let error as CapabilityAuditBatchStoreError {
            throw error
        } catch {
            throw CapabilityAuditBatchStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func list() -> [CapabilityAuditBatchRun] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let run = try? JSONCodec.decode(CapabilityAuditBatchRun.self, from: data),
                      (try? validate(run)) != nil else { return nil }
                return run
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func validate(_ run: CapabilityAuditBatchRun) throws {
        guard run.schemaVersion == 1 else {
            throw CapabilityAuditBatchStoreError.invalidRun("unsupported schema version")
        }
        guard !run.runID.isEmpty, !run.manifestID.isEmpty else {
            throw CapabilityAuditBatchStoreError.invalidRun("run and manifest identity are required")
        }
        guard run.maxNodes > 0, run.maxDepth >= 0, run.maxConcurrency == 1 else {
            throw CapabilityAuditBatchStoreError.invalidRun("bounds are invalid")
        }
        guard !run.targets.isEmpty,
              run.targets.count <= CapabilityAuditCatalog.maximumTargets,
              run.targets.count == run.entries.count else {
            throw CapabilityAuditBatchStoreError.invalidRun("target and receipt counts are invalid")
        }
        guard zip(run.targets, run.entries).allSatisfy({ $0 == $1.target }) else {
            throw CapabilityAuditBatchStoreError.invalidRun("receipt targets do not match the manifest")
        }
    }

    private func deduplicate(_ targets: [CapabilityAuditBatchTarget]) -> [CapabilityAuditBatchTarget] {
        var seen = Set<String>()
        return targets.filter { seen.insert($0.stableKey).inserted }
    }

    private static func filename(for runID: String) -> String {
        "\(CapabilityProfileDigest.make(runID)).json"
    }
}

/// Selects a bounded, deterministic set of user-facing apps for the default
/// inventory. Explicit selectors remain available for agents that own a
/// different app manifest. The priority list is a routing preference, not a
/// claim that every app supports every provider or task.
public enum CapabilityAuditCatalog {
    public static let maximumTargets = 24
    public static let defaultMaxNodes = CapabilityAuditBounds.defaultMaxNodes
    public static let defaultMaxDepth = CapabilityAuditBounds.defaultMaxDepth

    private static let priorityBundleIDs = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.Terminal",
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.mail",
        "com.apple.iCal",
        "com.apple.Notes",
        "com.apple.MobileSMS",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.hnc.Discord",
        "com.docker.docker",
        "md.obsidian",
        "com.pronto.desktop",
        "com.spotify.client",
        "net.whatsapp.WhatsApp",
        "us.zoom.xos",
        "com.todesktop.230313mzl4w4u92"
    ]

    public static func defaultTargets(
        from applications: [AppInfo],
        limit: Int = maximumTargets
    ) -> [CapabilityAuditBatchTarget] {
        let boundedLimit = min(max(1, limit), maximumTargets)
        let eligible = deduplicate(
            applications.filter(isEligible).map(CapabilityAuditBatchTarget.init)
        )
        guard !eligible.isEmpty else { return [] }

        let priorityIndex = Dictionary(
            uniqueKeysWithValues: priorityBundleIDs.enumerated().map { ($0.element.lowercased(), $0.offset) }
        )
        return eligible.sorted { lhs, rhs in
            let lhsIndex = lhs.identity?.bundleID.flatMap { priorityIndex[$0.lowercased()] }
                ?? Int.max
            let rhsIndex = rhs.identity?.bundleID.flatMap { priorityIndex[$0.lowercased()] }
                ?? Int.max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }.prefix(boundedLimit).map { $0 }
    }

    private static func deduplicate(_ targets: [CapabilityAuditBatchTarget]) -> [CapabilityAuditBatchTarget] {
        var seen = Set<String>()
        return targets.filter { seen.insert($0.stableKey).inserted }
    }

    private static func isEligible(_ application: AppInfo) -> Bool {
        let path = application.path.lowercased()
        let isUserFacingLocation = path.hasPrefix("/applications/")
            || path.hasPrefix("/system/applications/")
            || path.hasPrefix("/system/library/coreservices/finder.app")
            || path.contains("/users/") && path.contains("/applications/")
        guard isUserFacingLocation else { return false }

        let compact = "\(application.name) \(application.bundleID ?? "")"
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let excludedMarkers = [
            "helper", "agent", "server", "launcher", "urlhandler", "installer",
            "uninstaller", "diagnostic", "extensionhost", "filehandler", "droplet",
            "previewsshell", "systemintents", "systemevents", "widgetkit",
            "synchronizer", "coresync"
        ]
        return !excludedMarkers.contains(where: compact.contains)
    }
}
