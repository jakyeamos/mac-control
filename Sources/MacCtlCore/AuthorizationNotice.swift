import CryptoKit
import Foundation

public enum AuthorizationNoticeKind: String, Codable, Equatable {
    case keychain
    case credential
    case permission
    case other
}

public enum AuthorizationNoticeProvenance: String, Codable, Equatable {
    case attested
    case declared
    case unverified
}

public enum AuthorizationNoticeState: String, Codable, Equatable {
    case pending
    case resolved
    case expired
}

public enum AuthorizationNoticeOutcome: String, Codable, Equatable {
    case completed
    case failed
    case cancelled
    case timeout
    case unknown
}

/// Safe, caller-declared context for a sensitive request. This type has no
/// command, argument, prompt, password, token, or private-input field by
/// design. The daemon combines it with socket-observed identity below.
public struct AuthorizationNoticeRequest: Equatable {
    public let kind: AuthorizationNoticeKind
    public let project: String
    public let repository: String?
    public let taskID: String?
    public let taskTitle: String?
    public let threadID: String?
    public let threadTitle: String?
    public let sourceReference: String?
    public let requestingExecutable: String?
    public let requestingHelper: String?
    public let targetService: String?
    public let action: String
    public let summary: String
    public let expiresIn: TimeInterval

    public init(
        kind: AuthorizationNoticeKind = .other,
        project: String,
        repository: String? = nil,
        taskID: String? = nil,
        taskTitle: String? = nil,
        threadID: String? = nil,
        threadTitle: String? = nil,
        sourceReference: String? = nil,
        requestingExecutable: String? = nil,
        requestingHelper: String? = nil,
        targetService: String? = nil,
        action: String,
        summary: String,
        expiresIn: TimeInterval = 30
    ) {
        self.kind = kind
        self.project = project
        self.repository = repository
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.sourceReference = sourceReference
        self.requestingExecutable = requestingExecutable
        self.requestingHelper = requestingHelper
        self.targetService = targetService
        self.action = action
        self.summary = summary
        self.expiresIn = expiresIn
    }

    public static func from(params: [String: JSONValue]) throws -> AuthorizationNoticeRequest {
        let kind: AuthorizationNoticeKind
        if let rawKind = params["kind"]?.stringValue {
            guard let parsed = AuthorizationNoticeKind(rawValue: rawKind.lowercased()) else {
                throw AuthorizationNoticeStoreError.invalidField("kind")
            }
            kind = parsed
        } else {
            kind = .other
        }

        let project = try requiredString(params, key: "project")
        let action = try requiredString(params, key: "action")
        let summary = try requiredString(params, key: "summary")
        let expiresIn = params["expires_in"]?.doubleValue ?? params["ttl_seconds"]?.doubleValue ?? 30
        guard expiresIn.isFinite, expiresIn > 0 else {
            throw AuthorizationNoticeStoreError.invalidField("expires_in")
        }
        return AuthorizationNoticeRequest(
            kind: kind,
            project: project,
            repository: params["repository"]?.stringValue,
            taskID: params["task_id"]?.stringValue,
            taskTitle: params["task_title"]?.stringValue,
            threadID: params["thread_id"]?.stringValue,
            threadTitle: params["thread_title"]?.stringValue,
            sourceReference: params["source_reference"]?.stringValue,
            requestingExecutable: params["requesting_executable"]?.stringValue,
            requestingHelper: params["requesting_helper"]?.stringValue,
            targetService: params["target_service"]?.stringValue,
            action: action,
            summary: summary,
            expiresIn: expiresIn
        )
    }

    private static func requiredString(
        _ params: [String: JSONValue],
        key: String
    ) throws -> String {
        guard let value = params[key]?.stringValue, !value.isEmpty else {
            throw AuthorizationNoticeStoreError.invalidField(key)
        }
        return value
    }
}

public struct AuthorizationNoticeObservedIdentity: Codable, Equatable {
    public let userID: UInt32?
    public let groupID: UInt32?
    public let processID: Int32?
    public let executableName: String?
    public let signingIdentity: String?
    public let teamIdentifier: String?
    public let signatureValid: Bool?

    public init(peer: UnixSocketPeerIdentity) {
        userID = peer.userID
        groupID = peer.groupID
        processID = peer.processID
        executableName = peer.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        signingIdentity = peer.signingIdentity
        teamIdentifier = peer.teamIdentifier
        signatureValid = peer.signatureValid
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case groupID = "group_id"
        case processID = "process_id"
        case executableName = "executable_name"
        case signingIdentity = "signing_identity"
        case teamIdentifier = "team_identifier"
        case signatureValid = "signature_valid"
    }
}

public struct AuthorizationNotice: Codable, Equatable {
    public let requestID: String
    public let kind: AuthorizationNoticeKind
    public let project: String
    public let repository: String?
    public let taskID: String?
    public let taskTitle: String?
    public let threadID: String?
    public let threadTitle: String?
    public let sourceReference: String?
    public let requestingExecutable: String?
    public let requestingHelper: String?
    public let targetService: String?
    public let action: String
    public let summary: String
    public let createdAt: Date
    public let expiresAt: Date
    public let provenance: AuthorizationNoticeProvenance
    public let observedIdentity: AuthorizationNoticeObservedIdentity?
    public let boundProcessID: Int32?
    public let state: AuthorizationNoticeState
    public let outcome: AuthorizationNoticeOutcome?
    public let resolvedAt: Date?

    public init(
        requestID: String,
        kind: AuthorizationNoticeKind,
        project: String,
        repository: String?,
        taskID: String?,
        taskTitle: String?,
        threadID: String?,
        threadTitle: String?,
        sourceReference: String?,
        requestingExecutable: String?,
        requestingHelper: String?,
        targetService: String?,
        action: String,
        summary: String,
        createdAt: Date,
        expiresAt: Date,
        provenance: AuthorizationNoticeProvenance,
        observedIdentity: AuthorizationNoticeObservedIdentity?,
        boundProcessID: Int32? = nil,
        state: AuthorizationNoticeState = .pending,
        outcome: AuthorizationNoticeOutcome? = nil,
        resolvedAt: Date? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.project = project
        self.repository = repository
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.sourceReference = sourceReference
        self.requestingExecutable = requestingExecutable
        self.requestingHelper = requestingHelper
        self.targetService = targetService
        self.action = action
        self.summary = summary
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.provenance = provenance
        self.observedIdentity = observedIdentity
        self.boundProcessID = boundProcessID
        self.state = state
        self.outcome = outcome
        self.resolvedAt = resolvedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case kind
        case project
        case repository
        case taskID = "task_id"
        case taskTitle = "task_title"
        case threadID = "thread_id"
        case threadTitle = "thread_title"
        case sourceReference = "source_reference"
        case requestingExecutable = "requesting_executable"
        case requestingHelper = "requesting_helper"
        case targetService = "target_service"
        case action
        case summary
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case provenance
        case observedIdentity = "observed_identity"
        case boundProcessID = "bound_process_id"
        case state
        case outcome
        case resolvedAt = "resolved_at"
    }

    fileprivate func bound(to processID: Int32) -> AuthorizationNotice {
        AuthorizationNotice(
            requestID: requestID,
            kind: kind,
            project: project,
            repository: repository,
            taskID: taskID,
            taskTitle: taskTitle,
            threadID: threadID,
            threadTitle: threadTitle,
            sourceReference: sourceReference,
            requestingExecutable: requestingExecutable,
            requestingHelper: requestingHelper,
            targetService: targetService,
            action: action,
            summary: summary,
            createdAt: createdAt,
            expiresAt: expiresAt,
            provenance: provenance,
            observedIdentity: observedIdentity,
            boundProcessID: processID,
            state: state,
            outcome: outcome,
            resolvedAt: resolvedAt
        )
    }

    fileprivate func resolved(
        outcome: AuthorizationNoticeOutcome,
        at date: Date
    ) -> AuthorizationNotice {
        AuthorizationNotice(
            requestID: requestID,
            kind: kind,
            project: project,
            repository: repository,
            taskID: taskID,
            taskTitle: taskTitle,
            threadID: threadID,
            threadTitle: threadTitle,
            sourceReference: sourceReference,
            requestingExecutable: requestingExecutable,
            requestingHelper: requestingHelper,
            targetService: targetService,
            action: action,
            summary: summary,
            createdAt: createdAt,
            expiresAt: expiresAt,
            provenance: provenance,
            observedIdentity: observedIdentity,
            boundProcessID: boundProcessID,
            state: .resolved,
            outcome: outcome,
            resolvedAt: date
        )
    }

    fileprivate func expired() -> AuthorizationNotice {
        AuthorizationNotice(
            requestID: requestID,
            kind: kind,
            project: project,
            repository: repository,
            taskID: taskID,
            taskTitle: taskTitle,
            threadID: threadID,
            threadTitle: threadTitle,
            sourceReference: sourceReference,
            requestingExecutable: requestingExecutable,
            requestingHelper: requestingHelper,
            targetService: targetService,
            action: action,
            summary: summary,
            createdAt: createdAt,
            expiresAt: expiresAt,
            provenance: provenance,
            observedIdentity: observedIdentity,
            boundProcessID: boundProcessID,
            state: .expired,
            outcome: outcome,
            resolvedAt: resolvedAt
        )
    }
}

public struct AuthorizationNoticePrepareResult: Codable, Equatable {
    public let notice: AuthorizationNotice
    public let deduplicated: Bool

    public init(notice: AuthorizationNotice, deduplicated: Bool) {
        self.notice = notice
        self.deduplicated = deduplicated
    }
}

public enum AuthorizationNoticeStoreError: Error, LocalizedError, Equatable {
    case invalidField(String)
    case invalidSourceReference
    case notFound
    case expired
    case alreadyResolved
    case alreadyBound
    case storeFull

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field):
            return "Authorization notice field is invalid: \(field)"
        case .invalidSourceReference:
            return "source_reference must be an allowlisted codex://thread, codex://task, or codex://source reference"
        case .notFound:
            return "Authorization notice was not found"
        case .expired:
            return "Authorization notice expired before it was completed"
        case .alreadyResolved:
            return "Authorization notice has already been resolved"
        case .alreadyBound:
            return "Authorization notice has already been bound to a process"
        case .storeFull:
            return "Authorization notice store is full of active requests"
        }
    }
}

/// Owner-local, bounded, short-lived notice storage. Resolved records are
/// retained until their expiry so a duplicate resolve cannot replay as a new
/// completion. No native macOS approval operation is exposed here.
public final class AuthorizationNoticeStore {
    private struct Entry {
        let fingerprint: String
        var notice: AuthorizationNotice
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let now: () -> Date
    private let maximumEntries: Int
    private let maximumTTL: TimeInterval
    private let defaultTTL: TimeInterval

    public init(
        maximumEntries: Int = 64,
        defaultTTL: TimeInterval = 30,
        maximumTTL: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.defaultTTL = min(max(defaultTTL, 1), maximumTTL)
        self.maximumTTL = max(maximumTTL, 1)
        self.now = now
    }

    public func prepare(
        _ request: AuthorizationNoticeRequest,
        observedPeer: UnixSocketPeerIdentity? = nil,
        requestID: String = UUID().uuidString
    ) throws -> AuthorizationNoticePrepareResult {
        let sanitized = try sanitize(request)
        let currentDate = now()
        lock.lock()
        defer { lock.unlock() }
        expireEntriesLocked(at: currentDate)

        let observed = observedPeer.map(AuthorizationNoticeObservedIdentity.init)
        let provenance = Self.provenance(for: sanitized, observedPeer: observedPeer)
        let fingerprint = Self.fingerprint(
            request: sanitized,
            observedPeer: observedPeer,
            provenance: provenance
        )
        if let existing = entries.values.first(where: {
            $0.fingerprint == fingerprint && $0.notice.state == .pending
        }) {
            return AuthorizationNoticePrepareResult(notice: existing.notice, deduplicated: true)
        }

        makeRoomLocked(at: currentDate)
        guard entries.count < maximumEntries else {
            throw AuthorizationNoticeStoreError.storeFull
        }

        let ttl = min(
            max(sanitized.expiresIn.isFinite ? sanitized.expiresIn : defaultTTL, 1),
            maximumTTL
        )
        let notice = AuthorizationNotice(
            requestID: requestID,
            kind: sanitized.kind,
            project: sanitized.project,
            repository: sanitized.repository,
            taskID: sanitized.taskID,
            taskTitle: sanitized.taskTitle,
            threadID: sanitized.threadID,
            threadTitle: sanitized.threadTitle,
            sourceReference: sanitized.sourceReference,
            requestingExecutable: sanitized.requestingExecutable,
            requestingHelper: sanitized.requestingHelper,
            targetService: sanitized.targetService,
            action: sanitized.action,
            summary: sanitized.summary,
            createdAt: currentDate,
            expiresAt: currentDate.addingTimeInterval(ttl),
            provenance: provenance,
            observedIdentity: observed
        )
        entries[notice.requestID] = Entry(fingerprint: fingerprint, notice: notice)
        return AuthorizationNoticePrepareResult(notice: notice, deduplicated: false)
    }

    public func bind(requestID: String, processID: Int32) throws -> AuthorizationNotice {
        guard !requestID.isEmpty, processID > 0 else {
            throw AuthorizationNoticeStoreError.invalidField("request_id/process_id")
        }
        let currentDate = now()
        lock.lock()
        defer { lock.unlock() }
        expireEntriesLocked(at: currentDate)
        guard let entry = entries[requestID] else {
            throw AuthorizationNoticeStoreError.notFound
        }
        guard entry.notice.state == .pending else {
            throw entry.notice.state == .expired
                ? AuthorizationNoticeStoreError.expired
                : AuthorizationNoticeStoreError.alreadyResolved
        }
        guard entry.notice.expiresAt > currentDate else {
            entries[requestID]?.notice = entry.notice.expired()
            throw AuthorizationNoticeStoreError.expired
        }
        guard entry.notice.boundProcessID == nil else {
            throw AuthorizationNoticeStoreError.alreadyBound
        }
        let updated = entry.notice.bound(to: processID)
        entries[requestID]?.notice = updated
        return updated
    }

    public func resolve(
        requestID: String,
        outcome: AuthorizationNoticeOutcome
    ) throws -> AuthorizationNotice {
        guard !requestID.isEmpty else {
            throw AuthorizationNoticeStoreError.invalidField("request_id")
        }
        let currentDate = now()
        lock.lock()
        defer { lock.unlock() }
        expireEntriesLocked(at: currentDate)
        guard let entry = entries[requestID] else {
            throw AuthorizationNoticeStoreError.notFound
        }
        switch entry.notice.state {
        case .resolved:
            throw AuthorizationNoticeStoreError.alreadyResolved
        case .expired:
            throw AuthorizationNoticeStoreError.expired
        case .pending:
            guard entry.notice.expiresAt > currentDate else {
                entries[requestID]?.notice = entry.notice.expired()
                throw AuthorizationNoticeStoreError.expired
            }
            let updated = entry.notice.resolved(outcome: outcome, at: currentDate)
            entries[requestID]?.notice = updated
            return updated
        }
    }

    public func list() -> [AuthorizationNotice] {
        let currentDate = now()
        lock.lock()
        defer { lock.unlock() }
        expireEntriesLocked(at: currentDate)
        return entries.values
            .map(\.notice)
            .filter { $0.state == .pending && $0.expiresAt > currentDate }
            .sorted {
                if $0.expiresAt == $1.expiresAt { return $0.requestID < $1.requestID }
                return $0.expiresAt < $1.expiresAt
            }
    }

    public func pendingCount() -> Int {
        list().count
    }

    private func sanitize(_ request: AuthorizationNoticeRequest) throws -> AuthorizationNoticeRequest {
        let project = try Self.safeText(request.project, field: "project", limit: 120, required: true)
        let action = try Self.safeText(request.action, field: "action", limit: 100, required: true)
        let summary = try Self.safeText(request.summary, field: "summary", limit: 200, required: true)
        let sourceReference: String?
        if let rawSource = request.sourceReference {
            guard let safeSource = Self.safeSourceReference(rawSource) else {
                throw AuthorizationNoticeStoreError.invalidSourceReference
            }
            sourceReference = safeSource
        } else {
            sourceReference = nil
        }
        return AuthorizationNoticeRequest(
            kind: request.kind,
            project: project,
            repository: try Self.optionalSafeText(request.repository, field: "repository", limit: 160),
            taskID: try Self.optionalSafeText(request.taskID, field: "task_id", limit: 128),
            taskTitle: try Self.optionalSafeText(request.taskTitle, field: "task_title", limit: 160),
            threadID: try Self.optionalSafeText(request.threadID, field: "thread_id", limit: 128),
            threadTitle: try Self.optionalSafeText(request.threadTitle, field: "thread_title", limit: 160),
            sourceReference: sourceReference,
            requestingExecutable: Self.safeExecutable(request.requestingExecutable),
            requestingHelper: Self.safeExecutable(request.requestingHelper),
            targetService: try Self.optionalSafeText(request.targetService, field: "target_service", limit: 120),
            action: action,
            summary: summary,
            expiresIn: request.expiresIn
        )
    }

    private func expireEntriesLocked(at date: Date) {
        for (requestID, entry) in entries where entry.notice.state == .pending && entry.notice.expiresAt <= date {
            entries[requestID]?.notice = entry.notice.expired()
        }
        // Resolved and expired entries are only replay guards. Retain them for
        // one maximum-TTL window so an immediate retry returns an explicit
        // replay/expiry result, then remove them to limit metadata retention.
        let retentionCutoff = date.addingTimeInterval(-maximumTTL)
        entries = entries.filter { $0.value.notice.expiresAt > retentionCutoff }
    }

    private func makeRoomLocked(at date: Date) {
        expireEntriesLocked(at: date)
        guard entries.count >= maximumEntries else { return }
        let removable = entries.values
            .filter { $0.notice.state != .pending }
            .sorted { $0.notice.createdAt < $1.notice.createdAt }
        for entry in removable where entries.count >= maximumEntries {
            entries.removeValue(forKey: entry.notice.requestID)
        }
    }

    private static func provenance(
        for request: AuthorizationNoticeRequest,
        observedPeer: UnixSocketPeerIdentity?
    ) -> AuthorizationNoticeProvenance {
        guard let observedPeer,
              let observedPath = observedPeer.executablePath,
              !observedPath.isEmpty else {
            return .unverified
        }
        let observedName = URL(fileURLWithPath: observedPath).lastPathComponent.lowercased()
        let declaredNames = [request.requestingExecutable, request.requestingHelper]
            .compactMap { $0?.lowercased() }
        if declaredNames.isEmpty {
            return .declared
        }
        return declaredNames.contains(observedName) ? .attested : .unverified
    }

    private static func fingerprint(
        request: AuthorizationNoticeRequest,
        observedPeer: UnixSocketPeerIdentity?,
        provenance: AuthorizationNoticeProvenance
    ) -> String {
        let observedProcessID = observedPeer?.processID.map { String($0) } ?? ""
        let values: [String] = [
            request.kind.rawValue,
            request.project,
            request.repository ?? "",
            request.taskID ?? "",
            request.taskTitle ?? "",
            request.threadID ?? "",
            request.threadTitle ?? "",
            request.sourceReference ?? "",
            request.requestingExecutable ?? "",
            request.requestingHelper ?? "",
            request.targetService ?? "",
            request.action,
            request.summary,
            provenance.rawValue,
            observedProcessID,
            observedPeer?.executablePath ?? "",
            observedPeer?.signingIdentity ?? "",
            observedPeer?.teamIdentifier ?? ""
        ]
        let joinedValues = values.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(joinedValues.utf8))
        return digest.map { byte in String(format: "%02x", byte) }.joined()
    }

    private static func safeText(
        _ value: String,
        field: String,
        limit: Int,
        required: Bool
    ) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AuthorizationNoticeStoreError.invalidField(field)
        }
        let collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let redacted = redactSensitiveText(collapsed)
        let clipped = String(redacted.prefix(limit))
        if required && clipped.isEmpty {
            throw AuthorizationNoticeStoreError.invalidField(field)
        }
        return clipped
    }

    private static func optionalSafeText(
        _ value: String?,
        field: String,
        limit: Int
    ) throws -> String? {
        guard let value else { return nil }
        let safe = try safeText(value, field: field, limit: limit, required: false)
        return safe.isEmpty ? nil : safe
    }

    private static func safeExecutable(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let name = URL(fileURLWithPath: value).lastPathComponent
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return String(redactSensitiveText(name).prefix(96))
    }

    private static func safeSourceReference(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme == "codex",
              let host = components.host,
              ["thread", "task", "source"].contains(host),
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1,
              let opaque = parts.first,
              opaque.count <= 128,
              opaque.allSatisfy({ $0.isLetter || $0.isNumber || ".-_~".contains($0) }) else {
            return nil
        }
        return "codex://\(host)/\(opaque)"
    }

    private static func redactSensitiveText(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)(ghp|github_pat|xox[baprs])-?[A-Za-z0-9_-]+"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return result
    }
}
