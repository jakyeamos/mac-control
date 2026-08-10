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
    case mirroredDevice = "mirrored_device"
    case unknown
}

public enum MacAppArchetypeClassifier {
    public static func classify(_ application: WarmPathApplicationIdentity) -> MacAppArchetype {
        AppControlProfileRegistry.standard.archetype(for: application)
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
    public let routeContextCurrent: Bool
    public let freshMeasuredRoutes: [ControlActionRoute]
    public let staleOrUnprovenRoutes: [ControlActionRoute]
    public let callerSuppliedRoutes: [ControlActionRoute]
    public let contractCapabilities: [String]
    /// Capabilities intentionally not exposed by this provider. This is
    /// explicit truthfulness for callers that might otherwise infer that a
    /// browser's native context menu is a supported tab/group mutation API.
    public let unsupportedCapabilities: [String]
    public let handoffProviders: [String]
    public let preferredProviders: [AppControlProvider]
    public let profileLayers: [String]
    public let anchors: [String]
    public let verificationMethods: [String]
    public let invalidatesOn: [String]
    public let routeSelectionPolicy: String
    public let deepAuditAvailable: Bool
    public let cachedBroadProfile: CapabilityProfileCacheSummary?
    public let recentBlockers: [ControlBlockerObservation]

    public init(
        application: WarmPathApplicationIdentity,
        taskID: String? = nil,
        targetFingerprint: String? = nil,
        manifest: WarmPathManifest? = nil,
        now: Date = Date(),
        currentContextIdentity: WarmPathContextIdentity? = nil,
        deepAuditAvailable: Bool = false,
        cachedBroadProfile: CapabilityProfileCacheSummary? = nil,
        recentBlockers: [ControlBlockerObservation] = [],
        profileRegistry: AppControlProfileRegistry = .standard
    ) {
        self.schemaVersion = 2
        self.probeMode = "fast_route_probe"
        self.application = application
        let effectiveProfile = profileRegistry.profile(for: application)
        self.archetype = effectiveProfile.archetype
        self.classificationSource = "declarative_profile_registry"
        self.taskID = taskID
        self.targetFingerprint = targetFingerprint
        self.manifestFound = manifest != nil
        let candidates = manifest?.candidates ?? []
        let contextCurrent = currentContextIdentity == nil
            || manifest == nil
            || (manifest?.contextIdentity != nil && manifest?.contextIdentity == currentContextIdentity)
        self.routeContextCurrent = contextCurrent
        self.freshMeasuredRoutes = candidates
            .filter { contextCurrent && $0.isWarm(at: now) }
            .map(\.route)
        self.staleOrUnprovenRoutes = candidates
            .filter { !contextCurrent || !$0.isWarm(at: now) }
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
            "control.blocker_observations",
            "window_scoped_accessibility_selector",
            "verified_context_menu",
            "semantic_scroll",
            "computer_use_handoff"
        ]
        self.unsupportedCapabilities = effectiveProfile.unsupportedCapabilities
        self.handoffProviders = ["computer_use"]
        self.preferredProviders = effectiveProfile.preferredProviders(for: taskID)
        self.profileLayers = effectiveProfile.layers
        self.anchors = effectiveProfile.anchors
        self.verificationMethods = effectiveProfile.verification
        self.invalidatesOn = effectiveProfile.invalidatesOn
        self.routeSelectionPolicy = "repeated_verified_context_bound_measurement_only"
        self.deepAuditAvailable = deepAuditAvailable
        self.cachedBroadProfile = cachedBroadProfile
        self.recentBlockers = recentBlockers
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
