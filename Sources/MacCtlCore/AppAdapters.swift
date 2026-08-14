import AppKit
import Foundation

public enum AppAdapterRoute: String, Codable, Equatable, CaseIterable {
    case native
    case accessibility
    case keyboard
    case appleScript = "apple_script"
}

/// Whether a typed adapter operation can run while another application keeps
/// macOS foreground focus. This is an allowlist property, not an inference
/// from the transport: every operation defaults to foreground-only until its
/// implementation and post-action focus guard are known to be safe.
public enum AppAdapterFocusSupport: String, Codable, Equatable, CaseIterable {
    case foregroundOnly = "foreground_only"
    case backgroundSafe = "background_safe"
}

public struct AppAdapterOperation: Codable, Equatable {
    public let name: String
    public let mutating: Bool
    public let risk: RiskLevel
    public let requiredPermissions: [String]
    public let routes: [AppAdapterRoute]
    public let redactedObservationSchema: [String]
    public let focusSupport: AppAdapterFocusSupport

    public init(
        name: String,
        mutating: Bool,
        risk: RiskLevel,
        requiredPermissions: [String] = [],
        routes: [AppAdapterRoute],
        redactedObservationSchema: [String] = [],
        focusSupport: AppAdapterFocusSupport = .foregroundOnly
    ) {
        self.name = name
        self.mutating = mutating
        self.risk = risk
        self.requiredPermissions = requiredPermissions
        self.routes = routes
        self.redactedObservationSchema = redactedObservationSchema
        self.focusSupport = focusSupport
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case mutating
        case risk
        case requiredPermissions
        case routes
        case redactedObservationSchema
        case focusSupport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        mutating = try container.decode(Bool.self, forKey: .mutating)
        risk = try container.decode(RiskLevel.self, forKey: .risk)
        requiredPermissions = try container.decodeIfPresent([String].self, forKey: .requiredPermissions) ?? []
        routes = try container.decode([AppAdapterRoute].self, forKey: .routes)
        redactedObservationSchema = try container.decodeIfPresent(
            [String].self,
            forKey: .redactedObservationSchema
        ) ?? []
        focusSupport = try container.decodeIfPresent(
            AppAdapterFocusSupport.self,
            forKey: .focusSupport
        ) ?? .foregroundOnly
    }
}

public struct AppAdapterManifest: Codable, Equatable {
    public let adapterID: String
    public let displayName: String
    public let supportedBundleIdentifiers: [String]
    public let operations: [AppAdapterOperation]

    public init(
        adapterID: String,
        displayName: String,
        supportedBundleIdentifiers: [String],
        operations: [AppAdapterOperation]
    ) {
        self.adapterID = adapterID
        self.displayName = displayName
        self.supportedBundleIdentifiers = supportedBundleIdentifiers
        self.operations = operations
    }

    public func operation(named name: String) -> AppAdapterOperation? {
        operations.first { $0.name == name }
    }
}

public typealias AdapterManifest = AppAdapterManifest

public struct AppAdapterObservation: Codable, Equatable {
    public let adapterID: String
    public let operation: String
    public let application: String
    public let state: String
    public let fields: [String: JSONValue]

    public init(
        adapterID: String,
        operation: String,
        application: String,
        state: String,
        fields: [String: JSONValue] = [:]
    ) {
        self.adapterID = adapterID
        self.operation = operation
        self.application = application
        self.state = state
        self.fields = fields
    }
}

public struct AppAdapterActionResult: Codable, Equatable {
    public let adapterID: String
    public let operation: String
    public let route: AppAdapterRoute
    public let mutating: Bool
    public let targetFingerprint: String?
    public let observation: AppAdapterObservation?

    public init(
        adapterID: String,
        operation: String,
        route: AppAdapterRoute,
        mutating: Bool,
        targetFingerprint: String? = nil,
        observation: AppAdapterObservation? = nil
    ) {
        self.adapterID = adapterID
        self.operation = operation
        self.route = route
        self.mutating = mutating
        self.targetFingerprint = targetFingerprint
        self.observation = observation
    }
}

public enum AppAdapterError: Error, LocalizedError, Equatable {
    case unsupportedAdapter(String)
    case unsupportedOperation(adapterID: String, operation: String)
    case permissionMissing(String)
    case targetUnavailable(String)
    case ambiguousTarget
    case arbitraryScriptRejected
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAdapter(let adapterID): return "Application adapter is not allowlisted: \(adapterID)"
        case .unsupportedOperation(let adapterID, let operation):
            return "Adapter operation is not supported: \(adapterID).\(operation)"
        case .permissionMissing(let permission): return "Adapter permission is missing: \(permission)"
        case .targetUnavailable(let target): return "Adapter target is unavailable: \(target)"
        case .ambiguousTarget: return "Adapter target resolution was ambiguous"
        case .arbitraryScriptRejected: return "Arbitrary AppleScript/JXA is not exposed by macctl"
        case .operationFailed(let message): return "Adapter operation failed: \(message)"
        }
    }
}

public protocol TypedAppleScriptExecuting {
    func execute(source: String) throws
}

public final class SystemTypedAppleScriptExecutor: TypedAppleScriptExecuting {
    public init() {}

    public func execute(source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppAdapterError.operationFailed("typed_apple_script_invalid")
        }
        _ = script.executeAndReturnError(&error)
        if error != nil {
            throw AppAdapterError.operationFailed("typed_apple_script_failed")
        }
    }
}

/// Registry and capability manifest for typed application operations.  The
/// registry contains no request-provided script execution path.
public final class AppAdapterRegistry {
    private let manifestsByID: [String: AppAdapterManifest]
    private let permissionChecker: (String) -> Bool

    public init(
        manifests: [AppAdapterManifest] = AppAdapterRegistry.defaultManifests(),
        permissionChecker: @escaping (String) -> Bool = AppAdapterRegistry.defaultPermissionChecker
    ) {
        self.manifestsByID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.adapterID, $0) })
        self.permissionChecker = permissionChecker
    }

    public func manifests() -> [AppAdapterManifest] {
        manifestsByID.values.sorted {
            $0.adapterID.localizedCaseInsensitiveCompare($1.adapterID) == .orderedAscending
        }
    }

    public func manifest(adapterID: String) -> AppAdapterManifest? {
        manifestsByID[adapterID]
    }

    public func operation(adapterID: String, name: String) throws -> AppAdapterOperation {
        guard let manifest = manifestsByID[adapterID] else {
            throw AppAdapterError.unsupportedAdapter(adapterID)
        }
        guard let operation = manifest.operation(named: name) else {
            throw AppAdapterError.unsupportedOperation(adapterID: adapterID, operation: name)
        }
        return operation
    }

    public func missingPermission(for operation: AppAdapterOperation) -> String? {
        operation.requiredPermissions.first { !permissionChecker($0) }
    }

    public func adapterID(for application: AppInfo) -> String? {
        manifests().first { manifest in
            manifest.supportedBundleIdentifiers.contains { bundleID in
                bundleID == application.bundleID
            }
        }?.adapterID
    }

    public func automationPermissions() -> [PermissionStatus] {
        let requiresAutomation = manifests().contains { manifest in
            manifest.operations.contains { $0.requiredPermissions.contains("Automation") }
        }
        guard requiresAutomation else { return [] }
        if permissionChecker("Automation") {
            return [PermissionStatus(
                name: "Automation",
                state: "granted",
                requiredFor: "AppleScript and application-specific adapters",
                instruction: "Automation permission is available for declared adapter operations"
            )]
        }
        return PermissionDiagnostics.report(automationRequired: true)
            .filter { $0.name == "Automation" }
    }

    public static func defaultManifests() -> [AppAdapterManifest] {
        let inspect = AppAdapterOperation(
            name: "inspect.front-window",
            mutating: false,
            risk: .safe,
            requiredPermissions: ["Accessibility"],
            routes: [.accessibility],
            redactedObservationSchema: ["application", "window_visible"],
            focusSupport: .backgroundSafe
        )
        let open = AppAdapterOperation(
            name: "open",
            mutating: false,
            risk: .safe,
            routes: [.native],
            redactedObservationSchema: ["application", "running"]
        )
        let activate = AppAdapterOperation(
            name: "activate",
            mutating: true,
            risk: .reversible,
            requiredPermissions: ["Post Events"],
            routes: [.native],
            redactedObservationSchema: ["application", "foreground"]
        )
        let locate = AppAdapterOperation(
            name: "locate.named-object",
            mutating: false,
            risk: .safe,
            requiredPermissions: ["Accessibility"],
            routes: [.accessibility],
            redactedObservationSchema: ["role", "subrole", "identifier", "matched"],
            focusSupport: .backgroundSafe
        )
        let save = AppAdapterOperation(
            name: "document.save",
            mutating: true,
            risk: .reversible,
            requiredPermissions: ["Automation"],
            routes: [.appleScript],
            redactedObservationSchema: ["application", "saved"]
        )
        let openFocusBrief = AppAdapterOperation(
            name: FocusSessionExecutionOperation.openBrief.rawValue,
            mutating: true,
            risk: .reversible,
            routes: [.native],
            redactedObservationSchema: ["application", "fixture_digest", "opened"]
        )
        let openFocusScratchpad = AppAdapterOperation(
            name: FocusSessionExecutionOperation.openScratchpad.rawValue,
            mutating: true,
            risk: .reversible,
            routes: [.native],
            redactedObservationSchema: ["application", "fixture_digest", "opened"]
        )
        let arrangeFocusSession = AppAdapterOperation(
            name: FocusSessionExecutionOperation.arrangeWorkspace.rawValue,
            mutating: true,
            risk: .reversible,
            requiredPermissions: ["Accessibility"],
            routes: [.accessibility],
            redactedObservationSchema: ["applications", "layout_applied"]
        )
        let draft = AppAdapterOperation(
            name: "draft.create",
            mutating: true,
            risk: .sensitive,
            requiredPermissions: ["Automation"],
            routes: [.appleScript],
            redactedObservationSchema: ["application", "draft_created"]
        )
        let vscodeDiagnostics = AppAdapterOperation(
            name: "diagnostics.summary",
            mutating: false,
            risk: .safe,
            routes: [.native],
            redactedObservationSchema: [
                "fixture_id", "workspace_digest", "error_count", "warning_count",
                "info_count", "hint_count", "diagnostic_digest", "generated_at"
            ],
            focusSupport: .backgroundSafe
        )

        let core: [(String, String, String)] = [
            ("finder", "Finder", "com.apple.finder"),
            ("system-settings", "System Settings", "com.apple.systemsettings"),
            ("terminal", "Terminal", "com.apple.Terminal"),
            ("textedit", "TextEdit", "com.apple.TextEdit"),
            ("preview", "Preview", "com.apple.Preview")
        ]
        let productivity: [(String, String, String)] = [
            ("mail", "Mail", "com.apple.mail"),
            ("calendar", "Calendar", "com.apple.iCal"),
            ("notes", "Notes", "com.apple.Notes"),
            ("messages", "Messages", "com.apple.MobileSMS")
        ]
        var result: [AppAdapterManifest] = []
        result.append(AppAdapterManifest(
            adapterID: "vscode",
            displayName: "Visual Studio Code",
            supportedBundleIdentifiers: [
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders"
            ],
            operations: [vscodeDiagnostics]
        ))
        for (id, displayName, bundleID) in core {
            var operations = [open, activate, inspect, locate]
            if id == "textedit" || id == "preview" {
                operations.append(save)
            }
            if id == "preview" {
                operations.append(openFocusBrief)
                operations.append(arrangeFocusSession)
            }
            if id == "textedit" {
                operations.append(openFocusScratchpad)
            }
            result.append(AppAdapterManifest(
                adapterID: id,
                displayName: displayName,
                supportedBundleIdentifiers: [bundleID],
                operations: operations
            ))
        }
        for (id, displayName, bundleID) in productivity {
            let operations = id == "calendar"
                ? [open, activate, inspect, locate]
                : [open, activate, inspect, locate, draft]
            result.append(AppAdapterManifest(
                adapterID: id,
                displayName: displayName,
                supportedBundleIdentifiers: [bundleID],
                operations: operations
            ))
        }
        return result
    }

    public static func defaultPermissionChecker(_ permission: String) -> Bool {
        switch permission {
        case "Accessibility": return PermissionDiagnostics.hasAccessibility()
        case "Input Monitoring": return PermissionDiagnostics.hasListenEventAccess()
        case "Post Events": return PermissionDiagnostics.hasPostEventAccess()
        case "Screen Recording": return PermissionDiagnostics.hasScreenCaptureAccess()
        case "Automation":
            // macOS does not expose a general preflight for every target app.
            // Unknown is intentionally treated as unavailable at dispatch time.
            return false
        default: return false
        }
    }
}
