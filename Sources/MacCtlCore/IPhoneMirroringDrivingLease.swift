import Foundation

public enum IPhoneMirroringDrivingLeaseError: Error, LocalizedError, Equatable {
    case alreadyHeld
    case required
    case invalidOrExpired

    public var errorDescription: String? {
        switch self {
        case .alreadyHeld:
            return "An iPhone Mirroring driving lease is already held"
        case .required:
            return "An explicit user-held iPhone Mirroring driving lease is required before synthetic navigation"
        case .invalidOrExpired:
            return "The iPhone Mirroring driving lease is invalid or expired"
        }
    }
}

public final class IPhoneMirroringDrivingLease {
    public let token: String
    public let expiresAt: Date
    private let held: () -> Bool

    fileprivate init(token: String, expiresAt: Date, held: @escaping () -> Bool) {
        self.token = token
        self.expiresAt = expiresAt
        self.held = held
    }

    public var isHeld: Bool {
        held()
    }

    func requireHeld() throws {
        guard isHeld else {
            throw IPhoneMirroringDrivingLeaseError.invalidOrExpired
        }
    }
}

public final class IPhoneMirroringDrivingLeaseStore {
    public static let defaultLifetime: TimeInterval = 30

    private struct ActiveLease {
        let token: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let lifetime: TimeInterval
    private let now: () -> Date
    private var activeLease: ActiveLease?

    public init(
        lifetime: TimeInterval = IPhoneMirroringDrivingLeaseStore.defaultLifetime,
        now: @escaping () -> Date = { Date() }
    ) {
        self.lifetime = max(lifetime, 0.001)
        self.now = now
    }

    public var lifetimeSeconds: TimeInterval {
        lifetime
    }

    public func acquire() throws -> IPhoneMirroringDrivingLease {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        purgeExpired(at: current)
        guard activeLease == nil else {
            throw IPhoneMirroringDrivingLeaseError.alreadyHeld
        }
        let active = ActiveLease(
            token: UUID().uuidString,
            expiresAt: current.addingTimeInterval(lifetime)
        )
        activeLease = active
        return makeLease(active)
    }

    public func lease(for token: String) -> IPhoneMirroringDrivingLease? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: now())
        guard let activeLease, activeLease.token == token else { return nil }
        return makeLease(activeLease)
    }

    @discardableResult
    public func release(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: now())
        guard activeLease?.token == token else { return false }
        activeLease = nil
        return true
    }

    private func makeLease(_ active: ActiveLease) -> IPhoneMirroringDrivingLease {
        IPhoneMirroringDrivingLease(
            token: active.token,
            expiresAt: active.expiresAt,
            held: { [weak self] in
                self?.isHeld(token: active.token, expiresAt: active.expiresAt) ?? false
            }
        )
    }

    private func isHeld(token: String, expiresAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        purgeExpired(at: current)
        guard let activeLease else { return false }
        return activeLease.token == token
            && activeLease.expiresAt == expiresAt
            && activeLease.expiresAt > current
    }

    private func purgeExpired(at date: Date) {
        if let activeLease, activeLease.expiresAt <= date {
            self.activeLease = nil
        }
    }
}
