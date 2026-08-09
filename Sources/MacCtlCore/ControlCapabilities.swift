import Foundation

/// A coarse application archetype used for capability discovery and test
/// coverage.  It is deliberately descriptive metadata, never permission to
/// drive an app and never a substitute for a measured route manifest.
public enum MacAppArchetype: String, Codable, Equatable, CaseIterable {
    case nativeAppKit = "native_appkit"
    case swiftUI = "swiftui"
    case electronChromium = "electron_chromium"
    case browser
    case systemSettings = "system_settings"
    case unknown
}

public enum MacAppArchetypeClassifier {
    public static func classify(_ application: WarmPathApplicationIdentity) -> MacAppArchetype {
        let bundleID = application.bundleID?.lowercased() ?? ""
        let name = application.name.lowercased()
        let combined = "\(bundleID) \(name)"
        let compact = combined
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        if combined.contains("iphone") || combined.contains("mirroring") {
            return .unknown
        }
        if bundleID == "com.apple.systemsettings"
            || bundleID == "com.apple.systempreferences"
            || name == "system settings"
            || name == "system preferences" {
            return .systemSettings
        }
        if compact.contains("swiftui") {
            return .swiftUI
        }
        if bundleID.contains("chrome")
            || bundleID.contains("firefox")
            || bundleID.contains("safari")
            || bundleID.contains("microsoftedge")
            || bundleID.contains("brave")
            || name == "chrome"
            || name == "safari"
            || name == "firefox" {
            return .browser
        }
        if bundleID.contains("electron")
            || bundleID.contains("visualstudio")
            || bundleID.contains("slack")
            || bundleID.contains("discord")
            || bundleID.contains("notion")
            || bundleID.contains("figma") {
            return .electronChromium
        }
        if compact.contains("visualstudio")
            || compact.contains("slack")
            || compact.contains("discord")
            || compact.contains("notion")
            || compact.contains("figma") {
            return .electronChromium
        }
        if bundleID.hasPrefix("com.apple.") {
            return .nativeAppKit
        }
        return .unknown
    }
}

public struct ControlCapabilityProfile: Codable, Equatable {
    public let schemaVersion: Int
    public let probeMode: String
    public let application: WarmPathApplicationIdentity
    public let archetype: MacAppArchetype
    public let classificationSource: String
    public let taskID: String?
    public let targetFingerprint: String?
    public let manifestFound: Bool
    public let freshMeasuredRoutes: [ControlActionRoute]
    public let staleOrUnprovenRoutes: [ControlActionRoute]
    public let callerSuppliedRoutes: [ControlActionRoute]
    public let contractCapabilities: [String]
    public let handoffProviders: [String]
    public let routeSelectionPolicy: String
    public let deepAuditAvailable: Bool
    public let cachedBroadProfile: CapabilityProfileCacheSummary?

    public init(
        application: WarmPathApplicationIdentity,
        taskID: String? = nil,
        targetFingerprint: String? = nil,
        manifest: WarmPathManifest? = nil,
        now: Date = Date(),
        deepAuditAvailable: Bool = false,
        cachedBroadProfile: CapabilityProfileCacheSummary? = nil
    ) {
        self.schemaVersion = 1
        self.probeMode = "fast_route_probe"
        self.application = application
        self.archetype = MacAppArchetypeClassifier.classify(application)
        self.classificationSource = "bundle_identity_and_app_name"
        self.taskID = taskID
        self.targetFingerprint = targetFingerprint
        self.manifestFound = manifest != nil
        let candidates = manifest?.candidates ?? []
        self.freshMeasuredRoutes = candidates
            .filter { $0.isMeasured && $0.isFresh(at: now) }
            .map(\.route)
        self.staleOrUnprovenRoutes = candidates
            .filter { !$0.isMeasured || !$0.isFresh(at: now) }
            .map(\.route)
        self.callerSuppliedRoutes = candidates
            .filter { $0.measurementSource == .callerSupplied }
            .map(\.route)
        self.contractCapabilities = [
            "control.outcome",
            "control.batch",
            "control.capabilities",
            "control.capability_audit",
            "control.capability_audit_batch",
            "semantic_scroll",
            "computer_use_handoff"
        ]
        self.handoffProviders = ["computer_use"]
        self.routeSelectionPolicy = "fresh_daemon_executed_measurement_only"
        self.deepAuditAvailable = deepAuditAvailable
        self.cachedBroadProfile = cachedBroadProfile
    }
}

public struct ControlBatchStepReport: Codable, Equatable {
    public let index: Int
    public let action: String
    public let route: ControlActionRoute
    public let verification: ControlVerificationState
    public let fallbackUsed: Bool
    public let routeSelectionCacheHit: Bool

    public init(
        index: Int,
        action: String,
        route: ControlActionRoute,
        verification: ControlVerificationState,
        fallbackUsed: Bool,
        routeSelectionCacheHit: Bool
    ) {
        self.index = index
        self.action = action
        self.route = route
        self.verification = verification
        self.fallbackUsed = fallbackUsed
        self.routeSelectionCacheHit = routeSelectionCacheHit
    }
}

public struct ControlBatchReport: Codable, Equatable {
    public let application: WarmPathApplicationIdentity
    public let actionCount: Int
    public let completedCount: Int
    public let routeSelectionCacheHits: Int
    public let foregroundFastPathUsed: Bool
    public let leaseReleased: Bool
    public let steps: [ControlBatchStepReport]

    public init(
        application: WarmPathApplicationIdentity,
        actionCount: Int,
        completedCount: Int,
        routeSelectionCacheHits: Int,
        foregroundFastPathUsed: Bool,
        leaseReleased: Bool,
        steps: [ControlBatchStepReport]
    ) {
        self.application = application
        self.actionCount = actionCount
        self.completedCount = completedCount
        self.routeSelectionCacheHits = routeSelectionCacheHits
        self.foregroundFastPathUsed = foregroundFastPathUsed
        self.leaseReleased = leaseReleased
        self.steps = steps
    }
}
