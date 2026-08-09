import CryptoKit
import Foundation

public enum CommandTargetKind: String, Codable, Equatable, CaseIterable {
    case appMenu = "app_menu"
    case chromeExtension = "chrome_extension"
}

public struct CommandTarget: Codable, Equatable {
    public let kind: CommandTargetKind
    public let applicationName: String?
    public let bundleID: String?
    public let menuPath: [String]?
    public let extensionID: String?
    public let commandID: String?

    public init(
        kind: CommandTargetKind,
        applicationName: String? = nil,
        bundleID: String? = nil,
        menuPath: [String]? = nil,
        extensionID: String? = nil,
        commandID: String? = nil
    ) {
        self.kind = kind
        self.applicationName = applicationName
        self.bundleID = bundleID
        self.menuPath = menuPath
        self.extensionID = extensionID
        self.commandID = commandID
    }

    public static func appMenu(
        applicationName: String,
        bundleID: String?,
        menuPath: [String]
    ) -> CommandTarget {
        CommandTarget(
            kind: .appMenu,
            applicationName: applicationName,
            bundleID: bundleID,
            menuPath: menuPath
        )
    }

    public static func chromeExtension(extensionID: String, commandID: String) -> CommandTarget {
        CommandTarget(
            kind: .chromeExtension,
            applicationName: "Google Chrome",
            bundleID: "com.google.Chrome",
            extensionID: extensionID,
            commandID: commandID
        )
    }

    public var applicationIdentity: String {
        bundleID ?? applicationName ?? "unknown"
    }

    public func validate() throws {
        switch kind {
        case .appMenu:
            guard let applicationName, !applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let menuPath, menuPath.count >= 2,
                  menuPath.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ShortcutError.invalidTarget("app_menu requires an app and an exact path with at least two components")
            }
        case .chromeExtension:
            guard let extensionID, ShortcutValidation.isChromeExtensionID(extensionID),
                  let commandID, !commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ShortcutError.invalidTarget("chrome_extension requires a 32-character extension ID and command ID")
            }
        }
    }
}

public enum ShortcutProvider: String, Codable, Equatable, CaseIterable {
    case macOSAppShortcut = "macos_app_shortcut"
    case chromeExtensionCommand = "chrome_extension_command"
}

public enum ShortcutStatus: String, Codable, Equatable, CaseIterable {
    case proposed
    case setupRequired = "setup_required"
    case configured
    case behaviorVerified = "behavior_verified"
    case stale
    case blocked
}

public struct ShortcutApplicationFingerprint: Codable, Equatable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let version: String?

    public init(application: AppInfo) {
        name = application.name
        bundleID = application.bundleID
        path = application.path
        version = application.bundleVersion
    }

    public func matches(_ application: AppInfo) -> Bool {
        let sameIdentity: Bool
        if let bundleID, let other = application.bundleID {
            sameIdentity = bundleID == other
        } else {
            sameIdentity = path == application.path
        }
        return sameIdentity && version == application.bundleVersion
    }
}

public struct ShortcutEvidenceTimestamps: Codable, Equatable {
    public let proposedAt: Date
    public let configuredAt: Date?
    public let behaviorVerifiedAt: Date?
    public let lastInspectedAt: Date?

    public init(
        proposedAt: Date = Date(),
        configuredAt: Date? = nil,
        behaviorVerifiedAt: Date? = nil,
        lastInspectedAt: Date? = nil
    ) {
        self.proposedAt = proposedAt
        self.configuredAt = configuredAt
        self.behaviorVerifiedAt = behaviorVerifiedAt
        self.lastInspectedAt = lastInspectedAt
    }
}

public struct ShortcutBinding: Codable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let target: CommandTarget
    public let chord: String?
    public let provider: ShortcutProvider
    public let priorChord: String?
    public let postconditions: [TaskPredicate]
    public let applicationFingerprint: ShortcutApplicationFingerprint?
    public let postconditionFingerprint: String
    public let status: ShortcutStatus
    public let evidence: ShortcutEvidenceTimestamps
    public let setupCheckpoint: String?
    public let lastBlocker: String?

    public init(
        schemaVersion: Int = 1,
        id: String,
        target: CommandTarget,
        chord: String?,
        provider: ShortcutProvider,
        priorChord: String? = nil,
        postconditions: [TaskPredicate] = [],
        applicationFingerprint: ShortcutApplicationFingerprint? = nil,
        postconditionFingerprint: String? = nil,
        status: ShortcutStatus = .proposed,
        evidence: ShortcutEvidenceTimestamps = ShortcutEvidenceTimestamps(),
        setupCheckpoint: String? = nil,
        lastBlocker: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.target = target
        self.chord = chord
        self.provider = provider
        self.priorChord = priorChord
        self.postconditions = postconditions
        self.applicationFingerprint = applicationFingerprint
        self.postconditionFingerprint = postconditionFingerprint
            ?? ShortcutDigests.digest(postconditions)
        self.status = status
        self.evidence = evidence
        self.setupCheckpoint = setupCheckpoint
        self.lastBlocker = lastBlocker
    }

    public var digest: String {
        ShortcutDigests.digest(self)
    }

    public func updating(
        chord: String?? = nil,
        priorChord: String?? = nil,
        status: ShortcutStatus? = nil,
        applicationFingerprint: ShortcutApplicationFingerprint?? = nil,
        configuredAt: Date?? = nil,
        behaviorVerifiedAt: Date?? = nil,
        inspectedAt: Date?? = nil,
        setupCheckpoint: String?? = nil,
        blocker: String?? = nil
    ) -> ShortcutBinding {
        ShortcutBinding(
            schemaVersion: schemaVersion,
            id: id,
            target: target,
            chord: chord ?? self.chord,
            provider: provider,
            priorChord: priorChord ?? self.priorChord,
            postconditions: postconditions,
            applicationFingerprint: applicationFingerprint ?? self.applicationFingerprint,
            postconditionFingerprint: postconditionFingerprint,
            status: status ?? self.status,
            evidence: ShortcutEvidenceTimestamps(
                proposedAt: evidence.proposedAt,
                configuredAt: configuredAt ?? evidence.configuredAt,
                behaviorVerifiedAt: behaviorVerifiedAt ?? evidence.behaviorVerifiedAt,
                lastInspectedAt: inspectedAt ?? evidence.lastInspectedAt
            ),
            setupCheckpoint: setupCheckpoint ?? self.setupCheckpoint,
            lastBlocker: blocker ?? self.lastBlocker
        )
    }
}

public enum ShortcutAuditDisposition: String, Codable, Equatable, CaseIterable {
    case eligible
    case needsPostcondition = "needs_postcondition"
    case conflict
    case unsupported
    case notRunning = "not_running"
}

public struct ShortcutCapabilityReport: Codable, Equatable {
    public let methods: [String]
    public let providers: [ShortcutProvider]
    public let ownerOnlyStorage: Bool
    public let statusCounts: [String: Int]

    public init(bindings: [ShortcutBinding], ownerOnlyStorage: Bool) {
        methods = [
            "shortcut.audit", "shortcut.propose", "shortcut.inspect",
            "shortcut.setup", "shortcut.run", "shortcut.remove"
        ]
        providers = ShortcutProvider.allCases
        self.ownerOnlyStorage = ownerOnlyStorage
        statusCounts = Dictionary(grouping: bindings, by: { $0.status.rawValue }).mapValues(\.count)
    }
}

public struct MenuCommandSnapshot: Codable, Equatable {
    public let path: [String]
    public let enabled: Bool
    public let hidden: Bool
    public let dynamic: Bool
    public let keyEquivalent: String?
    public let checked: Bool?

    public init(
        path: [String],
        enabled: Bool,
        hidden: Bool = false,
        dynamic: Bool = false,
        keyEquivalent: String? = nil,
        checked: Bool? = nil
    ) {
        self.path = path
        self.enabled = enabled
        self.hidden = hidden
        self.dynamic = dynamic
        self.keyEquivalent = keyEquivalent
        self.checked = checked
    }
}

public struct ShortcutAuditEntry: Codable, Equatable {
    public let target: CommandTarget
    public let disposition: ShortcutAuditDisposition
    public let reason: String
    public let currentChord: String?
    public let suggestedChord: String?
    public let postconditionAvailable: Bool
    public let blockerRank: Int
}

public struct ShortcutAuditReport: Codable, Equatable {
    public let application: AppInfo?
    public let entries: [ShortcutAuditEntry]
    public let inspectedAt: Date
    public let truncated: Bool
}

public enum ShortcutRunRoute: String, Codable, Equatable, CaseIterable {
    case accessibility
    case keyboard
}

public struct ShortcutRunReport: Codable, Equatable {
    public let bindingID: String
    public let route: ShortcutRunRoute
    public let verification: String
    public let latencyMs: Double
    public let status: ShortcutStatus
    public let noRetry: Bool
    public let beforeMenuState: MenuCommandSnapshot?
    public let afterMenuState: MenuCommandSnapshot?

    public init(
        bindingID: String,
        route: ShortcutRunRoute,
        verification: String,
        latencyMs: Double,
        status: ShortcutStatus,
        noRetry: Bool,
        beforeMenuState: MenuCommandSnapshot? = nil,
        afterMenuState: MenuCommandSnapshot? = nil
    ) {
        self.bindingID = bindingID
        self.route = route
        self.verification = verification
        self.latencyMs = latencyMs
        self.status = status
        self.noRetry = noRetry
        self.beforeMenuState = beforeMenuState
        self.afterMenuState = afterMenuState
    }
}

public struct ShortcutInspectionReport: Codable, Equatable {
    public let binding: ShortcutBinding
    public let application: AppInfo?
    public let menuState: MenuCommandSnapshot?
    public let observation: String
}

public struct ShortcutSetupReport: Codable, Equatable {
    public let bindingID: String
    public let status: ShortcutStatus
    public let configuredChord: String?
    public let handoffRequired: Bool
    public let checkpoint: String
    public let instruction: String?
}

public enum ShortcutError: Error, LocalizedError, Equatable {
    case invalidTarget(String)
    case invalidChord(String)
    case bindingNotFound(String)
    case duplicateBinding(String)
    case appNotRunning(String)
    case menuPathNotFound([String])
    case ambiguousMenuPath([String], Int)
    case menuItemDisabled([String])
    case dynamicMenuItem([String])
    case menuPathDrift([String])
    case conflict(String)
    case setupRequired
    case handoffRequired(String)
    case verificationUnavailable(String)
    case staleBinding(String)
    case unsupported(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTarget(let reason): return "Invalid shortcut target: \(reason)"
        case .invalidChord(let chord): return "Invalid shortcut chord: \(chord)"
        case .bindingNotFound(let id): return "Shortcut binding was not found: \(id)"
        case .duplicateBinding(let id): return "Shortcut binding already exists: \(id)"
        case .appNotRunning(let app): return "Application is not running: \(app)"
        case .menuPathNotFound(let path): return "Menu path was not found: \(path.joined(separator: " -> "))"
        case .ambiguousMenuPath(let path, let count): return "Menu path is ambiguous (\(count) matches): \(path.joined(separator: " -> "))"
        case .menuItemDisabled(let path): return "Menu item is disabled: \(path.joined(separator: " -> "))"
        case .dynamicMenuItem(let path): return "Dynamic menu items are not eligible: \(path.joined(separator: " -> "))"
        case .menuPathDrift(let path): return "Menu path drifted: \(path.joined(separator: " -> "))"
        case .conflict(let chord): return "Shortcut chord conflicts with an existing registration: \(chord)"
        case .setupRequired: return "Shortcut setup is required before the keyboard route can run"
        case .handoffRequired(let reason): return "Human handoff is required: \(reason)"
        case .verificationUnavailable(let reason): return "Shortcut verification is unavailable: \(reason)"
        case .staleBinding(let reason): return "Shortcut binding is stale: \(reason)"
        case .unsupported(let reason): return "Shortcut operation is unsupported: \(reason)"
        case .persistence(let reason): return "Shortcut persistence failed: \(reason)"
        }
    }
}

public enum ShortcutDigests {
    public static func digest<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONCodec.encode(value) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func bindingID(for target: CommandTarget) -> String {
        "sc_" + String(digest(target).prefix(16))
    }
}

public enum ShortcutValidation {
    public static func isChromeExtensionID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("a"..."p").contains(String($0)) }
    }
}
