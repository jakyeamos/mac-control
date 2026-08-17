import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

public enum KeyboardLeaseScope: String, Codable, Equatable, CaseIterable {
    case app
    case session
}

public enum KeyboardPhysicalInputMode: String, Codable, Equatable, CaseIterable {
    case shared
    case suppressed
}

public enum KeyboardNavigationMode: String, Codable, Equatable, CaseIterable {
    case unchanged
    case navigation
}

public enum KeyboardCommand: String, Codable, Equatable, CaseIterable {
    case nextControl = "next-control"
    case previousControl = "previous-control"
    case activate
    case contextMenu = "context-menu"
    case nextItem = "next-item"
    case previousItem = "previous-item"
    case search
    case windowChooser = "window-chooser"
    case applicationChooser = "application-chooser"
    case menuBar = "menu-bar"
    case dock
    case controlCenter = "control-center"
    case notificationCenter = "notification-center"
    case pointerToFocus = "pointer-to-focus"
    case commandsHelp = "commands-help"
    case passThrough = "pass-through"

    public var keySpecifications: [String] {
        switch self {
        case .nextControl:
            return ["tab"]
        case .previousControl:
            return ["shift+tab"]
        case .activate:
            return ["space"]
        case .contextMenu:
            return ["shift+f10"]
        case .nextItem:
            return ["ctrl+tab"]
        case .previousItem:
            return ["ctrl+shift+tab"]
        case .search:
            return ["tab", "f"]
        case .windowChooser:
            return ["tab", "w"]
        case .applicationChooser:
            return ["tab", "a"]
        case .menuBar:
            return ["fn+ctrl+f2"]
        case .dock:
            return ["fn+a"]
        case .controlCenter:
            return ["fn+c"]
        case .notificationCenter:
            return ["fn+n"]
        case .pointerToFocus:
            return ["tab", "c"]
        case .commandsHelp:
            return ["tab", "h"]
        case .passThrough:
            return ["ctrl+option+cmd+p"]
        }
    }

    public var expectsFocusChange: Bool {
        switch self {
        case .activate, .contextMenu, .passThrough:
            return false
        default:
            return true
        }
    }

    public static func resolve(_ value: String) throws -> KeyboardCommand {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard let command = KeyboardCommand(rawValue: normalized) else {
            throw KeyboardControlError.invalidCommand(value)
        }
        return command
    }
}

public struct KeyboardDriveLease: Codable, Equatable {
    public let token: String
    public let scope: KeyboardLeaseScope
    public let physicalInputMode: KeyboardPhysicalInputMode
    public let navigationMode: KeyboardNavigationMode
    public let passThroughTransitionOwned: Bool
    /// Only presence is retained; the human-supplied reason never enters a
    /// lease response, receipt, or log.
    public let freezeReasonProvided: Bool
    public let application: AppInfo?
    public let acquiredAt: Date
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case token
        case scope
        case physicalInputMode
        case navigationMode
        case passThroughTransitionOwned
        case freezeReasonProvided
        case application
        case acquiredAt
        case expiresAt
    }

    public init(
        token: String,
        scope: KeyboardLeaseScope,
        application: AppInfo?,
        acquiredAt: Date,
        expiresAt: Date,
        physicalInputMode: KeyboardPhysicalInputMode = .shared,
        freezeReasonProvided: Bool = false,
        navigationMode: KeyboardNavigationMode = .unchanged,
        passThroughTransitionOwned: Bool = false
    ) {
        self.token = token
        self.scope = scope
        self.physicalInputMode = physicalInputMode
        self.navigationMode = navigationMode
        self.passThroughTransitionOwned = passThroughTransitionOwned
        self.freezeReasonProvided = freezeReasonProvided
        self.application = application
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        scope = try container.decode(KeyboardLeaseScope.self, forKey: .scope)
        physicalInputMode = try container.decodeIfPresent(
            KeyboardPhysicalInputMode.self,
            forKey: .physicalInputMode
        ) ?? .shared
        navigationMode = try container.decodeIfPresent(
            KeyboardNavigationMode.self,
            forKey: .navigationMode
        ) ?? .unchanged
        passThroughTransitionOwned = try container.decodeIfPresent(
            Bool.self,
            forKey: .passThroughTransitionOwned
        ) ?? false
        freezeReasonProvided = try container.decodeIfPresent(Bool.self, forKey: .freezeReasonProvided) ?? false
        application = try container.decodeIfPresent(AppInfo.self, forKey: .application)
        acquiredAt = try container.decode(Date.self, forKey: .acquiredAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

public struct KeyboardAccessStatus: Codable, Equatable {
    public let fullKeyboardAccessEnabled: Bool?
    public let permissionContext: String
    public let permissions: [PermissionStatus]
    public let setupPath: String
    public let activeLease: KeyboardDriveLease?
    public let navigationRestorationPending: Bool

    private enum CodingKeys: String, CodingKey {
        case fullKeyboardAccessEnabled
        case permissionContext
        case permissions
        case setupPath
        case activeLease
        case navigationRestorationPending
    }

    public init(
        fullKeyboardAccessEnabled: Bool?,
        permissionContext: String,
        permissions: [PermissionStatus],
        setupPath: String = KeyboardAccessController.settingsPath,
        activeLease: KeyboardDriveLease? = nil,
        navigationRestorationPending: Bool = false
    ) {
        self.fullKeyboardAccessEnabled = fullKeyboardAccessEnabled
        self.permissionContext = permissionContext
        self.permissions = permissions
        self.setupPath = setupPath
        self.activeLease = activeLease
        self.navigationRestorationPending = navigationRestorationPending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullKeyboardAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .fullKeyboardAccessEnabled)
        permissionContext = try container.decodeIfPresent(String.self, forKey: .permissionContext) ?? "unknown"
        permissions = try container.decodeIfPresent([PermissionStatus].self, forKey: .permissions)
            ?? PermissionDiagnostics.unknownReport()
        setupPath = try container.decodeIfPresent(String.self, forKey: .setupPath)
            ?? KeyboardAccessController.settingsPath
        activeLease = try container.decodeIfPresent(KeyboardDriveLease.self, forKey: .activeLease)
        navigationRestorationPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .navigationRestorationPending
        ) ?? false
    }

    public static func unknown(permissionContext: String = "unknown") -> KeyboardAccessStatus {
        KeyboardAccessStatus(
            fullKeyboardAccessEnabled: nil,
            permissionContext: permissionContext,
            permissions: PermissionDiagnostics.unknownReport()
        )
    }
}

public struct KeyboardFreezeStatus: Codable, Equatable {
    public let active: Bool
    public let token: String?
    public let scope: KeyboardLeaseScope?
    public let expiresAt: Date?
    public let reasonPresent: Bool
    public let permissions: [PermissionStatus]

    public init(
        active: Bool,
        token: String?,
        scope: KeyboardLeaseScope?,
        expiresAt: Date?,
        reasonPresent: Bool,
        permissions: [PermissionStatus]
    ) {
        self.active = active
        self.token = token
        self.scope = scope
        self.expiresAt = expiresAt
        self.reasonPresent = reasonPresent
        self.permissions = permissions
    }
}

public struct KeyboardSetupInfo: Codable, Equatable {
    public let settingsPath: String
    public let instructions: [String]
    public let recovery: String

    public init(
        settingsPath: String = KeyboardAccessController.settingsPath,
        instructions: [String] = [
            "Open System Settings.",
            "Choose Accessibility, then Motor, then Keyboard.",
            "Turn on Full Keyboard Access and select All controls."
        ],
        recovery: String = "If the setting does not take effect, toggle Full Keyboard Access off and on, then restart the target app."
    ) {
        self.settingsPath = settingsPath
        self.instructions = instructions
        self.recovery = recovery
    }
}

public struct FocusedElementSnapshot: Codable, Equatable {
    public let targetApplication: AppInfo
    public let role: String?
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    /// A redacted structural identity for controls that expose no stable AX
    /// identifier or title. This is deliberately a digest, never an AX
    /// element reference or raw value.
    public let identityFingerprint: String?

    public init(
        targetApplication: AppInfo,
        role: String?,
        subrole: String?,
        identifier: String?,
        title: String?,
        identityFingerprint: String? = nil
    ) {
        self.targetApplication = targetApplication
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.identityFingerprint = identityFingerprint
    }
}

public protocol FocusedElementInspecting {
    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot
}

public struct KeyboardActionReport: Codable, Equatable {
    public let action: String
    public let command: KeyboardCommand?
    public let keyCount: Int
    public let targetApplication: AppInfo
    public let leaseExpiresAt: Date

    public init(
        action: String,
        command: KeyboardCommand?,
        keyCount: Int,
        targetApplication: AppInfo,
        leaseExpiresAt: Date
    ) {
        self.action = action
        self.command = command
        self.keyCount = keyCount
        self.targetApplication = targetApplication
        self.leaseExpiresAt = leaseExpiresAt
    }
}

public enum KeyboardControlError: Error, LocalizedError, Equatable {
    case confirmationRequired
    case leaseRequired
    case fullKeyboardAccessDisabled
    case enableVerificationFailed
    case invalidCommand(String)
    case invalidSequence(String)
    case printableKeyRejected(String)
    case sequenceTooLong
    case repetitionLimitExceeded
    case invalidInterKeyDelay
    case permissionDenied(String)
    case foregroundUnavailable
    case appScopeMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Explicit confirmation is required for this keyboard operation"
        case .leaseRequired:
            return "A valid keyboard driving lease token is required for input"
        case .fullKeyboardAccessDisabled:
            return "Full Keyboard Access is disabled; enable it in System Settings before navigation"
        case .enableVerificationFailed:
            return "macOS did not verify Full Keyboard Access after the enable request"
        case .invalidCommand(let command):
            return "Unknown keyboard command: \(command)"
        case .invalidSequence(let key):
            return "Invalid keyboard sequence item: \(key)"
        case .printableKeyRejected(let key):
            return "Bare printable key rejected from the low-friction keyboard path: \(key)"
        case .sequenceTooLong:
            return "Keyboard sequence is longer than the supported maximum"
        case .repetitionLimitExceeded:
            return "Keyboard sequence repeats a key more than the supported maximum"
        case .invalidInterKeyDelay:
            return "Inter-key timing must be between 0 and 1000 milliseconds"
        case .permissionDenied(let permission):
            return "Required macOS permission is missing: \(permission)"
        case .foregroundUnavailable:
            return "The foreground application could not be read; keyboard input was blocked"
        case .appScopeMismatch(let expected, let actual):
            return "Keyboard lease is bound to \(expected), but the foreground application is \(actual)"
        }
    }
}

public enum KeyboardDriveStoreError: Error, LocalizedError, Equatable {
    case confirmationRequired
    case duplicateLease
    case invalidLifetime
    case applicationRequired
    case physicalKeyboardSuppressionRequiresSession
    case physicalKeyboardSuppressionReasonRequired
    case physicalKeyboardSuppressionUnavailable
    case navigationModeRequiresSession
    case navigationModeRequiresPassThroughAssertion
    case navigationModeRestorationPending
    case navigationModeTransitionFailed
    case navigationModeRestorationFailed
    case notFound
    case expired

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Explicit confirmation is required before acquiring a keyboard lease"
        case .duplicateLease:
            return "A keyboard driving lease is already active"
        case .invalidLifetime:
            return "Keyboard lease lifetime must be a positive finite duration; physical suppression and navigation leases may not exceed 300 seconds"
        case .applicationRequired:
            return "An app-scoped keyboard lease requires a foreground application"
        case .physicalKeyboardSuppressionRequiresSession:
            return "Physical keyboard suppression is available only for session-scoped leases"
        case .physicalKeyboardSuppressionReasonRequired:
            return "Physical keyboard suppression requires a non-empty human-readable reason"
        case .physicalKeyboardSuppressionUnavailable:
            return "macOS could not enable physical keyboard suppression; verify Accessibility and Input Monitoring permissions"
        case .navigationModeRequiresSession:
            return "Keyboard navigation mode is available only for session-scoped leases"
        case .navigationModeRequiresPassThroughAssertion:
            return "Keyboard navigation mode requires an explicit assertion that Pass-Through Mode is active"
        case .navigationModeRestorationPending:
            return "Pass-Through Mode restoration is pending after an ambiguous keyboard transition; reconcile macOS keyboard state before acquiring another navigation lease"
        case .navigationModeTransitionFailed:
            return "macOS Pass-Through Mode could not be toggled; keyboard navigation mode was not acquired"
        case .navigationModeRestorationFailed:
            return "macOS Pass-Through Mode could not be restored; keyboard navigation leases are blocked until keyboard state is reconciled"
        case .notFound:
            return "The keyboard lease token is invalid"
        case .expired:
            return "The keyboard lease has expired"
        }
    }
}

public protocol KeyboardPreferenceStore {
    var fullKeyboardAccessEnabled: Bool { get }
    func enableFullKeyboardAccess() throws
}

public struct SystemKeyboardPreferenceStore: KeyboardPreferenceStore {
    public init() {}

    public var fullKeyboardAccessEnabled: Bool {
        NSApplication.shared.isFullKeyboardAccessEnabled
    }

    public func enableFullKeyboardAccess() throws {
        let key = "AppleKeyboardUIMode" as CFString
        let value = NSNumber(value: 2)
        CFPreferencesSetValue(
            key,
            value,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw KeyboardControlError.enableVerificationFailed
        }
    }
}

public protocol KeyboardEventSending {
    func send(keySpecification: String) throws
}

extension InputController: KeyboardEventSending {
    public func send(keySpecification: String) throws {
        try key(keySpecification)
    }
}

public protocol KeyboardPassThroughToggling {
    func togglePassThroughMode() throws
}

public struct SystemKeyboardPassThroughToggler: KeyboardPassThroughToggling {
    private let eventSender: KeyboardEventSending

    public init(eventSender: KeyboardEventSending = InputController()) {
        self.eventSender = eventSender
    }

    public func togglePassThroughMode() throws {
        guard let specification = KeyboardCommand.passThrough.keySpecifications.first else {
            throw KeyboardControlError.invalidSequence("pass-through")
        }
        try eventSender.send(keySpecification: specification)
    }
}

public final class KeyboardDriveStore {
    public static let defaultLifetime: TimeInterval = 120
    public static let maximumLifetime: TimeInterval = 300

    private struct ActiveLease {
        let lease: KeyboardDriveLease
    }

    private let lock = NSLock()
    private let defaultLifetime: TimeInterval
    private let now: () -> Date
    private let physicalKeyboardSuppressor: PhysicalKeyboardSuppressing
    private let passThroughToggler: KeyboardPassThroughToggling
    private let expiryQueue = DispatchQueue(label: "com.jakyeamos.macctl.keyboard-lease-expiry")
    private var active: ActiveLease?
    private var expiryWorkItem: DispatchWorkItem?
    private var navigationRestorationPending = false

    public init(
        defaultLifetime: TimeInterval = KeyboardDriveStore.defaultLifetime,
        now: @escaping () -> Date = Date.init,
        physicalKeyboardSuppressor: PhysicalKeyboardSuppressing = SystemPhysicalKeyboardSuppressor(),
        passThroughToggler: KeyboardPassThroughToggling = SystemKeyboardPassThroughToggler()
    ) {
        self.defaultLifetime = min(max(defaultLifetime, 0.001), KeyboardDriveStore.maximumLifetime)
        self.now = now
        self.physicalKeyboardSuppressor = physicalKeyboardSuppressor
        self.passThroughToggler = passThroughToggler
    }

    deinit {
        shutdown()
    }

    public func acquire(
        scope: KeyboardLeaseScope,
        application: AppInfo?,
        seconds: TimeInterval?,
        confirm: Bool,
        physicalInputMode: KeyboardPhysicalInputMode = .shared,
        freezeReason: String? = nil,
        navigationMode: KeyboardNavigationMode = .unchanged,
        fromPassThrough: Bool = false
    ) throws -> KeyboardDriveLease {
        let lifetime = seconds ?? defaultLifetime
        guard lifetime.isFinite, lifetime > 0 else {
            throw KeyboardDriveStoreError.invalidLifetime
        }
        if (physicalInputMode == .suppressed || navigationMode == .navigation),
           lifetime > Self.maximumLifetime {
            throw KeyboardDriveStoreError.invalidLifetime
        }
        if scope == .app, application == nil {
            throw KeyboardDriveStoreError.applicationRequired
        }
        if physicalInputMode == .suppressed, scope != .session {
            throw KeyboardDriveStoreError.physicalKeyboardSuppressionRequiresSession
        }
        let hasFreezeReason = !(freezeReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if physicalInputMode == .suppressed, !hasFreezeReason {
            throw KeyboardDriveStoreError.physicalKeyboardSuppressionReasonRequired
        }
        if navigationMode == .navigation, scope != .session {
            throw KeyboardDriveStoreError.navigationModeRequiresSession
        }
        if navigationMode == .navigation, !fromPassThrough {
            throw KeyboardDriveStoreError.navigationModeRequiresPassThroughAssertion
        }
        lock.lock()
        let current = now()
        if let expiredLease = removeExpiredLocked(at: current) {
            lock.unlock()
            try? cleanup(expiredLease, throwOnRestoreFailure: false)
            lock.lock()
        }
        guard !navigationRestorationPending else {
            lock.unlock()
            throw KeyboardDriveStoreError.navigationModeRestorationPending
        }
        guard active == nil else {
            lock.unlock()
            throw KeyboardDriveStoreError.duplicateLease
        }
        let lease = KeyboardDriveLease(
            token: "kbd_\(UUID().uuidString)",
            scope: scope,
            application: scope == .app ? application : nil,
            acquiredAt: current,
            expiresAt: current.addingTimeInterval(lifetime),
            physicalInputMode: physicalInputMode,
            freezeReasonProvided: hasFreezeReason,
            navigationMode: navigationMode,
            passThroughTransitionOwned: navigationMode == .navigation
        )

        if physicalInputMode == .suppressed {
            do {
                try physicalKeyboardSuppressor.acquire(until: lease.expiresAt)
            } catch {
                lock.unlock()
                physicalKeyboardSuppressor.release()
                throw KeyboardDriveStoreError.physicalKeyboardSuppressionUnavailable
            }
        }
        if navigationMode == .navigation {
            do {
                try passThroughToggler.togglePassThroughMode()
            } catch {
                if physicalInputMode == .suppressed {
                    physicalKeyboardSuppressor.release()
                }
                navigationRestorationPending = true
                lock.unlock()
                throw KeyboardDriveStoreError.navigationModeTransitionFailed
            }
        }
        active = ActiveLease(lease: lease)
        scheduleExpirationLocked(for: lease)
        lock.unlock()
        return lease
    }

    public func lease(for token: String) throws -> KeyboardDriveLease {
        lock.lock()
        guard let active, active.lease.token == token else {
            lock.unlock()
            throw KeyboardDriveStoreError.notFound
        }
        let current = now()
        guard active.lease.expiresAt > current else {
            let expiredLease = removeActiveLocked()
            lock.unlock()
            try? cleanup(expiredLease, throwOnRestoreFailure: false)
            throw KeyboardDriveStoreError.expired
        }
        lock.unlock()
        return active.lease
    }

    public func activeLease() -> KeyboardDriveLease? {
        lock.lock()
        guard let active else {
            lock.unlock()
            return nil
        }
        let current = now()
        guard active.lease.expiresAt > current else {
            let expiredLease = removeActiveLocked()
            lock.unlock()
            try? cleanup(expiredLease, throwOnRestoreFailure: false)
            return nil
        }
        lock.unlock()
        return active.lease
    }

    @discardableResult
    public func release(token: String) throws -> KeyboardDriveLease {
        lock.lock()
        guard let active, active.lease.token == token else {
            lock.unlock()
            throw KeyboardDriveStoreError.notFound
        }
        let current = now()
        guard active.lease.expiresAt > current else {
            let expiredLease = removeActiveLocked()
            lock.unlock()
            try? cleanup(expiredLease, throwOnRestoreFailure: false)
            throw KeyboardDriveStoreError.expired
        }
        let lease = active.lease
        let removedLease = removeActiveLocked()
        lock.unlock()
        try cleanup(removedLease, throwOnRestoreFailure: true)
        return lease
    }

    /// Invalidates a matching lease without depending on its expiry state.
    ///
    /// This is used by daemon-owned ephemeral control actions so cleanup remains
    /// fail-closed even when the action or its post-action verification throws.
    @discardableResult
    public func invalidate(token: String) -> Bool {
        lock.lock()
        guard let active, active.lease.token == token else {
            lock.unlock()
            return false
        }
        let removedLease = removeActiveLocked()
        lock.unlock()
        try? cleanup(removedLease, throwOnRestoreFailure: false)
        return true
    }

    /// Releases the active lease and any physical suppression owned by it.
    /// This is called during daemon shutdown and is safe to invoke repeatedly.
    public func shutdown() {
        lock.lock()
        let removedLease = removeActiveLocked()
        lock.unlock()
        try? cleanup(removedLease, throwOnRestoreFailure: false)
    }

    public var isNavigationRestorationPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return navigationRestorationPending
    }

    private func removeActiveLocked() -> KeyboardDriveLease? {
        guard let active else { return nil }
        self.active = nil
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        return active.lease
    }

    private func removeExpiredLocked(at date: Date) -> KeyboardDriveLease? {
        guard let active, active.lease.expiresAt <= date else { return nil }
        return removeActiveLocked()
    }

    private func cleanup(_ lease: KeyboardDriveLease?, throwOnRestoreFailure: Bool) throws {
        guard let lease else { return }
        if lease.physicalInputMode == .suppressed {
            physicalKeyboardSuppressor.release()
        }
        guard lease.passThroughTransitionOwned else { return }
        do {
            try passThroughToggler.togglePassThroughMode()
        } catch {
            lock.lock()
            navigationRestorationPending = true
            lock.unlock()
            if throwOnRestoreFailure {
                // The lease has already been removed, so callers cannot safely
                // retry this transition through the old token.
                throw KeyboardDriveStoreError.navigationModeRestorationFailed
            }
        }
    }

    private func scheduleExpirationLocked(for lease: KeyboardDriveLease) {
        expiryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.expireIfNeeded(token: lease.token)
        }
        expiryWorkItem = workItem
        let delay = max(lease.expiresAt.timeIntervalSince(now()), 0)
        expiryQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func expireIfNeeded(token: String) {
        lock.lock()
        guard let active, active.lease.token == token else {
            lock.unlock()
            return
        }
        let remaining = active.lease.expiresAt.timeIntervalSince(now())
        if remaining > 0 {
            scheduleExpirationLocked(for: active.lease)
            lock.unlock()
            return
        }
        let removedLease = removeActiveLocked()
        lock.unlock()
        try? cleanup(removedLease, throwOnRestoreFailure: false)
    }
}

public final class KeyboardAccessController {
    public static let settingsPath = "System Settings > Accessibility > Motor > Keyboard > Full Keyboard Access"
    public static let maximumRawSequenceLength = 32
    public static let maximumNamedRepetitions = 20
    public static let maximumConsecutiveRepetitions = 8

    private let eventSender: KeyboardEventSending
    private let preferenceStore: KeyboardPreferenceStore

    public init(
        eventSender: KeyboardEventSending = InputController(),
        preferenceStore: KeyboardPreferenceStore = SystemKeyboardPreferenceStore()
    ) {
        self.eventSender = eventSender
        self.preferenceStore = preferenceStore
    }

    public func status(
        permissionContext: String = "daemon",
        activeLease: KeyboardDriveLease? = nil,
        navigationRestorationPending: Bool = false
    ) -> KeyboardAccessStatus {
        KeyboardAccessStatus(
            fullKeyboardAccessEnabled: permissionContext == "unknown"
                ? nil
                : preferenceStore.fullKeyboardAccessEnabled,
            permissionContext: permissionContext,
            permissions: permissionContext == "unknown"
                ? PermissionDiagnostics.unknownReport()
                : PermissionDiagnostics.report(),
            activeLease: activeLease,
            navigationRestorationPending: navigationRestorationPending
        )
    }

    public func setup() -> KeyboardSetupInfo {
        KeyboardSetupInfo()
    }

    public func enable(
        confirm: Bool,
        permissionContext: String = "daemon",
        activeLease: KeyboardDriveLease? = nil,
        navigationRestorationPending: Bool = false
    ) throws -> KeyboardAccessStatus {
        try preferenceStore.enableFullKeyboardAccess()
        guard preferenceStore.fullKeyboardAccessEnabled else {
            throw KeyboardControlError.enableVerificationFailed
        }
        return status(
            permissionContext: permissionContext,
            activeLease: activeLease,
            navigationRestorationPending: navigationRestorationPending
        )
    }

    public func send(
        command: KeyboardCommand,
        count: Int,
        targetApplication: AppInfo,
        leaseExpiresAt: Date,
        interKeyDelay: TimeInterval,
        beforeEach: @escaping (Int) throws -> Void
    ) throws -> KeyboardActionReport {
        guard (1...Self.maximumNamedRepetitions).contains(count) else {
            throw KeyboardControlError.repetitionLimitExceeded
        }
        let keys = Array(repeating: command.keySpecifications, count: count).flatMap { $0 }
        try validateInterKeyDelay(interKeyDelay)
        try dispatch(
            keys: keys,
            interKeyDelay: interKeyDelay,
            beforeEach: beforeEach
        )
        return KeyboardActionReport(
            action: command.rawValue,
            command: command,
            keyCount: keys.count,
            targetApplication: targetApplication,
            leaseExpiresAt: leaseExpiresAt
        )
    }

    public func sendRaw(
        keys: [String],
        targetApplication: AppInfo,
        leaseExpiresAt: Date,
        interKeyDelay: TimeInterval,
        beforeEach: @escaping (Int) throws -> Void
    ) throws -> KeyboardActionReport {
        let validatedKeys = try Self.validateRawSequence(keys)
        try validateInterKeyDelay(interKeyDelay)
        try dispatch(
            keys: validatedKeys,
            interKeyDelay: interKeyDelay,
            beforeEach: beforeEach
        )
        return KeyboardActionReport(
            action: "send",
            command: nil,
            keyCount: validatedKeys.count,
            targetApplication: targetApplication,
            leaseExpiresAt: leaseExpiresAt
        )
    }

    public static func validateRawSequence(_ keys: [String]) throws -> [String] {
        guard !keys.isEmpty else { throw KeyboardControlError.invalidSequence("empty sequence") }
        guard keys.count <= maximumRawSequenceLength else {
            throw KeyboardControlError.sequenceTooLong
        }
        var previous: String?
        var consecutiveCount = 0
        var validated: [String] = []
        for rawKey in keys {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { throw KeyboardControlError.invalidSequence(rawKey) }
            do {
                _ = try KeySpecification.parse(key)
            } catch {
                throw KeyboardControlError.invalidSequence(rawKey)
            }
            if isBarePrintable(key) {
                throw KeyboardControlError.printableKeyRejected(rawKey)
            }
            if key == previous {
                consecutiveCount += 1
            } else {
                previous = key
                consecutiveCount = 1
            }
            guard consecutiveCount <= maximumConsecutiveRepetitions else {
                throw KeyboardControlError.repetitionLimitExceeded
            }
            validated.append(key)
        }
        return validated
    }

    private func dispatch(
        keys: [String],
        interKeyDelay: TimeInterval,
        beforeEach: (Int) throws -> Void
    ) throws {
        for (index, key) in keys.enumerated() {
            try beforeEach(index)
            try eventSender.send(keySpecification: key)
            if index < keys.count - 1, interKeyDelay > 0 {
                Thread.sleep(forTimeInterval: interKeyDelay)
            }
        }
    }

    private func validateInterKeyDelay(_ delay: TimeInterval) throws {
        guard (0...1).contains(delay) else { throw KeyboardControlError.invalidInterKeyDelay }
    }

    private static func isBarePrintable(_ key: String) -> Bool {
        guard !key.contains("+") else { return false }
        if key == "space" { return true }
        let printable = "abcdefghijklmnopqrstuvwxyz0123456789-=\\[];',./`"
        return key.count == 1 && printable.contains(key)
    }
}
