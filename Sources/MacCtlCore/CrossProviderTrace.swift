import CryptoKit
import Foundation

public enum CrossProviderTraceProvenance: String, Codable, Equatable {
    case macControlAttested = "mac_control_attested"
    case browserProviderAttested = "browser_provider_attested"
    case orchestratorDeclared = "orchestrator_declared"
    case unverified
}

public enum CrossProviderTraceState: String, Codable, Equatable {
    case open
    case completed
    case failed
    case blocked
    case expired
}

public enum CrossProviderCompletionStatus: String, Codable, Equatable {
    case verified
    case failed
    case blocked

    var operationStatus: OperationStatus {
        switch self {
        case .verified: return .succeeded
        case .failed: return .failed
        case .blocked: return .blocked
        }
    }

    var verificationResult: String {
        switch self {
        case .verified: return "passed"
        case .failed: return "failed"
        case .blocked: return "blocked"
        }
    }

    var traceState: CrossProviderTraceState {
        switch self {
        case .verified: return .completed
        case .failed: return .failed
        case .blocked: return .blocked
        }
    }
}

public enum CrossProviderForegroundState: String, Codable, Equatable {
    case preserved
    case changed
    case unverified
}

public struct CrossProviderTraceContext: Codable, Equatable {
    public let schemaVersion: Int
    public let traceID: String
    public let spanID: String
    public let completionToken: String
    public let expiresAt: Date
    public let provider: String
    public let provenance: CrossProviderTraceProvenance

    public init(
        traceID: String,
        spanID: String,
        completionToken: String,
        expiresAt: Date,
        provider: String = "browser_dom",
        provenance: CrossProviderTraceProvenance = .orchestratorDeclared,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.traceID = traceID
        self.spanID = spanID
        self.completionToken = completionToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case traceID = "trace_id"
        case spanID = "span_id"
        case completionToken = "completion_token"
        case expiresAt = "expires_at"
        case provider
        case provenance
    }
}

public struct CrossProviderCompletionRequest: Equatable {
    public static let allowedProviders: Set<String> = ["browser_dom", "cdp_dom"]
    public static let allowedKeys: Set<String> = [
        "trace_id", "completion_token", "provider", "provider_observation_id",
        "status", "verification_kind", "foreground_state", "provider_session_id",
        "provider_turn_id", "provider_tab_id"
    ]

    public let traceID: String
    public let completionToken: String
    public let provider: String
    public let providerObservationID: String
    public let status: CrossProviderCompletionStatus
    public let verificationKind: String
    public let foregroundState: CrossProviderForegroundState
    public let providerSessionID: String?
    public let providerTurnID: String?
    public let providerTabID: String?

    public init(
        traceID: String,
        completionToken: String,
        provider: String,
        providerObservationID: String,
        status: CrossProviderCompletionStatus,
        verificationKind: String,
        foregroundState: CrossProviderForegroundState = .unverified,
        providerSessionID: String? = nil,
        providerTurnID: String? = nil,
        providerTabID: String? = nil
    ) throws {
        guard Self.isTraceID(traceID) else { throw CrossProviderTraceError.invalidField("trace_id") }
        guard completionToken.hasPrefix("mctr_"), completionToken.count <= 160 else {
            throw CrossProviderTraceError.invalidField("completion_token")
        }
        guard Self.allowedProviders.contains(provider) else {
            throw CrossProviderTraceError.invalidField("provider")
        }
        guard Self.isBoundedOpaque(providerObservationID) else {
            throw CrossProviderTraceError.invalidField("provider_observation_id")
        }
        guard Self.isBoundedLabel(verificationKind) else {
            throw CrossProviderTraceError.invalidField("verification_kind")
        }
        for (key, value) in [
            ("provider_session_id", providerSessionID),
            ("provider_turn_id", providerTurnID),
            ("provider_tab_id", providerTabID)
        ] {
            if let value, !Self.isBoundedOpaque(value) {
                throw CrossProviderTraceError.invalidField(key)
            }
        }
        self.traceID = traceID
        self.completionToken = completionToken
        self.provider = provider
        self.providerObservationID = providerObservationID
        self.status = status
        self.verificationKind = verificationKind
        self.foregroundState = foregroundState
        self.providerSessionID = providerSessionID
        self.providerTurnID = providerTurnID
        self.providerTabID = providerTabID
    }

    public static func from(params: [String: JSONValue]) throws -> CrossProviderCompletionRequest {
        let unexpected = Set(params.keys).subtracting(allowedKeys)
        guard unexpected.isEmpty else {
            throw CrossProviderTraceError.unexpectedField(unexpected.sorted().first ?? "unknown")
        }
        guard let traceID = params["trace_id"]?.stringValue,
              let completionToken = params["completion_token"]?.stringValue,
              let provider = params["provider"]?.stringValue,
              let providerObservationID = params["provider_observation_id"]?.stringValue,
              let rawStatus = params["status"]?.stringValue,
              let status = CrossProviderCompletionStatus(rawValue: rawStatus),
              let verificationKind = params["verification_kind"]?.stringValue else {
            throw CrossProviderTraceError.invalidRequest
        }
        let foregroundState: CrossProviderForegroundState
        if let raw = params["foreground_state"]?.stringValue {
            guard let parsed = CrossProviderForegroundState(rawValue: raw) else {
                throw CrossProviderTraceError.invalidField("foreground_state")
            }
            foregroundState = parsed
        } else {
            foregroundState = .unverified
        }
        return try CrossProviderCompletionRequest(
            traceID: traceID,
            completionToken: completionToken,
            provider: provider,
            providerObservationID: providerObservationID,
            status: status,
            verificationKind: verificationKind,
            foregroundState: foregroundState,
            providerSessionID: params["provider_session_id"]?.stringValue,
            providerTurnID: params["provider_turn_id"]?.stringValue,
            providerTabID: params["provider_tab_id"]?.stringValue
        )
    }

    public var providerObservationDigest: String { Self.digest(providerObservationID) }
    public var providerSessionDigest: String? { providerSessionID.map(Self.digest) }
    public var providerTurnDigest: String? { providerTurnID.map(Self.digest) }
    public var providerTabDigest: String? { providerTabID.map(Self.digest) }
    public var completionDigest: String {
        let fields = [
            provider,
            providerObservationDigest,
            status.rawValue,
            verificationKind,
            foregroundState.rawValue,
            providerSessionDigest ?? "",
            providerTurnDigest ?? "",
            providerTabDigest ?? ""
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return Self.digest(canonical)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isTraceID(_ value: String) -> Bool {
        value.count == 32 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func isBoundedOpaque(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains(where: { $0.isNewline })
    }

    private static func isBoundedLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...90).contains($0.value)
                || (97...122).contains($0.value)
                || [45, 46, 95].contains($0.value)
        }
    }
}

public enum CrossProviderTraceError: Error, LocalizedError, Equatable {
    case invalidRequest
    case invalidField(String)
    case unexpectedField(String)
    case notFound
    case expired
    case alreadyCompleted
    case tokenMismatch
    case observationMismatch
    case storageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Cross-provider trace completion requires the bounded stdin schema"
        case .invalidField(let field): return "Cross-provider trace field is invalid: \(field)"
        case .unexpectedField(let field): return "Cross-provider trace field is not allowed: \(field)"
        case .notFound: return "Cross-provider trace was not found"
        case .expired: return "Cross-provider trace completion window has expired"
        case .alreadyCompleted: return "Cross-provider trace was already completed"
        case .tokenMismatch: return "Cross-provider trace completion token did not match"
        case .observationMismatch: return "Cross-provider trace replay did not match the recorded observation"
        case .storageUnavailable(let message): return "Cross-provider trace storage is unavailable: \(message)"
        }
    }
}

public enum CrossProviderPendingState: String, Codable, Equatable {
    case pending
    case completed
}

public struct CrossProviderPendingTrace: Codable, Equatable {
    public let schemaVersion: Int
    public let traceID: String
    public let rootSpanID: String
    public let rootOperationID: String
    public let tokenDigest: String
    public let createdAt: Date
    public let expiresAt: Date
    public let state: CrossProviderPendingState
    public let providerObservationDigest: String?
    public let completionDigest: String?
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case traceID = "trace_id"
        case rootSpanID = "root_span_id"
        case rootOperationID = "root_operation_id"
        case tokenDigest = "token_digest"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case state
        case providerObservationDigest = "provider_observation_digest"
        case completionDigest = "completion_digest"
        case completedAt = "completed_at"
    }

    init(
        traceID: String,
        rootSpanID: String,
        rootOperationID: String,
        tokenDigest: String,
        createdAt: Date,
        expiresAt: Date,
        state: CrossProviderPendingState = .pending,
        providerObservationDigest: String? = nil,
        completionDigest: String? = nil,
        completedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.traceID = traceID
        self.rootSpanID = rootSpanID
        self.rootOperationID = rootOperationID
        self.tokenDigest = tokenDigest
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.providerObservationDigest = providerObservationDigest
        self.completionDigest = completionDigest
        self.completedAt = completedAt
    }
}

public struct CrossProviderCompletionDisposition: Equatable {
    public let pendingTrace: CrossProviderPendingTrace
    public let duplicate: Bool
}

public final class CrossProviderTracePendingStore {
    public static let defaultLifetime: TimeInterval = 15 * 60
    public static let maximumLifetime: TimeInterval = 60 * 60
    public static let defaultMaximumRecords = 1_000

    private let directory: URL
    private let fileManager: FileManager
    private let maximumRecords: Int
    private let lock = NSLock()

    public init(
        directory: URL = MacCtlPaths.crossProviderTracesDirectory,
        fileManager: FileManager = .default,
        maximumRecords: Int = CrossProviderTracePendingStore.defaultMaximumRecords
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumRecords = max(1, maximumRecords)
    }

    public func prepare(
        traceID: String,
        rootSpanID: String,
        rootOperationID: String,
        now: Date = Date(),
        lifetime: TimeInterval = CrossProviderTracePendingStore.defaultLifetime
    ) throws -> CrossProviderTraceContext {
        guard CrossProviderCompletionRequest.isTraceID(traceID), rootSpanID.count == 16 else {
            throw CrossProviderTraceError.invalidField("trace_context")
        }
        let token = "mctr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let expiresAt = now.addingTimeInterval(min(max(lifetime, 1), Self.maximumLifetime))
        let record = CrossProviderPendingTrace(
            traceID: traceID,
            rootSpanID: rootSpanID,
            rootOperationID: rootOperationID,
            tokenDigest: CrossProviderCompletionRequest.digest(token),
            createdAt: now,
            expiresAt: expiresAt
        )
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        try makeRoomForTrace(traceID: traceID, now: now)
        try write(record)
        return CrossProviderTraceContext(
            traceID: traceID,
            spanID: rootSpanID,
            completionToken: token,
            expiresAt: expiresAt
        )
    }

    public func complete(
        _ request: CrossProviderCompletionRequest,
        now: Date = Date(),
        beforeCommit: ((CrossProviderPendingTrace) throws -> Void)? = nil
    ) throws -> CrossProviderCompletionDisposition {
        lock.lock()
        defer { lock.unlock() }
        let record = try read(traceID: request.traceID)
        guard secureEquals(record.tokenDigest, CrossProviderCompletionRequest.digest(request.completionToken)) else {
            throw CrossProviderTraceError.tokenMismatch
        }
        if record.state == .completed {
            guard record.providerObservationDigest == request.providerObservationDigest,
                  record.completionDigest == nil || record.completionDigest == request.completionDigest else {
                throw CrossProviderTraceError.observationMismatch
            }
            return CrossProviderCompletionDisposition(pendingTrace: record, duplicate: true)
        }
        guard record.expiresAt > now else { throw CrossProviderTraceError.expired }
        let completed = CrossProviderPendingTrace(
            traceID: record.traceID,
            rootSpanID: record.rootSpanID,
            rootOperationID: record.rootOperationID,
            tokenDigest: record.tokenDigest,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            state: .completed,
            providerObservationDigest: request.providerObservationDigest,
            completionDigest: request.completionDigest,
            completedAt: now
        )
        try beforeCommit?(completed)
        try write(completed)
        return CrossProviderCompletionDisposition(pendingTrace: completed, duplicate: false)
    }

    public func record(traceID: String) throws -> CrossProviderPendingTrace {
        lock.lock()
        defer { lock.unlock() }
        return try read(traceID: traceID)
    }

    public func discard(traceID: String) throws {
        guard CrossProviderCompletionRequest.isTraceID(traceID) else {
            throw CrossProviderTraceError.invalidField("trace_id")
        }
        lock.lock()
        defer { lock.unlock() }
        let path = tracePath(traceID: traceID)
        guard fileManager.fileExists(atPath: path.path) else { return }
        do {
            try fileManager.removeItem(at: path)
        } catch {
            throw CrossProviderTraceError.storageUnavailable(error.localizedDescription)
        }
    }

    public func effectiveState(traceID: String, now: Date = Date()) throws -> CrossProviderTraceState {
        let record = try record(traceID: traceID)
        if record.state == .completed { return .completed }
        return record.expiresAt <= now ? .expired : .open
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
            throw CrossProviderTraceError.storageUnavailable(error.localizedDescription)
        }
    }

    private func read(traceID: String) throws -> CrossProviderPendingTrace {
        guard CrossProviderCompletionRequest.isTraceID(traceID) else {
            throw CrossProviderTraceError.invalidField("trace_id")
        }
        let path = tracePath(traceID: traceID)
        guard fileManager.fileExists(atPath: path.path) else { throw CrossProviderTraceError.notFound }
        do {
            return try JSONCodec.decode(CrossProviderPendingTrace.self, from: Data(contentsOf: path))
        } catch let error as CrossProviderTraceError {
            throw error
        } catch {
            throw CrossProviderTraceError.storageUnavailable(error.localizedDescription)
        }
    }

    private func write(_ record: CrossProviderPendingTrace) throws {
        let path = tracePath(traceID: record.traceID)
        do {
            try JSONCodec.encode(record).write(to: path, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            throw CrossProviderTraceError.storageUnavailable(error.localizedDescription)
        }
    }

    private func tracePath(traceID: String) -> URL {
        directory.appendingPathComponent("trace-\(traceID).json")
    }

    private func makeRoomForTrace(traceID: String, now: Date) throws {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix("trace-") && $0.pathExtension == "json" }
            guard !urls.contains(tracePath(traceID: traceID)), urls.count >= maximumRecords else {
                return
            }
            var reclaimable: [(url: URL, record: CrossProviderPendingTrace)] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONCodec.decode(CrossProviderPendingTrace.self, from: data),
                      record.state == .completed || record.expiresAt <= now else {
                    continue
                }
                reclaimable.append((url, record))
            }
            reclaimable.sort { $0.record.createdAt < $1.record.createdAt }
            var remainingCount = urls.count
            for entry in reclaimable where remainingCount >= maximumRecords {
                try fileManager.removeItem(at: entry.url)
                remainingCount -= 1
            }
            guard remainingCount < maximumRecords else {
                throw CrossProviderTraceError.storageUnavailable(
                    "the bounded trace store is full of active completion windows"
                )
            }
        } catch let error as CrossProviderTraceError {
            throw error
        } catch {
            throw CrossProviderTraceError.storageUnavailable(error.localizedDescription)
        }
    }

    private func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct CrossProviderTraceMetrics: Codable, Equatable {
    public let macRoutingMilliseconds: Int
    public let handoffToCompletionMilliseconds: Int?
    public let totalMilliseconds: Int?
    public let focusInterruptionCount: Int

    private enum CodingKeys: String, CodingKey {
        case macRoutingMilliseconds = "mac_routing_ms"
        case handoffToCompletionMilliseconds = "handoff_to_completion_ms"
        case totalMilliseconds = "total_ms"
        case focusInterruptionCount = "focus_interruption_count"
    }
}

public struct CrossProviderTraceView: Codable, Equatable {
    public let schemaVersion: Int
    public let traceID: String
    public let state: CrossProviderTraceState
    public let observations: [OperationReceipt]
    public let metrics: CrossProviderTraceMetrics
    public let expiresAt: Date?

    public init(
        traceID: String,
        pending: CrossProviderPendingTrace,
        observations: [OperationReceipt],
        now: Date = Date(),
        schemaVersion: Int = 1
    ) {
        let ordered = observations.sorted { $0.startedAt < $1.startedAt }
        let root = ordered.first { $0.parentSpanID == nil }
        let completion = ordered.last { $0.parentSpanID != nil }
        let derivedState: CrossProviderTraceState
        if let completion {
            if completion.verificationResult == "passed" && completion.status == .succeeded {
                derivedState = .completed
            } else if completion.status == .failed {
                derivedState = .failed
            } else {
                derivedState = .blocked
            }
        } else if pending.expiresAt <= now {
            derivedState = .expired
        } else {
            derivedState = .open
        }
        self.schemaVersion = schemaVersion
        self.traceID = traceID
        self.state = derivedState
        self.observations = ordered
        self.metrics = CrossProviderTraceMetrics(
            macRoutingMilliseconds: Self.milliseconds(
                from: root?.startedAtMilliseconds,
                to: root?.completedAtMilliseconds
            ) ?? Self.milliseconds(
                from: root?.startedAt,
                to: root?.completedAt
            ) ?? 0,
            handoffToCompletionMilliseconds: Self.milliseconds(
                from: root?.completedAtMilliseconds,
                to: completion?.completedAtMilliseconds
            ) ?? Self.milliseconds(
                from: root?.completedAt,
                to: completion?.completedAt
            ),
            totalMilliseconds: Self.milliseconds(
                from: root?.startedAtMilliseconds,
                to: completion?.completedAtMilliseconds
            ) ?? Self.milliseconds(
                from: root?.startedAt,
                to: completion?.completedAt
            ),
            focusInterruptionCount: ordered.filter { $0.foregroundState == .changed }.count
        )
        self.expiresAt = completion == nil ? pending.expiresAt : nil
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }

    private static func milliseconds(from start: Int64?, to end: Int64?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(end - start))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case traceID = "trace_id"
        case state
        case observations
        case metrics
        case expiresAt = "expires_at"
    }
}
