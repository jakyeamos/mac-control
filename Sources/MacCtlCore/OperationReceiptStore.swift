import Foundation

public struct ReceiptEvidence: Codable, Equatable {
    public let kind: String
    public let source: String?

    public init(kind: String, source: String?) {
        self.kind = kind
        self.source = source
    }
}

/// Privacy-bounded application identity for durable control observations.
/// The installed path is represented only by a digest so receipts do not
/// retain user-specific filesystem locations.
public struct ControlReceiptApplication: Codable, Equatable {
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let pathDigest: String

    public init(application: AppInfo) {
        self.name = application.name
        self.bundleID = application.bundleID
        self.version = application.bundleVersion
        self.pathDigest = CapabilityProfileDigest.make(application.path)
    }

    public func matches(_ application: WarmPathApplicationIdentity) -> Bool {
        if let bundleID, let otherBundleID = application.bundleID {
            return bundleID.caseInsensitiveCompare(otherBundleID) == .orderedSame
                && version == application.version
        }
        return pathDigest == CapabilityProfileDigest.make(application.path)
            && version == application.version
    }
}

/// Redacted target context attached to control receipts. Selector values are
/// never retained; the digest supports deduplication while selectorFields says
/// which stable discriminator classes were present.
public struct ControlReceiptTarget: Codable, Equatable {
    public let application: ControlReceiptApplication
    public let action: String?
    public let targetFingerprintDigest: String?
    public let locatorDigest: String?
    public let selectorFields: [String]

    public init(
        application: ControlReceiptApplication,
        action: String? = nil,
        targetFingerprintDigest: String? = nil,
        locatorDigest: String? = nil,
        selectorFields: [String] = []
    ) {
        self.application = application
        self.action = action
        self.targetFingerprintDigest = targetFingerprintDigest
        self.locatorDigest = locatorDigest
        self.selectorFields = Array(Set(selectorFields)).sorted()
    }
}

/// Aggregated, provider-neutral blocker evidence returned by the fast control
/// capability probe. It is advisory evidence, never execution authority.
public struct ControlBlockerObservation: Codable, Equatable {
    public let schemaVersion: Int
    public let provider: String
    public let state: AgentActionOutcomeState
    public let failureClass: String?
    public let route: String?
    public let target: ControlReceiptTarget
    public let taskID: String?
    public let count: Int
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let freshUntil: Date
    public let isFresh: Bool
    public let nextAction: String?

    public init(
        provider: String,
        state: AgentActionOutcomeState,
        failureClass: String?,
        route: String?,
        target: ControlReceiptTarget,
        taskID: String?,
        count: Int,
        firstObservedAt: Date,
        lastObservedAt: Date,
        freshUntil: Date,
        isFresh: Bool,
        nextAction: String?,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.state = state
        self.failureClass = failureClass
        self.route = route
        self.target = target
        self.taskID = taskID
        self.count = max(1, count)
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.freshUntil = freshUntil
        self.isFresh = isFresh
        self.nextAction = nextAction
    }
}

public struct OperationReceipt: Codable, Equatable {
    public let schemaVersion: Int
    public let operationID: String
    public let requestID: String
    public let method: String
    public let source: String?
    public let workflowID: String?
    public let targetSurface: SurfaceKind?
    public let providerTargetSurface: ControlTargetSurface?
    public let requestedFocusPolicy: FocusPolicy?
    public let focusPolicy: FocusPolicy?
    public let focusSelectionReason: String?
    public let backgroundUnavailableReason: String?
    public let risk: RiskLevel?
    public let approvalState: String
    public let executionResult: String
    public let verificationResult: String
    public let planDigest: String?
    public let taskID: String?
    public let stepID: String?
    public let route: String?
    public let adapterID: String?
    public let recoveryClassification: String?
    public let preconditionResult: String?
    public let postconditionResult: String?
    public let lifecycleState: String?
    public let actionOutcome: AgentActionOutcome?
    public let controlTarget: ControlReceiptTarget?
    public let traceID: String?
    public let spanID: String?
    public let parentSpanID: String?
    public let providerObservationDigest: String?
    public let provider: String?
    public let providerProvenance: CrossProviderTraceProvenance?
    public let providerSessionDigest: String?
    public let providerTurnDigest: String?
    public let providerTabDigest: String?
    public let foregroundState: CrossProviderForegroundState?
    public let startedAtMilliseconds: Int64?
    public let completedAtMilliseconds: Int64?
    public let runtimeIdentity: RuntimeIdentity
    public let permissionContext: String
    public let permissions: [PermissionStatus]
    public let status: OperationStatus
    public let errorCode: String?
    public let evidence: [ReceiptEvidence]
    public let startedAt: Date
    public let completedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID
        case requestID
        case method
        case source
        case workflowID
        case targetSurface
        case providerTargetSurface
        case requestedFocusPolicy
        case focusPolicy
        case focusSelectionReason
        case backgroundUnavailableReason
        case risk
        case approvalState
        case executionResult
        case verificationResult
        case planDigest
        case taskID
        case stepID
        case route
        case adapterID
        case recoveryClassification
        case preconditionResult
        case postconditionResult
        case lifecycleState
        case actionOutcome
        case controlTarget
        case traceID
        case spanID
        case parentSpanID
        case providerObservationDigest
        case provider
        case providerProvenance
        case providerSessionDigest
        case providerTurnDigest
        case providerTabDigest
        case foregroundState
        case startedAtMilliseconds
        case completedAtMilliseconds
        case runtimeIdentity
        case permissionContext
        case permissions
        case status
        case errorCode
        case evidence
        case startedAt
        case completedAt
    }

    public init(
        operationID: String,
        requestID: String,
        method: String,
        source: String? = nil,
        workflowID: String?,
        targetSurface: SurfaceKind?,
        providerTargetSurface: ControlTargetSurface? = nil,
        requestedFocusPolicy: FocusPolicy? = nil,
        focusPolicy: FocusPolicy? = nil,
        focusSelectionReason: String? = nil,
        backgroundUnavailableReason: String? = nil,
        risk: RiskLevel?,
        approvalState: String = "not_required",
        executionResult: String = "not_run",
        verificationResult: String = "not_run",
        planDigest: String?,
        taskID: String? = nil,
        stepID: String? = nil,
        route: String? = nil,
        adapterID: String? = nil,
        recoveryClassification: String? = nil,
        preconditionResult: String? = nil,
        postconditionResult: String? = nil,
        lifecycleState: String? = nil,
        actionOutcome: AgentActionOutcome? = nil,
        controlTarget: ControlReceiptTarget? = nil,
        traceID: String? = nil,
        spanID: String? = nil,
        parentSpanID: String? = nil,
        providerObservationDigest: String? = nil,
        provider: String? = nil,
        providerProvenance: CrossProviderTraceProvenance? = nil,
        providerSessionDigest: String? = nil,
        providerTurnDigest: String? = nil,
        providerTabDigest: String? = nil,
        foregroundState: CrossProviderForegroundState? = nil,
        startedAtMilliseconds: Int64? = nil,
        completedAtMilliseconds: Int64? = nil,
        runtimeIdentity: RuntimeIdentity,
        permissionContext: String,
        permissions: [PermissionStatus],
        status: OperationStatus,
        errorCode: String?,
        evidence: [ReceiptEvidence],
        startedAt: Date,
        completedAt: Date,
        schemaVersion: Int = 4
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.requestID = requestID
        self.method = method
        self.source = source
        self.workflowID = workflowID
        self.targetSurface = targetSurface
        self.providerTargetSurface = providerTargetSurface
        self.requestedFocusPolicy = requestedFocusPolicy
        self.focusPolicy = focusPolicy
        self.focusSelectionReason = focusSelectionReason
        self.backgroundUnavailableReason = backgroundUnavailableReason
        self.risk = risk
        self.approvalState = approvalState
        self.executionResult = executionResult
        self.verificationResult = verificationResult
        self.planDigest = planDigest
        self.taskID = taskID
        self.stepID = stepID
        self.route = route
        self.adapterID = adapterID
        self.recoveryClassification = recoveryClassification
        self.preconditionResult = preconditionResult
        self.postconditionResult = postconditionResult
        self.lifecycleState = lifecycleState
        self.actionOutcome = actionOutcome
        self.controlTarget = controlTarget
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.providerObservationDigest = providerObservationDigest
        self.provider = provider
        self.providerProvenance = providerProvenance
        self.providerSessionDigest = providerSessionDigest
        self.providerTurnDigest = providerTurnDigest
        self.providerTabDigest = providerTabDigest
        self.foregroundState = foregroundState
        self.startedAtMilliseconds = startedAtMilliseconds
        self.completedAtMilliseconds = completedAtMilliseconds
        self.runtimeIdentity = runtimeIdentity
        self.permissionContext = permissionContext
        self.permissions = permissions
        self.status = status
        self.errorCode = errorCode
        self.evidence = evidence
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.operationID = try container.decode(String.self, forKey: .operationID)
        self.requestID = try container.decode(String.self, forKey: .requestID)
        self.method = try container.decode(String.self, forKey: .method)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.workflowID = try container.decodeIfPresent(String.self, forKey: .workflowID)
        self.targetSurface = try container.decodeIfPresent(SurfaceKind.self, forKey: .targetSurface)
        self.providerTargetSurface = try container.decodeIfPresent(
            ControlTargetSurface.self,
            forKey: .providerTargetSurface
        )
        self.requestedFocusPolicy = try container.decodeIfPresent(FocusPolicy.self, forKey: .requestedFocusPolicy)
        self.focusPolicy = try container.decodeIfPresent(FocusPolicy.self, forKey: .focusPolicy)
        self.focusSelectionReason = try container.decodeIfPresent(String.self, forKey: .focusSelectionReason)
        self.backgroundUnavailableReason = try container.decodeIfPresent(
            String.self,
            forKey: .backgroundUnavailableReason
        )
        self.risk = try container.decodeIfPresent(RiskLevel.self, forKey: .risk)
        self.approvalState = try container.decodeIfPresent(String.self, forKey: .approvalState) ?? "not_required"
        self.executionResult = try container.decodeIfPresent(String.self, forKey: .executionResult) ?? "not_run"
        self.verificationResult = try container.decodeIfPresent(String.self, forKey: .verificationResult) ?? "not_run"
        self.planDigest = try container.decodeIfPresent(String.self, forKey: .planDigest)
        self.taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        self.stepID = try container.decodeIfPresent(String.self, forKey: .stepID)
        self.route = try container.decodeIfPresent(String.self, forKey: .route)
        self.adapterID = try container.decodeIfPresent(String.self, forKey: .adapterID)
        self.recoveryClassification = try container.decodeIfPresent(String.self, forKey: .recoveryClassification)
        self.preconditionResult = try container.decodeIfPresent(String.self, forKey: .preconditionResult)
        self.postconditionResult = try container.decodeIfPresent(String.self, forKey: .postconditionResult)
        self.lifecycleState = try container.decodeIfPresent(String.self, forKey: .lifecycleState)
        self.actionOutcome = try container.decodeIfPresent(AgentActionOutcome.self, forKey: .actionOutcome)
        self.controlTarget = try container.decodeIfPresent(ControlReceiptTarget.self, forKey: .controlTarget)
        self.traceID = try container.decodeIfPresent(String.self, forKey: .traceID)
        self.spanID = try container.decodeIfPresent(String.self, forKey: .spanID)
        self.parentSpanID = try container.decodeIfPresent(String.self, forKey: .parentSpanID)
        self.providerObservationDigest = try container.decodeIfPresent(String.self, forKey: .providerObservationDigest)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.providerProvenance = try container.decodeIfPresent(
            CrossProviderTraceProvenance.self,
            forKey: .providerProvenance
        )
        self.providerSessionDigest = try container.decodeIfPresent(String.self, forKey: .providerSessionDigest)
        self.providerTurnDigest = try container.decodeIfPresent(String.self, forKey: .providerTurnDigest)
        self.providerTabDigest = try container.decodeIfPresent(String.self, forKey: .providerTabDigest)
        self.foregroundState = try container.decodeIfPresent(CrossProviderForegroundState.self, forKey: .foregroundState)
        self.startedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .startedAtMilliseconds)
        self.completedAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .completedAtMilliseconds)
        self.runtimeIdentity = try container.decode(RuntimeIdentity.self, forKey: .runtimeIdentity)
        self.permissionContext = try container.decodeIfPresent(String.self, forKey: .permissionContext) ?? "unknown"
        self.permissions = try container.decodeIfPresent([PermissionStatus].self, forKey: .permissions) ?? []
        self.status = try container.decode(OperationStatus.self, forKey: .status)
        self.errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        self.evidence = try container.decodeIfPresent([ReceiptEvidence].self, forKey: .evidence) ?? []
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}

public struct ReceiptPruneResult: Codable, Equatable {
    public let prunedCount: Int
    public let remainingCount: Int
    public let maximumRecords: Int

    public init(prunedCount: Int, remainingCount: Int, maximumRecords: Int) {
        self.prunedCount = prunedCount
        self.remainingCount = remainingCount
        self.maximumRecords = maximumRecords
    }
}

public struct ReceiptStoreStatus: Codable, Equatable {
    public let directory: String
    public let fileCount: Int
    public let maximumRecords: Int
    public let pendingPrune: Int
    public let invalidReceiptCount: Int
    public let writable: Bool
    public let directoryOwnerOnly: Bool
    public let filesOwnerOnly: Bool
    public let oldestReceipt: Date?
    public let newestReceipt: Date?

    public init(
        directory: String,
        fileCount: Int,
        maximumRecords: Int,
        pendingPrune: Int,
        invalidReceiptCount: Int,
        writable: Bool,
        directoryOwnerOnly: Bool,
        filesOwnerOnly: Bool,
        oldestReceipt: Date?,
        newestReceipt: Date?
    ) {
        self.directory = directory
        self.fileCount = fileCount
        self.maximumRecords = maximumRecords
        self.pendingPrune = pendingPrune
        self.invalidReceiptCount = invalidReceiptCount
        self.writable = writable
        self.directoryOwnerOnly = directoryOwnerOnly
        self.filesOwnerOnly = filesOwnerOnly
        self.oldestReceipt = oldestReceipt
        self.newestReceipt = newestReceipt
    }

    public static func unavailable() -> ReceiptStoreStatus {
        ReceiptStoreStatus(
            directory: MacCtlPaths.receiptsDirectory.path,
            fileCount: 0,
            maximumRecords: OperationReceiptStore.defaultMaximumRecords,
            pendingPrune: 0,
            invalidReceiptCount: 0,
            writable: false,
            directoryOwnerOnly: false,
            filesOwnerOnly: false,
            oldestReceipt: nil,
            newestReceipt: nil
        )
    }
}

public enum ReceiptStoreError: Error, LocalizedError, Equatable {
    case invalidOperationID
    case directoryUnavailable(String)
    case writeFailed(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOperationID:
            return "Operation receipt requires a non-empty operation ID"
        case .directoryUnavailable(let message):
            return "Receipt directory is unavailable: \(message)"
        case .writeFailed(let message):
            return "Operation receipt could not be written: \(message)"
        case .readFailed(let message):
            return "Operation receipts could not be read: \(message)"
        }
    }
}

public final class OperationReceiptStore {
    public static let defaultMaximumRecords = 1_000
    public static let defaultBlockerFreshnessInterval: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let maximumRecords: Int
    private let fileManager: FileManager
    private let releaseEvidenceArchive: ReleaseEvidenceArchive
    private let lock = NSLock()

    public init(
        directory: URL = MacCtlPaths.receiptsDirectory,
        maximumRecords: Int = OperationReceiptStore.defaultMaximumRecords,
        releaseEvidenceDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumRecords = max(1, maximumRecords)
        self.fileManager = fileManager
        self.releaseEvidenceArchive = ReleaseEvidenceArchive(
            directory: releaseEvidenceDirectory
                ?? directory.appendingPathComponent(".release-evidence", isDirectory: true),
            fileManager: fileManager
        )
    }

    public func record(_ receipt: OperationReceipt) throws {
        guard !receipt.operationID.isEmpty else {
            throw ReceiptStoreError.invalidOperationID
        }
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let path = directory.appendingPathComponent(
            fileName(for: receipt.operationID, requestID: receipt.requestID)
        )
        do {
            let data = try JSONCodec.encode(receipt)
            try OwnerOnlyFileStore.withExclusiveDirectoryLock(directory, fileManager: fileManager) {
                try OwnerOnlyFileStore.write(data, to: path, fileManager: fileManager)
                try releaseEvidenceArchive.record(receipt)
                _ = try pruneLocked()
            }
        } catch let error as ReceiptStoreError {
            throw error
        } catch {
            throw ReceiptStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func list(limit: Int = 80) throws -> [OperationReceipt] {
        lock.lock()
        defer { lock.unlock() }
        let entries = try receiptEntries()
        return entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.url),
                  let receipt = try? JSONCodec.decode(OperationReceipt.self, from: data) else {
                return nil
            }
            return receipt
        }
        .sorted { $0.completedAt > $1.completedAt }
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// Release checks consume the rolling operation history plus the bounded
    /// newest-per-requirement archive. This keeps 24-hour proof independent of
    /// unrelated high-volume receipts without changing ordinary list callers.
    public func listForReleaseGate(limit: Int = OperationReceiptStore.defaultMaximumRecords) throws -> [OperationReceipt] {
        let rolling = try list(limit: limit)
        var seen = Set(rolling.map { "\($0.operationID)|\($0.requestID)|\($0.method)" })
        let archived = releaseEvidenceArchive.list().filter { receipt in
            seen.insert("\(receipt.operationID)|\(receipt.requestID)|\(receipt.method)").inserted
        }
        return (rolling + archived).sorted { $0.completedAt > $1.completedAt }
    }

    public func trace(_ traceID: String) throws -> [OperationReceipt] {
        guard CrossProviderCompletionRequest.isTraceID(traceID) else {
            throw ReceiptStoreError.readFailed("trace_id must be 32 lowercase hexadecimal characters")
        }
        return try list(limit: maximumRecords)
            .filter { $0.traceID == traceID }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Returns bounded, deduplicated blocker evidence for one installed app.
    /// Raw selectors never enter the aggregation key or result.
    public func recentControlBlockers(
        application: WarmPathApplicationIdentity,
        taskID: String? = nil,
        targetFingerprintDigest: String? = nil,
        limit: Int = 8,
        now: Date = Date(),
        freshnessInterval: TimeInterval = OperationReceiptStore.defaultBlockerFreshnessInterval
    ) throws -> [ControlBlockerObservation] {
        struct Aggregate {
            var receipt: OperationReceipt
            var count: Int
            var firstObservedAt: Date
            var lastObservedAt: Date
        }

        let candidates = try list(limit: min(maximumRecords, 250)).filter { receipt in
            guard let outcome = receipt.actionOutcome,
                  outcome.state != .verifiedSuccess,
                  let target = receipt.controlTarget,
                  target.application.matches(application) else {
                return false
            }
            if let taskID, receipt.taskID != taskID { return false }
            if let targetFingerprintDigest,
               target.targetFingerprintDigest != targetFingerprintDigest {
                return false
            }
            return true
        }

        var grouped: [String: Aggregate] = [:]
        for receipt in candidates {
            guard let outcome = receipt.actionOutcome,
                  let target = receipt.controlTarget else { continue }
            let key = [
                outcome.provider,
                outcome.state.rawValue,
                outcome.failureClass ?? "",
                outcome.route ?? "",
                receipt.taskID ?? "",
                target.action ?? "",
                target.targetFingerprintDigest ?? "",
                target.locatorDigest ?? "",
                target.selectorFields.joined(separator: ",")
            ].joined(separator: "|")
            if var aggregate = grouped[key] {
                aggregate.count += 1
                aggregate.firstObservedAt = min(aggregate.firstObservedAt, receipt.completedAt)
                if receipt.completedAt > aggregate.lastObservedAt {
                    aggregate.receipt = receipt
                    aggregate.lastObservedAt = receipt.completedAt
                }
                grouped[key] = aggregate
            } else {
                grouped[key] = Aggregate(
                    receipt: receipt,
                    count: 1,
                    firstObservedAt: receipt.completedAt,
                    lastObservedAt: receipt.completedAt
                )
            }
        }

        return grouped.values.compactMap { aggregate in
            guard let outcome = aggregate.receipt.actionOutcome,
                  let target = aggregate.receipt.controlTarget else { return nil }
            let freshUntil = aggregate.lastObservedAt.addingTimeInterval(max(0, freshnessInterval))
            return ControlBlockerObservation(
                provider: outcome.provider,
                state: outcome.state,
                failureClass: outcome.failureClass,
                route: outcome.route,
                target: target,
                taskID: aggregate.receipt.taskID,
                count: aggregate.count,
                firstObservedAt: aggregate.firstObservedAt,
                lastObservedAt: aggregate.lastObservedAt,
                freshUntil: freshUntil,
                isFresh: freshUntil >= now,
                nextAction: outcome.nextAction
            )
        }
        .sorted { $0.lastObservedAt > $1.lastObservedAt }
        .prefix(max(0, limit))
        .map { $0 }
    }

    public func prune() throws -> ReceiptPruneResult {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let result = try OwnerOnlyFileStore.withExclusiveDirectoryLock(directory, fileManager: fileManager) {
            try pruneLocked()
        }
        let remaining = try receiptEntries().count
        return ReceiptPruneResult(
            prunedCount: result,
            remainingCount: remaining,
            maximumRecords: maximumRecords
        )
    }

    public func status() -> ReceiptStoreStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let entries = try? receiptEntries() else {
            return ReceiptStoreStatus(
                directory: directory.path,
                fileCount: 0,
                maximumRecords: maximumRecords,
                pendingPrune: 0,
                invalidReceiptCount: 0,
                writable: false,
                directoryOwnerOnly: false,
                filesOwnerOnly: false,
                oldestReceipt: nil,
                newestReceipt: nil
            )
        }
        let dates = entries.compactMap(\.modificationDate).sorted()
        let archiveStatus = releaseEvidenceArchive.status()
        let invalidCount = entries.reduce(into: archiveStatus.invalidReceiptCount) { count, entry in
            guard let data = try? Data(contentsOf: entry.url),
                  (try? JSONCodec.decode(OperationReceipt.self, from: data)) != nil else {
                count += 1
                return
            }
        }
        let directoryOwnerOnly = ((try? fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
            .map { ($0.intValue & 0o777) == 0o700 } ?? false)
            && archiveStatus.directoryOwnerOnly
        let filesOwnerOnly = entries.allSatisfy { entry in
            guard let permissions = try? fileManager.attributesOfItem(atPath: entry.url.path)[.posixPermissions] as? NSNumber else {
                return false
            }
            return (permissions.intValue & 0o777) == 0o600
        } && archiveStatus.filesOwnerOnly
        return ReceiptStoreStatus(
            directory: directory.path,
            fileCount: entries.count,
            maximumRecords: maximumRecords,
            pendingPrune: max(0, entries.count - maximumRecords)
                + max(0, archiveStatus.fileCount - ReleaseEvidenceArchive.maximumRecords),
            invalidReceiptCount: invalidCount,
            writable: fileManager.isWritableFile(atPath: directory.path) && archiveStatus.writable,
            directoryOwnerOnly: directoryOwnerOnly,
            filesOwnerOnly: filesOwnerOnly,
            oldestReceipt: dates.first,
            newestReceipt: dates.last
        )
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ReceiptStoreError.directoryUnavailable(error.localizedDescription)
        }
    }

    private func receiptEntries() throws -> [ReceiptEntry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return ReceiptEntry(url: url, modificationDate: values?.contentModificationDate)
            }
            .sorted { $0.modificationDate ?? .distantPast > $1.modificationDate ?? .distantPast }
        } catch {
            throw ReceiptStoreError.readFailed(error.localizedDescription)
        }
    }

    private func pruneLocked() throws -> Int {
        let entries = try receiptEntries()
        guard entries.count > maximumRecords else { return 0 }
        var removed = 0
        for entry in entries.dropFirst(maximumRecords) {
            do {
                try fileManager.removeItem(at: entry.url)
                removed += 1
            } catch {
                throw ReceiptStoreError.writeFailed(error.localizedDescription)
            }
        }
        return removed
    }

    private func fileName(for operationID: String, requestID: String) -> String {
        let normalized = operationID.unicodeScalars.reduce(into: "") { value, scalar in
            let code = scalar.value
            let isAlphanumeric = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
            if isAlphanumeric || code == 45 || code == 95 {
                value.append(String(scalar))
            }
        }
        let normalizedRequest = requestID.unicodeScalars.reduce(into: "") { value, scalar in
            let code = scalar.value
            let isAlphanumeric = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
            if isAlphanumeric || code == 45 || code == 95 {
                value.append(String(scalar))
            }
        }
        let operationPart = normalized.isEmpty ? UUID().uuidString : normalized
        let requestPart = normalizedRequest.isEmpty ? UUID().uuidString : normalizedRequest
        return "receipt-\(operationPart)-\(requestPart).json"
    }
}

private struct ReceiptEntry {
    let url: URL
    let modificationDate: Date?
}
