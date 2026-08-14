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

public enum CapabilityAuditOpportunityState: String, Codable, Equatable {
    case notApplicable = "not_applicable"
    case notObserved = "not_observed"
    case satisfied
    case scheduled
    case inProgress = "in_progress"
}

public struct CapabilityAuditOpportunity: Codable, Equatable {
    public let state: CapabilityAuditOpportunityState
    public let reason: String
    public let launchesApplications: Bool
    public let dispatchesActions: Bool

    public init(state: CapabilityAuditOpportunityState, reason: String) {
        self.state = state
        self.reason = reason
        self.launchesApplications = false
        self.dispatchesActions = false
    }
}

/// The caller's intended control boundary. Browser chrome remains macOS app
/// UI; rendered webpage content belongs to the tab-addressed browser provider.
public enum ControlTargetSurface: String, Codable, Equatable, CaseIterable {
    case macAppUI = "mac_app_ui"
    case webContent = "web_content"
}

public struct ControlProviderHandoffRequired: Error, LocalizedError, Equatable {
    public let targetSurface: ControlTargetSurface
    public let recommendedProvider: AppControlProvider
    public let nextAction: String

    public init(
        targetSurface: ControlTargetSurface,
        recommendedProvider: AppControlProvider = .browserDOM,
        nextAction: String = "submit_browser_target_plan"
    ) {
        self.targetSurface = targetSurface
        self.recommendedProvider = recommendedProvider
        self.nextAction = nextAction
    }

    public var errorDescription: String? {
        "Web content must be addressed through the browser connector; Mac Control will not activate the browser for this request"
    }
}

public struct ControlCapabilityProfile: Codable, Equatable {
    public let schemaVersion: Int
    public let probeMode: String
    public let application: WarmPathApplicationIdentity
    public let archetype: MacAppArchetype
    public let classificationSource: String
    public let targetSurface: ControlTargetSurface
    public let localExecution: String
    public let foregroundRequirement: String
    public let providerHandoffRequired: Bool
    public let recommendedProvider: AppControlProvider?
    public let nextAction: String?
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
    /// App-published candidate capabilities. They improve planning and deep
    /// audit discovery but are never included in `freshMeasuredRoutes` until
    /// the specific task has independent verification evidence.
    public let advertisedCapabilities: [AppAdvertisedCapability]
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
    public let auditOpportunity: CapabilityAuditOpportunity?
    /// Static routing guidance that should be consulted before live probing.
    /// This is not execution authority and is separate from recent blockers,
    /// which are observations of already-failed actions.
    public let knownLimitations: [MacControlLimitation]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case probeMode
        case application
        case archetype
        case classificationSource
        case targetSurface
        case localExecution
        case foregroundRequirement
        case providerHandoffRequired
        case recommendedProvider
        case nextAction
        case taskID
        case targetFingerprint
        case manifestFound
        case routeContextCurrent
        case freshMeasuredRoutes
        case staleOrUnprovenRoutes
        case callerSuppliedRoutes
        case contractCapabilities
        case unsupportedCapabilities
        case advertisedCapabilities
        case handoffProviders
        case preferredProviders
        case profileLayers
        case anchors
        case verificationMethods
        case invalidatesOn
        case routeSelectionPolicy
        case deepAuditAvailable
        case cachedBroadProfile
        case recentBlockers
        case auditOpportunity
        case knownLimitations
    }

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
        auditOpportunity: CapabilityAuditOpportunity? = nil,
        targetSurface: ControlTargetSurface = .macAppUI,
        profileRegistry: AppControlProfileRegistry = .standard,
        knownLimitations: [MacControlLimitation] = MacControlLimitationsLedger.current.entries
    ) {
        self.schemaVersion = 7
        self.probeMode = "fast_route_probe"
        self.application = application
        let effectiveProfile = profileRegistry.profile(for: application)
        self.archetype = effectiveProfile.archetype
        self.classificationSource = "declarative_profile_registry"
        self.targetSurface = targetSurface
        self.localExecution = targetSurface == .webContent ? "provider_handoff_required" : "supported"
        self.foregroundRequirement = targetSurface == .webContent
            ? "not_required_by_surface"
            : "action_dependent"
        self.providerHandoffRequired = targetSurface == .webContent
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
            "control.limitations",
            "control.capability_audit",
            "control.capability_audit_batch",
            "control.capability_leads",
            "control.blocker_observations",
            "window_scoped_accessibility_selector",
            "verified_context_menu",
            "semantic_scroll",
            "computer_use_handoff",
            "web_content_provider_handoff"
        ]
        self.unsupportedCapabilities = effectiveProfile.unsupportedCapabilities
        self.advertisedCapabilities = effectiveProfile.advertisedCapabilities
        self.preferredProviders = effectiveProfile.preferredProviders(for: taskID)
        let browserProviders = self.preferredProviders.filter {
            $0 == .browserDOM || $0 == .cdpDOM
        }
        self.recommendedProvider = targetSurface == .webContent
            ? (browserProviders.first ?? .browserDOM)
            : nil
        self.nextAction = targetSurface == .webContent ? "submit_browser_target_plan" : nil
        self.handoffProviders = targetSurface == .webContent
            ? Array((browserProviders + [.computerUse]).map(\.rawValue).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            })
            : [AppControlProvider.computerUse.rawValue]
        self.profileLayers = effectiveProfile.layers
        self.anchors = effectiveProfile.anchors
        self.verificationMethods = effectiveProfile.verification
        self.invalidatesOn = effectiveProfile.invalidatesOn
        self.routeSelectionPolicy = "repeated_verified_context_bound_measurement_only"
        self.deepAuditAvailable = deepAuditAvailable
        self.cachedBroadProfile = cachedBroadProfile
        self.recentBlockers = recentBlockers
        self.auditOpportunity = auditOpportunity
        self.knownLimitations = knownLimitations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        probeMode = try container.decode(String.self, forKey: .probeMode)
        application = try container.decode(WarmPathApplicationIdentity.self, forKey: .application)
        archetype = try container.decode(MacAppArchetype.self, forKey: .archetype)
        classificationSource = try container.decode(String.self, forKey: .classificationSource)
        targetSurface = try container.decode(ControlTargetSurface.self, forKey: .targetSurface)
        localExecution = try container.decode(String.self, forKey: .localExecution)
        foregroundRequirement = try container.decode(String.self, forKey: .foregroundRequirement)
        providerHandoffRequired = try container.decode(Bool.self, forKey: .providerHandoffRequired)
        recommendedProvider = try container.decodeIfPresent(AppControlProvider.self, forKey: .recommendedProvider)
        nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        targetFingerprint = try container.decodeIfPresent(String.self, forKey: .targetFingerprint)
        manifestFound = try container.decode(Bool.self, forKey: .manifestFound)
        routeContextCurrent = try container.decode(Bool.self, forKey: .routeContextCurrent)
        freshMeasuredRoutes = try container.decode([ControlActionRoute].self, forKey: .freshMeasuredRoutes)
        staleOrUnprovenRoutes = try container.decode([ControlActionRoute].self, forKey: .staleOrUnprovenRoutes)
        callerSuppliedRoutes = try container.decode([ControlActionRoute].self, forKey: .callerSuppliedRoutes)
        contractCapabilities = try container.decode([String].self, forKey: .contractCapabilities)
        unsupportedCapabilities = try container.decode([String].self, forKey: .unsupportedCapabilities)
        advertisedCapabilities = try container.decode([AppAdvertisedCapability].self, forKey: .advertisedCapabilities)
        handoffProviders = try container.decode([String].self, forKey: .handoffProviders)
        preferredProviders = try container.decode([AppControlProvider].self, forKey: .preferredProviders)
        profileLayers = try container.decode([String].self, forKey: .profileLayers)
        anchors = try container.decode([String].self, forKey: .anchors)
        verificationMethods = try container.decode([String].self, forKey: .verificationMethods)
        invalidatesOn = try container.decode([String].self, forKey: .invalidatesOn)
        routeSelectionPolicy = try container.decode(String.self, forKey: .routeSelectionPolicy)
        deepAuditAvailable = try container.decode(Bool.self, forKey: .deepAuditAvailable)
        cachedBroadProfile = try container.decodeIfPresent(CapabilityProfileCacheSummary.self, forKey: .cachedBroadProfile)
        recentBlockers = try container.decode([ControlBlockerObservation].self, forKey: .recentBlockers)
        auditOpportunity = try container.decodeIfPresent(CapabilityAuditOpportunity.self, forKey: .auditOpportunity)
        knownLimitations = try container.decodeIfPresent([MacControlLimitation].self, forKey: .knownLimitations)
            ?? MacControlLimitationsLedger.current.entries
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
