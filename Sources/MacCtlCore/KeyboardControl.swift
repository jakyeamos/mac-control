import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

public enum KeyboardLeaseScope: String, Codable, Equatable, CaseIterable {
    case app
    case session
}

public enum KeyboardCommand: String, Codable, Equatable, CaseIterable {
    case nextControl = "next-control"
    case previousControl = "previous-control"
    case activate
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
    public let application: AppInfo?
    public let acquiredAt: Date
    public let expiresAt: Date

    public init(
        token: String,
        scope: KeyboardLeaseScope,
        application: AppInfo?,
        acquiredAt: Date,
        expiresAt: Date
    ) {
        self.token = token
        self.scope = scope
        self.application = application
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }
}

public struct KeyboardAccessStatus: Codable, Equatable {
    public let fullKeyboardAccessEnabled: Bool?
    public let permissionContext: String
    public let permissions: [PermissionStatus]
    public let setupPath: String
    public let activeLease: KeyboardDriveLease?

    public init(
        fullKeyboardAccessEnabled: Bool?,
        permissionContext: String,
        permissions: [PermissionStatus],
        setupPath: String = KeyboardAccessController.settingsPath,
        activeLease: KeyboardDriveLease? = nil
    ) {
        self.fullKeyboardAccessEnabled = fullKeyboardAccessEnabled
        self.permissionContext = permissionContext
        self.permissions = permissions
        self.setupPath = setupPath
        self.activeLease = activeLease
    }

    public static func unknown(permissionContext: String = "unknown") -> KeyboardAccessStatus {
        KeyboardAccessStatus(
            fullKeyboardAccessEnabled: nil,
            permissionContext: permissionContext,
            permissions: PermissionDiagnostics.unknownReport()
        )
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

    public init(
        targetApplication: AppInfo,
        role: String?,
        subrole: String?,
        identifier: String?,
        title: String?
    ) {
        self.targetApplication = targetApplication
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
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
    case notFound
    case expired

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Explicit confirmation is required before acquiring a keyboard lease"
        case .duplicateLease:
            return "A keyboard driving lease is already active"
        case .invalidLifetime:
            return "Keyboard lease lifetime must be greater than zero and no more than 300 seconds"
        case .applicationRequired:
            return "An app-scoped keyboard lease requires a foreground application"
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

public final class KeyboardDriveStore {
    public static let defaultLifetime: TimeInterval = 120
    public static let maximumLifetime: TimeInterval = 300

    private struct ActiveLease {
        let lease: KeyboardDriveLease
    }

    private let lock = NSLock()
    private let defaultLifetime: TimeInterval
    private let now: () -> Date
    private var active: ActiveLease?

    public init(
        defaultLifetime: TimeInterval = KeyboardDriveStore.defaultLifetime,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaultLifetime = min(max(defaultLifetime, 0.001), KeyboardDriveStore.maximumLifetime)
        self.now = now
    }

    public func acquire(
        scope: KeyboardLeaseScope,
        application: AppInfo?,
        seconds: TimeInterval?,
        confirm: Bool
    ) throws -> KeyboardDriveLease {
        guard confirm else { throw KeyboardDriveStoreError.confirmationRequired }
        let lifetime = seconds ?? defaultLifetime
        guard lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw KeyboardDriveStoreError.invalidLifetime
        }
        if scope == .app, application == nil {
            throw KeyboardDriveStoreError.applicationRequired
        }
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        purgeExpired(at: current)
        guard active == nil else { throw KeyboardDriveStoreError.duplicateLease }
        let lease = KeyboardDriveLease(
            token: "kbd_\(UUID().uuidString)",
            scope: scope,
            application: scope == .app ? application : nil,
            acquiredAt: current,
            expiresAt: current.addingTimeInterval(lifetime)
        )
        active = ActiveLease(lease: lease)
        return lease
    }

    public func lease(for token: String) throws -> KeyboardDriveLease {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { throw KeyboardDriveStoreError.notFound }
        guard active.lease.token == token else { throw KeyboardDriveStoreError.notFound }
        let current = now()
        guard active.lease.expiresAt > current else {
            self.active = nil
            throw KeyboardDriveStoreError.expired
        }
        return active.lease
    }

    public func activeLease() -> KeyboardDriveLease? {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { return nil }
        let current = now()
        guard active.lease.expiresAt > current else {
            self.active = nil
            return nil
        }
        return active.lease
    }

    @discardableResult
    public func release(token: String) throws -> KeyboardDriveLease {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { throw KeyboardDriveStoreError.notFound }
        guard active.lease.token == token else { throw KeyboardDriveStoreError.notFound }
        let current = now()
        guard active.lease.expiresAt > current else {
            self.active = nil
            throw KeyboardDriveStoreError.expired
        }
        self.active = nil
        return active.lease
    }

    private func purgeExpired(at date: Date) {
        guard let active, active.lease.expiresAt <= date else { return }
        self.active = nil
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
        activeLease: KeyboardDriveLease? = nil
    ) -> KeyboardAccessStatus {
        KeyboardAccessStatus(
            fullKeyboardAccessEnabled: permissionContext == "unknown"
                ? nil
                : preferenceStore.fullKeyboardAccessEnabled,
            permissionContext: permissionContext,
            permissions: permissionContext == "unknown"
                ? PermissionDiagnostics.unknownReport()
                : PermissionDiagnostics.report(),
            activeLease: activeLease
        )
    }

    public func setup() -> KeyboardSetupInfo {
        KeyboardSetupInfo()
    }

    public func enable(
        confirm: Bool,
        permissionContext: String = "daemon",
        activeLease: KeyboardDriveLease? = nil
    ) throws -> KeyboardAccessStatus {
        guard confirm else { throw KeyboardControlError.confirmationRequired }
        try preferenceStore.enableFullKeyboardAccess()
        guard preferenceStore.fullKeyboardAccessEnabled else {
            throw KeyboardControlError.enableVerificationFailed
        }
        return status(permissionContext: permissionContext, activeLease: activeLease)
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
