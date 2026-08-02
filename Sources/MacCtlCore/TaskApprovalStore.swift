import Foundation

public struct PreparedTaskApproval {
    public let record: ApprovalRecord
    public let plan: TaskPlan
    public let ephemeralInputs: [String: String]
    public let planDigest: String

    public init(
        record: ApprovalRecord,
        plan: TaskPlan,
        ephemeralInputs: [String: String],
        planDigest: String
    ) {
        self.record = record
        self.plan = plan
        self.ephemeralInputs = ephemeralInputs
        self.planDigest = planDigest
    }
}
public enum TaskApprovalStoreError: Error, LocalizedError, Equatable {
    case notFound
    case expired
    case alreadyUsed
    case mismatch

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Task approval token was not found"
        case .expired: return "Task approval token has expired"
        case .alreadyUsed: return "Task approval token was already used"
        case .mismatch: return "Task approval token does not match the exact task plan"
        }
    }
}

/// Task approvals are kept separate from legacy workflow approvals so adding
/// checkpoint resume cannot change the older prepare/approve/run semantics.
public final class TaskApprovalStore {
    private enum State {
        case pending
        case approved
        case denied
        case consumed
        case expired
    }

    private struct Entry {
        let prepared: PreparedTaskApproval
        var state: State
    }

    private let lifetime: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(lifetime: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.lifetime = min(max(lifetime, 0.001), 300)
        self.now = now
    }

    public func prepare(
        plan: TaskPlan,
        ephemeralInputs: [String: String] = [:],
        operationID: String = UUID().uuidString
    ) -> PreparedTaskApproval {
        let token = "mct_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let record = ApprovalRecord(
            token: token,
            operationID: operationID,
            workflowID: plan.id,
            summary: plan.summary,
            risk: plan.steps.map(\.risk).max(by: { rank($0) < rank($1) }) ?? .safe,
            focusPolicy: plan.focusPolicy,
            expiresAt: now().addingTimeInterval(lifetime)
        )
        let prepared = PreparedTaskApproval(
            record: record,
            plan: plan,
            ephemeralInputs: ephemeralInputs,
            planDigest: TaskPlan.digest(plan, ephemeralInputs: ephemeralInputs)
        )
        lock.lock()
        entries[token] = Entry(prepared: prepared, state: .pending)
        lock.unlock()
        return prepared
    }

    public func list() -> [ApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        expirePendingLocked()
        return entries.values
            .filter { $0.state == .pending }
            .map(\.prepared.record)
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    public func record(for token: String) -> ApprovalRecord? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.prepared.record
    }

    public func approve(token: String) throws -> PreparedTaskApproval {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[token] else { throw TaskApprovalStoreError.notFound }
        guard entry.state == .pending else {
            if entry.state == .expired { throw TaskApprovalStoreError.expired }
            throw TaskApprovalStoreError.alreadyUsed
        }
        guard entry.prepared.record.expiresAt > now() else {
            entry.state = .expired
            entries[token] = entry
            throw TaskApprovalStoreError.expired
        }
        entry.state = .approved
        entries[token] = entry
        return entry.prepared
    }

    public func deny(token: String) throws -> ApprovalRecord {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[token] else { throw TaskApprovalStoreError.notFound }
        guard entry.state == .pending else {
            if entry.state == .expired { throw TaskApprovalStoreError.expired }
            throw TaskApprovalStoreError.alreadyUsed
        }
        guard entry.prepared.record.expiresAt > now() else {
            entry.state = .expired
            entries[token] = entry
            throw TaskApprovalStoreError.expired
        }
        entry.state = .denied
        entries[token] = entry
        return entry.prepared.record
    }

    /// Consuming is a one-way boundary.  Resume therefore always requires a
    /// newly prepared and approved token bound to the remaining plan.
    public func consume(
        token: String,
        plan: TaskPlan,
        ephemeralInputs: [String: String]
    ) throws -> PreparedTaskApproval {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[token] else { throw TaskApprovalStoreError.notFound }
        guard entry.state == .approved else {
            if entry.state == .expired { throw TaskApprovalStoreError.expired }
            throw TaskApprovalStoreError.alreadyUsed
        }
        guard entry.prepared.record.expiresAt > now() else {
            entry.state = .expired
            entries[token] = entry
            throw TaskApprovalStoreError.expired
        }
        let digest = TaskPlan.digest(plan, ephemeralInputs: ephemeralInputs)
        guard digest == entry.prepared.planDigest else {
            throw TaskApprovalStoreError.mismatch
        }
        entry.state = .consumed
        entries[token] = entry
        return entry.prepared
    }

    private func expirePendingLocked() {
        let current = now()
        for token in entries.keys {
            guard let entry = entries[token], entry.state == .pending else { continue }
            if entry.prepared.record.expiresAt <= current {
                entries[token] = Entry(prepared: entry.prepared, state: .expired)
            }
        }
    }

    private func rank(_ risk: RiskLevel) -> Int {
        switch risk {
        case .safe: return 0
        case .reversible: return 1
        case .sensitive: return 2
        }
    }
}
