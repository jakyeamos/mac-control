import Foundation

public enum ExternalApprovalState: String, Codable, Equatable {
    case pending
    case approved
    case denied
    case consumed
    case expired
}

public enum ExternalApprovalStoreError: Error, LocalizedError, Equatable {
    case notFound
    case expired
    case alreadyUsed
    case denied
    case pending
    case mismatch

    public var errorDescription: String? {
        switch self {
        case .notFound: return "External approval was not found"
        case .expired: return "External approval has expired"
        case .alreadyUsed: return "External approval was already consumed"
        case .denied: return "External approval was denied"
        case .pending: return "External approval is still pending"
        case .mismatch: return "External approval did not match the exact provider plan"
        }
    }
}

public struct ExternalApprovalRequest: Codable, Equatable {
    public let record: ApprovalRecord
    public let provider: String
    public let providerInstanceID: String
    public let planID: String
    public let planDigest: String
    public let state: ExternalApprovalState

    public init(
        record: ApprovalRecord,
        provider: String,
        providerInstanceID: String,
        planID: String,
        planDigest: String,
        state: ExternalApprovalState
    ) {
        self.record = record
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.planID = planID
        self.planDigest = planDigest
        self.state = state
    }
}

/// Session-only broker for plans owned and executed by another local provider.
/// The provider receives an operation identifier and decision state, never the
/// private control-center token used by the menu-bar UI.
public final class ExternalApprovalStore {
    private struct Entry {
        let record: ApprovalRecord
        let provider: String
        let providerInstanceID: String
        let planID: String
        let planDigest: String
        var state: ExternalApprovalState
    }

    private let lifetime: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var entriesByToken: [String: Entry] = [:]
    private var tokenByOperationID: [String: String] = [:]
    private var tokenByBinding: [String: String] = [:]

    public init(lifetime: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.lifetime = min(max(lifetime, 0.001), 120)
        self.now = now
    }

    public func prepare(
        provider: String,
        providerInstanceID: String,
        planID: String,
        planDigest: String,
        summary: String,
        risk: RiskLevel
    ) -> ExternalApprovalRequest {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        let binding = bindingKey(
            provider: provider,
            providerInstanceID: providerInstanceID,
            planID: planID,
            planDigest: planDigest
        )
        if let token = tokenByBinding[binding], let entry = entriesByToken[token] {
            return request(entry)
        }
        let token = "mce_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let operationID = UUID().uuidString
        let record = ApprovalRecord(
            token: token,
            operationID: operationID,
            workflowID: planID,
            summary: summary,
            risk: risk,
            focusPolicy: .background,
            keyboardFreezeRequired: false,
            handoffTarget: nil,
            expiresAt: now().addingTimeInterval(lifetime),
            provider: provider,
            planDigest: planDigest
        )
        let entry = Entry(
            record: record,
            provider: provider,
            providerInstanceID: providerInstanceID,
            planID: planID,
            planDigest: planDigest,
            state: .pending
        )
        entriesByToken[token] = entry
        tokenByOperationID[operationID] = token
        tokenByBinding[binding] = token
        return request(entry)
    }

    public func list() -> [ApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        return entriesByToken.values
            .filter { $0.state == .pending }
            .map(\.record)
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    public func record(for token: String) -> ApprovalRecord? {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        return entriesByToken[token]?.record
    }

    public func status(operationID: String) throws -> ExternalApprovalRequest {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        guard let token = tokenByOperationID[operationID], let entry = entriesByToken[token] else {
            throw ExternalApprovalStoreError.notFound
        }
        return request(entry)
    }

    public func approve(token: String) throws -> ExternalApprovalRequest {
        try transitionPending(token: token, to: .approved)
    }

    public func deny(token: String) throws -> ExternalApprovalRequest {
        try transitionPending(token: token, to: .denied)
    }

    public func consume(
        operationID: String,
        provider: String,
        providerInstanceID: String,
        planID: String,
        planDigest: String
    ) throws -> ExternalApprovalRequest {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        guard let token = tokenByOperationID[operationID], var entry = entriesByToken[token] else {
            throw ExternalApprovalStoreError.notFound
        }
        guard entry.provider == provider,
              entry.providerInstanceID == providerInstanceID,
              entry.planID == planID,
              entry.planDigest == planDigest else {
            throw ExternalApprovalStoreError.mismatch
        }
        switch entry.state {
        case .pending: throw ExternalApprovalStoreError.pending
        case .denied: throw ExternalApprovalStoreError.denied
        case .expired: throw ExternalApprovalStoreError.expired
        case .consumed: throw ExternalApprovalStoreError.alreadyUsed
        case .approved:
            entry.state = .consumed
            entriesByToken[token] = entry
            return request(entry)
        }
    }

    private func transitionPending(
        token: String,
        to state: ExternalApprovalState
    ) throws -> ExternalApprovalRequest {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        guard var entry = entriesByToken[token] else { throw ExternalApprovalStoreError.notFound }
        if entry.state != .pending {
            switch entry.state {
            case .expired: throw ExternalApprovalStoreError.expired
            case .denied: throw ExternalApprovalStoreError.denied
            case .approved, .consumed: throw ExternalApprovalStoreError.alreadyUsed
            case .pending: break
            }
        }
        entry.state = state
        entriesByToken[token] = entry
        return request(entry)
    }

    private func expireLocked() {
        let current = now()
        for token in entriesByToken.keys {
            guard var entry = entriesByToken[token],
                  [.pending, .approved].contains(entry.state),
                  entry.record.expiresAt <= current else { continue }
            entry.state = .expired
            entriesByToken[token] = entry
        }
    }

    private func request(_ entry: Entry) -> ExternalApprovalRequest {
        ExternalApprovalRequest(
            record: entry.record,
            provider: entry.provider,
            providerInstanceID: entry.providerInstanceID,
            planID: entry.planID,
            planDigest: entry.planDigest,
            state: entry.state
        )
    }

    private func bindingKey(
        provider: String,
        providerInstanceID: String,
        planID: String,
        planDigest: String
    ) -> String {
        [provider, providerInstanceID, planID, planDigest].joined(separator: "\u{0}")
    }
}
