import CryptoKit
import Foundation

/// The fast probe and the broad audit are deliberately separate surfaces.
/// A fast probe may read this cache, but it never walks an Accessibility tree.
public enum CapabilityAuditDepth: String, Codable, Equatable {
    case fastProbe = "fast_probe"
    case deepReadOnly = "deep_read_only"
}

public enum CapabilityProfileState: String, Codable, Equatable {
    case valid
    case stale
    case invalidated
}

public enum CapabilityEvidenceKind: String, Codable, Equatable {
    case positive
    case negative
    case ambiguous
}

public enum CapabilityEvidenceDisposition: String, Codable, Equatable {
    case promoted
    case demoted
    case candidate
}

public enum CapabilityProfileInvalidationReason: String, Codable, Equatable, CaseIterable {
    case applicationIdentityChanged = "application_identity_changed"
    case applicationVersionChanged = "application_version_changed"
    case osChanged = "os_changed"
    case providerStateChanged = "provider_state_changed"
    case treeChanged = "tree_changed"
    case staleElement = "stale_element"
    case actionFailed = "action_failed"
    case verificationFailed = "verification_failed"
    case targetAmbiguous = "target_ambiguous"
    case targetResolutionIncomplete = "target_resolution_incomplete"
    case permissionChanged = "permission_changed"
    case deepAuditTruncated = "deep_audit_truncated"
}

public struct CapabilityPermissionState: Codable, Equatable {
    public let name: String
    public let state: String

    public init(name: String, state: String) {
        self.name = name
        self.state = state
    }
}

/// Only permission/provider state is persisted. Instructions, paths to user
/// data, and provider payloads are intentionally excluded from this cache key.
public struct CapabilityProviderState: Codable, Equatable {
    public let revision: String
    public let permissions: [CapabilityPermissionState]
    public let observedProviders: [String]

    public init(
        revision: String = "mac-control-provider-contract-v1",
        permissions: [CapabilityPermissionState] = [],
        observedProviders: [String] = []
    ) {
        self.revision = revision
        self.permissions = permissions.sorted { $0.name < $1.name }
        self.observedProviders = observedProviders.sorted()
    }

    public init(
        permissionStatuses: [PermissionStatus],
        revision: String = "mac-control-provider-contract-v1"
    ) {
        let states = permissionStatuses.map {
            CapabilityPermissionState(name: $0.name, state: $0.state)
        }
        let granted = Set(states.filter { $0.state == "granted" }.map { $0.name.lowercased() })
        var providers = ["computer_use_handoff"]
        if granted.contains("accessibility") {
            providers.append("accessibility")
        }
        if granted.contains("post events") {
            providers.append("keyboard")
            providers.append("visual_input")
        }
        self.init(
            revision: revision,
            permissions: states,
            observedProviders: providers
        )
    }

    public var signature: String {
        let permissionsValue = permissions
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.state)" }
            .joined(separator: "|")
        let providersValue = observedProviders.sorted().joined(separator: "|")
        return CapabilityProfileDigest.make(
            "\(revision)|\(permissionsValue)|\(providersValue)"
        )
    }
}

public struct CapabilityCacheIdentity: Codable, Equatable {
    public let application: WarmPathApplicationIdentity
    public let osVersion: String
    public let providerStateSignature: String
    public let treeSignature: String

    public init(
        application: WarmPathApplicationIdentity,
        osVersion: String,
        providerStateSignature: String,
        treeSignature: String
    ) {
        self.application = application
        self.osVersion = osVersion
        self.providerStateSignature = providerStateSignature
        self.treeSignature = treeSignature
    }
}

/// A locator is an identity descriptor, never a retained AXUIElement.
/// Labels are hashed so a profile can survive without persisting visible text.
public struct CapabilityLocatorDescriptor: Codable, Equatable {
    public let role: String?
    public let subrole: String?
    public let identifier: String?
    public let labelDigest: String?
    public let actions: [String]
    public let scrollable: Bool
    /// Redacted identity of the target's Accessibility ancestor chain. This
    /// is optional so older audit profiles and local descriptors remain
    /// readable and addressable.
    public let ancestorDigest: String?
    /// Redacted geometry identity for task-specific disambiguation. Raw
    /// coordinates never leave the process; tree changes invalidate profiles
    /// that depend on this descriptor.
    public let geometryDigest: String?
    /// Redacted structural neighborhood evidence for repeated controls whose
    /// role/identity/ancestor/geometry descriptors are still not unique.
    public let structuralDigest: String?
    public let identityDigest: String

    public init(
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        labelDigest: String? = nil,
        actions: [String] = [],
        scrollable: Bool = false,
        ancestorDigest: String? = nil,
        geometryDigest: String? = nil,
        structuralDigest: String? = nil,
        identityDigest: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.labelDigest = labelDigest
        self.actions = actions.sorted()
        self.scrollable = scrollable
        self.ancestorDigest = ancestorDigest
        self.geometryDigest = geometryDigest
        self.structuralDigest = structuralDigest
        self.identityDigest = identityDigest ?? CapabilityProfileDigest.make([
            role ?? "",
            subrole ?? "",
            identifier ?? "",
            labelDigest ?? "",
            self.actions.joined(separator: ","),
            scrollable ? "1" : "0"
        ].joined(separator: "|"))
    }

    public static func from(
        treeNode: AccessibilityTreeNode,
        ancestorDigest: String? = nil
    ) -> CapabilityLocatorDescriptor? {
        guard treeNode.role != nil || treeNode.identifier != nil || treeNode.label != nil else {
            return nil
        }
        return fromAccessibilityIdentity(
            role: treeNode.role,
            subrole: treeNode.subrole,
            identifier: treeNode.identifier,
            label: treeNode.label,
            actions: treeNode.actions,
            scrollable: treeNode.scrollable,
            ancestorDigest: ancestorDigest,
            geometryDigest: treeNode.bounds.map(CapabilityProfileDigest.geometry),
            structuralDigest: treeNode.structuralDigest
        )
    }

    static func fromAccessibilityIdentity(
        role: String?,
        subrole: String?,
        identifier: String?,
        label: String?,
        actions: [String],
        scrollable: Bool,
        ancestorDigest: String? = nil,
        geometryDigest: String? = nil,
        structuralDigest: String? = nil
    ) -> CapabilityLocatorDescriptor {
        CapabilityLocatorDescriptor(
            role: role,
            subrole: subrole,
            identifier: identifier,
            labelDigest: label.map(CapabilityProfileDigest.make),
            actions: actions,
            scrollable: scrollable,
            ancestorDigest: ancestorDigest,
            geometryDigest: geometryDigest,
            structuralDigest: structuralDigest
        )
    }

    public static func from(selector: Selector, route: ControlActionRoute) -> CapabilityLocatorDescriptor? {
        guard selector.role != nil || selector.identifier != nil || selector.locatorDigest != nil
            || selector.ancestorDigest != nil || selector.geometryDigest != nil
            || selector.structuralDigest != nil || selector.title != nil else {
            return nil
        }
        let actions: [String]
        switch route {
        case .accessibility:
            actions = ["AXPress"]
        case .scroll:
            actions = ["AXScroll"]
        case .keyboard, .visual, .normalizedCoordinate, .rawCoordinate:
            actions = []
        }
        return CapabilityLocatorDescriptor(
            role: selector.role,
            subrole: selector.subrole,
            identifier: selector.identifier,
            labelDigest: selector.title.map(CapabilityProfileDigest.make),
            actions: actions,
            scrollable: route == .scroll,
            ancestorDigest: selector.ancestorDigest,
            geometryDigest: selector.geometryDigest,
            structuralDigest: selector.structuralDigest,
            identityDigest: selector.locatorDigest
        )
    }
}

public struct CapabilityEvidenceRecord: Codable, Equatable {
    public let capabilityID: String
    public let provider: String
    public let kind: CapabilityEvidenceKind
    public let reason: String
    public let taskID: String?
    public let targetFingerprintDigest: String?
    public let locatorDigest: String?
    public let observedAt: Date

    public init(
        capabilityID: String,
        provider: String,
        kind: CapabilityEvidenceKind,
        reason: String,
        taskID: String? = nil,
        targetFingerprintDigest: String? = nil,
        locatorDigest: String? = nil,
        observedAt: Date = Date()
    ) {
        self.capabilityID = capabilityID
        self.provider = provider
        self.kind = kind
        self.reason = reason
        self.taskID = taskID
        self.targetFingerprintDigest = targetFingerprintDigest
        self.locatorDigest = locatorDigest
        self.observedAt = observedAt
    }
}

public struct CapabilityRecord: Codable, Equatable {
    public let id: String
    public let provider: String
    public let state: CapabilityEvidenceDisposition
    public let positiveEvidenceCount: Int
    public let negativeEvidenceCount: Int
    public let ambiguousEvidenceCount: Int
    public let locatorDigests: [String]
    public let lastReason: String?
    public let lastVerifiedAt: Date?

    public init(
        id: String,
        provider: String,
        state: CapabilityEvidenceDisposition,
        positiveEvidenceCount: Int = 0,
        negativeEvidenceCount: Int = 0,
        ambiguousEvidenceCount: Int = 0,
        locatorDigests: [String] = [],
        lastReason: String? = nil,
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.state = state
        self.positiveEvidenceCount = max(0, positiveEvidenceCount)
        self.negativeEvidenceCount = max(0, negativeEvidenceCount)
        self.ambiguousEvidenceCount = max(0, ambiguousEvidenceCount)
        self.locatorDigests = Array(Set(locatorDigests)).sorted()
        self.lastReason = lastReason
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public enum AdvertisedCapabilityDiscoveryState: String, Codable, Equatable {
    case observed
    case partial
}

/// A redacted deep-audit observation of an app-published capability. This is
/// deliberately separate from runtime capability evidence so an advertisement
/// can never promote an execution route by itself.
public struct AdvertisedCapabilityObservation: Codable, Equatable {
    public let capabilityID: String
    public let provider: AppControlProvider
    public let source: AppAdvertisedCapabilitySource
    public let taskIDs: [String]
    public let keyboardShortcut: String?
    public let discoveryState: AdvertisedCapabilityDiscoveryState
    public let disposition: CapabilityEvidenceDisposition
    public let matchedSignalCount: Int
    public let requiredSignalCount: Int
    public let locatorDigests: [String]
    public let verificationMethods: [String]
    public let observedAt: Date

    public init(
        declaration: AppAdvertisedCapability,
        discoveryState: AdvertisedCapabilityDiscoveryState,
        matchedSignalCount: Int,
        locatorDigests: [String],
        observedAt: Date
    ) {
        self.capabilityID = declaration.id
        self.provider = declaration.provider
        self.source = declaration.source
        self.taskIDs = declaration.taskIDs
        self.keyboardShortcut = declaration.keyboardShortcut
        self.discoveryState = discoveryState
        self.disposition = .candidate
        self.matchedSignalCount = max(0, matchedSignalCount)
        self.requiredSignalCount = declaration.discoverySignals.count
        self.locatorDigests = Array(Set(locatorDigests)).sorted()
        self.verificationMethods = declaration.verificationMethods
        self.observedAt = observedAt
    }
}

public enum CapabilityLeadKind: String, Codable, Equatable, Hashable {
    case keyboardNavigation = "keyboard_navigation"
    case shortcutCatalog = "shortcut_catalog"
    case quickSwitcher = "quick_switcher"
    case commandPalette = "command_palette"
    case keyboardSearch = "keyboard_search"
}

public enum CapabilityLeadConfidence: String, Codable, Equatable {
    case high
    case medium
    case ambiguous
}

/// A generic, redacted capability candidate inferred from an app-owned menu,
/// help, onboarding, dialog, or control surface. A lead is planning evidence,
/// never execution authority or a measured route.
public struct CapabilityLeadObservation: Codable, Equatable {
    public let leadID: String
    public let kind: CapabilityLeadKind
    public let provider: AppControlProvider
    public let source: AppAdvertisedCapabilitySource
    public let taskIDs: [String]
    public let keyboardShortcut: String?
    public let signalKinds: [String]
    public let confidence: CapabilityLeadConfidence
    public let disposition: CapabilityEvidenceDisposition
    public let positiveEvidenceCount: Int
    public let negativeEvidenceCount: Int
    public let ambiguousEvidenceCount: Int
    public let locatorDigests: [String]
    public let matchedAdvertisedCapabilityIDs: [String]
    public let verificationMethods: [String]
    public let observedAt: Date
    public let lastVerifiedAt: Date?
    public let lastReason: String?

    public init(
        leadID: String,
        kind: CapabilityLeadKind,
        provider: AppControlProvider,
        source: AppAdvertisedCapabilitySource,
        taskIDs: [String],
        keyboardShortcut: String?,
        signalKinds: [String],
        confidence: CapabilityLeadConfidence,
        disposition: CapabilityEvidenceDisposition = .candidate,
        positiveEvidenceCount: Int = 0,
        negativeEvidenceCount: Int = 0,
        ambiguousEvidenceCount: Int = 1,
        locatorDigests: [String],
        matchedAdvertisedCapabilityIDs: [String] = [],
        verificationMethods: [String],
        observedAt: Date,
        lastVerifiedAt: Date? = nil,
        lastReason: String? = "read_only_discovery_requires_task_verification"
    ) {
        self.leadID = leadID
        self.kind = kind
        self.provider = provider
        self.source = source
        self.taskIDs = Array(Set(taskIDs)).sorted()
        self.keyboardShortcut = keyboardShortcut
        self.signalKinds = Array(Set(signalKinds)).sorted()
        self.confidence = confidence
        self.disposition = disposition
        self.positiveEvidenceCount = max(0, positiveEvidenceCount)
        self.negativeEvidenceCount = max(0, negativeEvidenceCount)
        self.ambiguousEvidenceCount = max(0, ambiguousEvidenceCount)
        self.locatorDigests = Array(Set(locatorDigests)).sorted()
        self.matchedAdvertisedCapabilityIDs = Array(Set(matchedAdvertisedCapabilityIDs)).sorted()
        self.verificationMethods = Array(Set(verificationMethods)).sorted()
        self.observedAt = observedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.lastReason = lastReason
    }

    func recording(
        kind evidenceKind: CapabilityEvidenceKind,
        reason: String,
        at timestamp: Date
    ) -> CapabilityLeadObservation {
        let nextDisposition: CapabilityEvidenceDisposition = switch evidenceKind {
        case .positive: .promoted
        case .negative: .demoted
        case .ambiguous: .candidate
        }
        return CapabilityLeadObservation(
            leadID: leadID,
            kind: kind,
            provider: provider,
            source: source,
            taskIDs: taskIDs,
            keyboardShortcut: keyboardShortcut,
            signalKinds: signalKinds,
            confidence: confidence,
            disposition: nextDisposition,
            positiveEvidenceCount: positiveEvidenceCount + (evidenceKind == .positive ? 1 : 0),
            negativeEvidenceCount: negativeEvidenceCount + (evidenceKind == .negative ? 1 : 0),
            ambiguousEvidenceCount: ambiguousEvidenceCount + (evidenceKind == .ambiguous ? 1 : 0),
            locatorDigests: locatorDigests,
            matchedAdvertisedCapabilityIDs: matchedAdvertisedCapabilityIDs,
            verificationMethods: verificationMethods,
            observedAt: observedAt,
            lastVerifiedAt: timestamp,
            lastReason: reason
        )
    }
}

public struct CapabilityAuditProfile: Codable, Equatable {
    public let schemaVersion: Int
    public let identity: CapabilityCacheIdentity
    public let providerState: CapabilityProviderState
    public let archetype: MacAppArchetype
    public let auditDepth: CapabilityAuditDepth
    public let state: CapabilityProfileState
    public let treeNodeCount: Int
    public let treeTruncated: Bool
    public let locators: [CapabilityLocatorDescriptor]
    public let capabilities: [CapabilityRecord]
    /// Optional preserves decoding of schema-v1 profiles written before app
    /// advertisement discovery was added. New profiles always write an array.
    public let advertisedCapabilities: [AdvertisedCapabilityObservation]?
    /// Optional preserves decoding of profiles written before generic,
    /// candidate-only capability lead discovery was added.
    public let capabilityLeads: [CapabilityLeadObservation]?
    public let evidence: [CapabilityEvidenceRecord]
    public let invalidationReasons: [CapabilityProfileInvalidationReason]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        identity: CapabilityCacheIdentity,
        providerState: CapabilityProviderState,
        archetype: MacAppArchetype,
        auditDepth: CapabilityAuditDepth = .deepReadOnly,
        state: CapabilityProfileState = .valid,
        treeNodeCount: Int,
        treeTruncated: Bool,
        locators: [CapabilityLocatorDescriptor],
        capabilities: [CapabilityRecord],
        advertisedCapabilities: [AdvertisedCapabilityObservation]? = [],
        capabilityLeads: [CapabilityLeadObservation]? = [],
        evidence: [CapabilityEvidenceRecord] = [],
        invalidationReasons: [CapabilityProfileInvalidationReason] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.providerState = providerState
        self.archetype = archetype
        self.auditDepth = auditDepth
        self.state = state
        self.treeNodeCount = max(0, treeNodeCount)
        self.treeTruncated = treeTruncated
        self.locators = locators
        self.capabilities = capabilities
        self.advertisedCapabilities = advertisedCapabilities
        self.capabilityLeads = capabilityLeads
        self.evidence = evidence
        self.invalidationReasons = Array(Set(invalidationReasons))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var deepAuditRecommended: Bool {
        state != .valid || treeTruncated || auditDepth != .deepReadOnly
    }
}

public struct CapabilityProfileCacheSummary: Codable, Equatable {
    public let cacheHit: Bool
    public let profileState: CapabilityProfileState?
    public let auditDepth: CapabilityAuditDepth?
    public let treeSignature: String?
    public let promotedCapabilities: [String]
    public let candidateCapabilities: [String]
    public let demotedCapabilities: [String]
    public let advertisedCapabilities: [AdvertisedCapabilityObservation]
    public let capabilityLeads: [CapabilityLeadObservation]
    public let invalidationReasons: [CapabilityProfileInvalidationReason]
    public let deepAuditRecommended: Bool

    init(
        cacheHit: Bool,
        profileState: CapabilityProfileState?,
        auditDepth: CapabilityAuditDepth?,
        treeSignature: String?,
        promotedCapabilities: [String],
        candidateCapabilities: [String],
        demotedCapabilities: [String],
        advertisedCapabilities: [AdvertisedCapabilityObservation],
        capabilityLeads: [CapabilityLeadObservation],
        invalidationReasons: [CapabilityProfileInvalidationReason],
        deepAuditRecommended: Bool
    ) {
        self.cacheHit = cacheHit
        self.profileState = profileState
        self.auditDepth = auditDepth
        self.treeSignature = treeSignature
        self.promotedCapabilities = promotedCapabilities
        self.candidateCapabilities = candidateCapabilities
        self.demotedCapabilities = demotedCapabilities
        self.advertisedCapabilities = advertisedCapabilities
        self.capabilityLeads = capabilityLeads
        self.invalidationReasons = invalidationReasons
        self.deepAuditRecommended = deepAuditRecommended
    }

    public init(profile: CapabilityAuditProfile?, cacheHit: Bool) {
        self.cacheHit = cacheHit
        self.profileState = profile?.state
        self.auditDepth = profile?.auditDepth
        self.treeSignature = profile?.identity.treeSignature
        self.promotedCapabilities = profile?.capabilities
            .filter { $0.state == .promoted }
            .map(\.id)
            .sorted() ?? []
        self.candidateCapabilities = profile?.capabilities
            .filter { $0.state == .candidate }
            .map(\.id)
            .sorted() ?? []
        self.demotedCapabilities = profile?.capabilities
            .filter { $0.state == .demoted }
            .map(\.id)
            .sorted() ?? []
        self.advertisedCapabilities = profile?.advertisedCapabilities ?? []
        self.capabilityLeads = profile?.capabilityLeads ?? []
        self.invalidationReasons = profile?.invalidationReasons ?? []
        self.deepAuditRecommended = profile?.deepAuditRecommended ?? true
    }
}

public struct CapabilityProfileLookup: Codable, Equatable {
    public let profile: CapabilityAuditProfile?
    public let cacheHit: Bool
    public let invalidationReasons: [CapabilityProfileInvalidationReason]

    public init(
        profile: CapabilityAuditProfile?,
        cacheHit: Bool,
        invalidationReasons: [CapabilityProfileInvalidationReason] = []
    ) {
        self.profile = profile
        self.cacheHit = cacheHit
        self.invalidationReasons = Array(Set(invalidationReasons))
    }

    public var summary: CapabilityProfileCacheSummary {
        let summary = CapabilityProfileCacheSummary(profile: profile, cacheHit: cacheHit)
        guard !invalidationReasons.isEmpty else { return summary }
        return CapabilityProfileCacheSummary(
            cacheHit: summary.cacheHit,
            profileState: summary.profileState,
            auditDepth: summary.auditDepth,
            treeSignature: summary.treeSignature,
            promotedCapabilities: summary.promotedCapabilities,
            candidateCapabilities: summary.candidateCapabilities,
            demotedCapabilities: summary.demotedCapabilities,
            advertisedCapabilities: summary.advertisedCapabilities,
            capabilityLeads: summary.capabilityLeads,
            invalidationReasons: Array(Set(summary.invalidationReasons + invalidationReasons)),
            deepAuditRecommended: true
        )
    }
}

public enum CapabilityProfileStoreError: Error, LocalizedError, Equatable {
    case invalidProfile(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let message): return "Invalid capability profile: \(message)"
        case .writeFailed(let message): return "Could not persist capability profile: \(message)"
        }
    }
}

public enum CapabilityProfileDigest {
    public static func make(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func geometry(_ bounds: CGRect) -> String {
        let values = [
            bounds.origin.x,
            bounds.origin.y,
            bounds.size.width,
            bounds.size.height
        ].map { String(format: "%.1f", Double($0)) }
        return make(values.joined(separator: "|"))
    }
}

public enum CapabilityProfileBuilder {
    public static func treeSignature(_ tree: AccessibilityTreeReport) -> String {
        let nodes = tree.nodes.map { node in
            let labelDigest = node.label.map(CapabilityProfileDigest.make) ?? ""
            return [
                node.role ?? "",
                node.subrole ?? "",
                node.identifier ?? "",
                labelDigest,
                node.actions.sorted().joined(separator: ","),
                node.scrollable ? "1" : "0",
                node.bounds.map(CapabilityProfileDigest.geometry) ?? "",
                String(node.childCount),
                node.structuralDigest ?? ""
            ].joined(separator: "|")
        }.joined(separator: "||")
        let coverage = tree.coverage?.signature ?? "recursive"
        return CapabilityProfileDigest.make(
            "nodes=\(tree.nodeCount)|truncated=\(tree.truncated ? 1 : 0)|coverage=\(coverage)|\(nodes)"
        )
    }

    /// Builds the same redacted locator identity used by broad profiles for a
    /// node in a fresh tree. Task-specific verification uses this helper so a
    /// read-only observation and a later action resolver cannot disagree about
    /// locator or ancestor digests.
    public static func locatorDescriptor(
        for node: AccessibilityTreeNode,
        nodesByPath: [String: AccessibilityTreeNode]
    ) -> CapabilityLocatorDescriptor? {
        CapabilityLocatorDescriptor.from(
            treeNode: node,
            ancestorDigest: ancestorDigest(for: node, nodesByPath: nodesByPath)
        )
    }

    public static func build(
        application: AppInfo,
        osVersion: String,
        providerState: CapabilityProviderState,
        tree: AccessibilityTreeReport,
        now: Date = Date()
    ) -> CapabilityAuditProfile {
        let nodesByPath = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.path, $0) })
        let allLocators = tree.nodes.compactMap {
            locatorDescriptor(for: $0, nodesByPath: nodesByPath)
        }
        let locators = deduplicateLocators(allLocators)
        let hasPress = tree.nodes.contains { $0.actions.contains("AXPress") }
        let activationLocators = allLocators.filter { locator in
            AccessibilityController.semanticActivationAction(
                role: locator.role,
                subrole: locator.subrole,
                actions: locator.actions
            ) != nil
        }
        let hasSemanticActivation = !activationLocators.isEmpty
        let presentationLocators = allLocators.filter { locator in
            AccessibilityController.semanticPresentationAction(
                role: locator.role,
                subrole: locator.subrole,
                actions: locator.actions
            ) != nil
        }
        let hasPresentationAction = !presentationLocators.isEmpty
        let scrollLocators = allLocators.filter(\.scrollable)
        let hasScroll = !scrollLocators.isEmpty
        let hasDirectionalScroll = tree.nodes.contains { node in
            guard node.role == "AXScrollArea" else { return false }
            return AccessibilityScrollDirection.allCases.contains { direction in
                direction.actionName(matching: node.actions) != nil
            }
        }
        let ambiguousScroll = hasDuplicateLocator(scrollLocators)
        let hasSettableValue = tree.nodes.contains { $0.state.settable }
        let complete = !tree.truncated
        let appProfile = AppControlProfileRegistry.standard.profile(
            for: WarmPathApplicationIdentity(application: application)
        )
        let advertisedCapabilities = advertisedCapabilityObservations(
            declarations: appProfile.advertisedCapabilities,
            tree: tree,
            nodesByPath: nodesByPath,
            now: now
        )
        let capabilityLeads = genericCapabilityLeadObservations(
            declarations: appProfile.advertisedCapabilities,
            advertisedObservations: advertisedCapabilities,
            tree: tree,
            nodesByPath: nodesByPath,
            now: now
        )
        let capabilities = [
            observedCapability(
                id: "accessibility_tree",
                provider: "accessibility",
                positive: tree.nodeCount > 0 && complete,
                ambiguous: tree.nodeCount > 0 && tree.truncated,
                reason: tree.truncated ? "bounded_tree_truncated" : "bounded_tree_observed",
                locators: locators
            ),
            observedCapability(
                id: "ax_press",
                provider: "accessibility",
                positive: hasPress,
                ambiguous: !hasPress && tree.truncated,
                reason: hasPress ? "AXPress_observed" : (tree.truncated ? "AXPress_not_observed_in_truncated_tree" : "AXPress_not_present_in_complete_tree"),
                locators: locators.filter { $0.actions.contains("AXPress") }
            ),
            observedCapability(
                id: "ax_activation",
                provider: "accessibility",
                positive: hasSemanticActivation,
                ambiguous: !hasSemanticActivation && tree.truncated,
                reason: hasSemanticActivation
                    ? "semantic_activation_action_observed"
                    : (tree.truncated
                        ? "semantic_activation_not_observed_in_truncated_tree"
                        : "semantic_activation_not_present_in_complete_tree"),
                locators: activationLocators
            ),
            observedCapability(
                id: "ax_presentation",
                provider: "accessibility",
                positive: hasPresentationAction,
                ambiguous: !hasPresentationAction && tree.truncated,
                reason: hasPresentationAction
                    ? "presentation_action_observed"
                    : (tree.truncated
                        ? "presentation_action_not_observed_in_truncated_tree"
                        : "presentation_action_not_present_in_complete_tree"),
                locators: presentationLocators
            ),
            observedCapability(
                id: "semantic_scroll",
                provider: "accessibility",
                positive: hasDirectionalScroll && !ambiguousScroll,
                ambiguous: ambiguousScroll
                    || (hasScroll && !hasDirectionalScroll)
                    || (!hasScroll && tree.truncated),
                reason: ambiguousScroll
                    ? "repeated_scroll_locator_ambiguous"
                    : (hasDirectionalScroll
                        ? "directional_scroll_action_observed"
                        : (hasScroll
                            ? "directional_scroll_action_not_observed"
                            : (tree.truncated
                                ? "scrollable_element_not_observed_in_truncated_tree"
                                : "scrollable_element_not_present_in_complete_tree"))),
                locators: locators.filter(\.scrollable)
            ),
            observedCapability(
                id: "settable_ax_value",
                provider: "accessibility",
                positive: hasSettableValue,
                ambiguous: !hasSettableValue && tree.truncated,
                reason: hasSettableValue ? "settable_AX_value_observed" : (tree.truncated ? "settable_value_not_observed_in_truncated_tree" : "settable_value_not_present_in_complete_tree"),
                locators: locators
            ),
            CapabilityRecord(
                id: "keyboard",
                provider: "keyboard",
                state: .candidate,
                ambiguousEvidenceCount: 1,
                lastReason: "deep_AX_audit_does_not_execute_keyboard_input",
                lastVerifiedAt: now
            ),
            CapabilityRecord(
                id: "computer_use_handoff",
                provider: "computer_use",
                state: .candidate,
                ambiguousEvidenceCount: 1,
                lastReason: "provider_handoff_is_declared_but_not_executed_by_mac_control",
                lastVerifiedAt: now
            )
        ]
        let treeSignature = treeSignature(tree)
        let invalidationReasons: [CapabilityProfileInvalidationReason] = tree.truncated
            ? [.deepAuditTruncated]
            : []
        return CapabilityAuditProfile(
            identity: CapabilityCacheIdentity(
                application: WarmPathApplicationIdentity(application: application),
                osVersion: osVersion,
                providerStateSignature: providerState.signature,
                treeSignature: treeSignature
            ),
            providerState: providerState,
            archetype: MacAppArchetypeClassifier.classify(WarmPathApplicationIdentity(application: application)),
            auditDepth: .deepReadOnly,
            state: tree.truncated ? .stale : .valid,
            treeNodeCount: tree.nodeCount,
            treeTruncated: tree.truncated,
            locators: locators,
            capabilities: capabilities,
            advertisedCapabilities: advertisedCapabilities,
            capabilityLeads: capabilityLeads,
            evidence: [],
            invalidationReasons: invalidationReasons,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func advertisedCapabilityObservations(
        declarations: [AppAdvertisedCapability],
        tree: AccessibilityTreeReport,
        nodesByPath: [String: AccessibilityTreeNode],
        now: Date
    ) -> [AdvertisedCapabilityObservation] {
        guard !declarations.isEmpty else { return [] }
        let labeledNodes = tree.nodes.compactMap { node -> (AccessibilityTreeNode, String)? in
            guard node.state.visible, let label = node.label else { return nil }
            let normalized = normalizeDiscoveryText(label)
            return normalized.isEmpty ? nil : (node, normalized)
        }
        let corpus = labeledNodes.map(\.1).joined(separator: " ")

        return declarations.compactMap { declaration -> AdvertisedCapabilityObservation? in
            let signals = declaration.discoverySignals
                .map(normalizeDiscoveryText)
                .filter { !$0.isEmpty }
            guard !signals.isEmpty else { return nil }
            let matchedSignals = signals.filter { corpus.contains($0) }
            guard !matchedSignals.isEmpty else { return nil }

            let matchingLocators = labeledNodes.compactMap { pair -> CapabilityLocatorDescriptor? in
                let (node, label) = pair
                guard matchedSignals.contains(where: { label.contains($0) }) else { return nil }
                return CapabilityLocatorDescriptor.from(
                    treeNode: node,
                    ancestorDigest: ancestorDigest(for: node, nodesByPath: nodesByPath)
                )
            }
            return AdvertisedCapabilityObservation(
                declaration: declaration,
                discoveryState: matchedSignals.count == signals.count ? .observed : .partial,
                matchedSignalCount: matchedSignals.count,
                locatorDigests: matchingLocators.map(\.identityDigest),
                observedAt: now
            )
        }
    }

    private struct CapabilityLeadCandidate {
        let kind: CapabilityLeadKind
        let source: AppAdvertisedCapabilitySource
        let taskIDs: [String]
        let shortcuts: Set<String>
        let signalKinds: [String]
        let locatorDigests: [String]
        let verificationMethods: [String]
    }

    private static func genericCapabilityLeadObservations(
        declarations: [AppAdvertisedCapability],
        advertisedObservations: [AdvertisedCapabilityObservation],
        tree: AccessibilityTreeReport,
        nodesByPath: [String: AccessibilityTreeNode],
        now: Date
    ) -> [CapabilityLeadObservation] {
        let visibleLabeledNodes = tree.nodes.filter {
            $0.state.visible && !($0.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let nodesByParent = Dictionary(grouping: visibleLabeledNodes) { parentPath($0.path) }
        var candidatesByKind: [CapabilityLeadKind: [CapabilityLeadCandidate]] = [:]

        for node in visibleLabeledNodes {
            let ancestors = ancestorNodes(for: node, nodesByPath: nodesByPath)
            guard isCapabilityDiscoverySurface(node: node, ancestors: ancestors) else { continue }
            let normalizedLabel = normalizeDiscoveryText(node.label ?? "")
            guard !normalizedLabel.isEmpty else { continue }
            let contextNodes = nodesByParent[parentPath(node.path)] ?? [node]
            let directShortcuts = Set(extractKeyboardShortcuts(from: node.label ?? ""))
            let nearbyText = nearbySiblingNodes(for: node, in: contextNodes)
                .compactMap(\.label)
                .joined(separator: " ")
            let nearbyShortcuts = Set(extractKeyboardShortcuts(from: nearbyText))
            let candidateShortcuts = directShortcuts.isEmpty ? nearbyShortcuts : directShortcuts
            guard let semantic = classifyCapabilityLead(
                normalizedLabel: normalizedLabel,
                shortcuts: candidateShortcuts
            ) else { continue }
            let shortcuts = semantic.kind == .keyboardNavigation ? [] : candidateShortcuts
            guard let locator = CapabilityLocatorDescriptor.from(
                treeNode: node,
                ancestorDigest: ancestorDigest(for: node, nodesByPath: nodesByPath)
            ) else { continue }
            let candidate = CapabilityLeadCandidate(
                kind: semantic.kind,
                source: capabilityLeadSource(node: node, ancestors: ancestors),
                taskIDs: semantic.taskIDs,
                shortcuts: shortcuts,
                signalKinds: semantic.signalKinds + (shortcuts.isEmpty ? [] : ["keyboard_chord"]),
                locatorDigests: [locator.identityDigest],
                verificationMethods: semantic.verificationMethods
            )
            candidatesByKind[semantic.kind, default: []].append(candidate)
        }

        let observedDeclarations = declarations.filter { declaration in
            advertisedObservations.contains { $0.capabilityID == declaration.id }
        }
        return candidatesByKind.compactMap { kind, candidates -> CapabilityLeadObservation? in
            guard !candidates.isEmpty else { return nil }
            let allShortcuts = Set(candidates.flatMap(\.shortcuts))
            let locatorDigests = Array(Set(candidates.flatMap(\.locatorDigests))).sorted()
            let locatorSet = Set(locatorDigests)
            let matchedDeclarations = observedDeclarations.filter { declaration in
                guard let observation = advertisedObservations.first(where: {
                    $0.capabilityID == declaration.id
                }) else { return false }
                let locatorMatch = !locatorSet.isDisjoint(with: observation.locatorDigests)
                let shortcutMatch = declaration.keyboardShortcut.map(allShortcuts.contains) == true
                return locatorMatch || shortcutMatch
            }
            let reconciledShortcuts = allShortcuts.union(
                matchedDeclarations.compactMap(\.keyboardShortcut)
            )
            let keyboardShortcut = reconciledShortcuts.count == 1 ? reconciledShortcuts.first : nil
            let source = candidates.map(\.source).sorted {
                capabilitySourceRank($0) < capabilitySourceRank($1)
            }.first ?? .accessibilityDisclosure
            let taskIDs = candidates.flatMap(\.taskIDs) + matchedDeclarations.flatMap(\.taskIDs)
            let verificationMethods = candidates.flatMap(\.verificationMethods)
                + matchedDeclarations.flatMap(\.verificationMethods)
            var signalKinds = candidates.flatMap(\.signalKinds)
            if !matchedDeclarations.isEmpty {
                signalKinds.append("declared_capability_match")
            }
            let confidence: CapabilityLeadConfidence
            if reconciledShortcuts.count > 1 {
                confidence = .ambiguous
            } else if keyboardShortcut != nil || kind == .keyboardNavigation {
                confidence = .high
            } else {
                confidence = .medium
            }
            let shortcutIdentity = keyboardShortcut.map(CapabilityProfileDigest.make) ?? "unspecified"
            return CapabilityLeadObservation(
                leadID: "lead.\(kind.rawValue).\(shortcutIdentity.prefix(12))",
                kind: kind,
                provider: .keyboard,
                source: source,
                taskIDs: taskIDs,
                keyboardShortcut: keyboardShortcut,
                signalKinds: signalKinds,
                confidence: confidence,
                locatorDigests: locatorDigests,
                matchedAdvertisedCapabilityIDs: matchedDeclarations.map(\.id),
                verificationMethods: verificationMethods,
                observedAt: now
            )
        }.sorted { $0.leadID < $1.leadID }
    }

    private static func classifyCapabilityLead(
        normalizedLabel: String,
        shortcuts: Set<String>
    ) -> (
        kind: CapabilityLeadKind,
        taskIDs: [String],
        signalKinds: [String],
        verificationMethods: [String]
    )? {
        if normalizedLabel.contains("quick switcher") {
            return (
                .quickSwitcher,
                ["open-quick-switcher"],
                ["quick_switcher_label"],
                ["quick_switcher_present", "foreground_unchanged"]
            )
        }
        if normalizedLabel.contains("command palette")
            || normalizedLabel.contains("command menu") {
            return (
                .commandPalette,
                ["open-command-palette"],
                ["command_palette_label"],
                ["command_palette_present", "foreground_unchanged"]
            )
        }
        if normalizedLabel.contains("keyboard shortcuts")
            || normalizedLabel.contains("shortcut catalog")
            || normalizedLabel.contains("shortcut list") {
            return (
                .shortcutCatalog,
                ["open-shortcut-catalog"],
                ["shortcut_catalog_label"],
                ["shortcut_catalog_present", "foreground_unchanged"]
            )
        }
        let advertisesNavigation = normalizedLabel.contains("navigate")
            || normalizedLabel.contains("navigation")
        let advertisesTab = normalizedLabel.contains(" tab ")
            || normalizedLabel.hasPrefix("tab ")
            || normalizedLabel.hasSuffix(" tab")
        let advertisesArrow = normalizedLabel.contains("arrow")
        if normalizedLabel.contains("keyboard navigation")
            || (advertisesNavigation && advertisesTab && advertisesArrow) {
            return (
                .keyboardNavigation,
                ["next-control", "previous-control"],
                ["keyboard_navigation_label", "tab_and_arrow_keys"],
                ["focused_element_change", "foreground_unchanged"]
            )
        }
        if normalizedLabel.contains("search"), !shortcuts.isEmpty,
           normalizedLabel.contains("press")
            || normalizedLabel.contains("open")
            || normalizedLabel.contains("focus") {
            return (
                .keyboardSearch,
                ["focus-search"],
                ["keyboard_search_label"],
                ["search_field_focused", "foreground_unchanged"]
            )
        }
        return nil
    }

    private static func isCapabilityDiscoverySurface(
        node: AccessibilityTreeNode,
        ancestors: [AccessibilityTreeNode]
    ) -> Bool {
        let directRoles = Set(["AXMenuItem", "AXButton", "AXLink"])
        if let role = node.role, directRoles.contains(role) { return true }
        let contextRoles = Set(["AXDialog", "AXSheet", "AXPopover", "AXMenu", "AXMenuBar"])
        if ancestors.contains(where: { $0.role.map(contextRoles.contains) == true }) { return true }
        let contextIdentity = ([node.identifier].compactMap { $0 } + ancestors.flatMap {
            [$0.identifier, $0.label].compactMap { $0 }
        }).map(normalizeDiscoveryText).joined(separator: " ")
        let contextTerms = [
            "accessibility", "disclosure", "onboarding", "keyboard", "shortcut",
            "tutorial", "help", "guide", "quick switcher", "command palette"
        ]
        return contextTerms.contains { contextIdentity.contains($0) }
    }

    private static func capabilityLeadSource(
        node: AccessibilityTreeNode,
        ancestors: [AccessibilityTreeNode]
    ) -> AppAdvertisedCapabilitySource {
        if ([node] + ancestors).contains(where: {
            $0.role == "AXMenuItem" || $0.role == "AXMenu" || $0.role == "AXMenuBar"
        }) {
            return .appMenu
        }
        let context = ([node] + ancestors).flatMap {
            [$0.identifier, $0.label].compactMap { $0 }
        }.map(normalizeDiscoveryText).joined(separator: " ")
        if ["help", "guide", "tutorial", "shortcut"].contains(where: { context.contains($0) }) {
            return .helpSurface
        }
        return .accessibilityDisclosure
    }

    private static func capabilitySourceRank(_ source: AppAdvertisedCapabilitySource) -> Int {
        switch source {
        case .appMenu: 0
        case .helpSurface: 1
        case .accessibilityDisclosure: 2
        }
    }

    static func extractKeyboardShortcuts(from value: String) -> [String] {
        let pattern = #"(?i)(?:(?:control|ctrl|⌃|option|opt|alt|⌥|shift|⇧|command|cmd|⌘)[\s+\-]*){1,5}(?:pageup|pagedown|space|return|tab|left|right|up|down|home|end|f(?:[1-9]|1[0-9]|20)|[a-z0-9/.,;=])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return Array(Set(expression.matches(in: value, range: range).compactMap { match in
            guard let rawRange = Range(match.range, in: value) else { return nil }
            return canonicalShortcut(from: String(value[rawRange]))
        })).sorted()
    }

    private static func canonicalShortcut(from value: String) -> String? {
        let lower = value.lowercased()
        var modifiers = Set<String>()
        if lower.contains("control") || lower.contains("ctrl") || lower.contains("⌃") {
            modifiers.insert("ctrl")
        }
        if lower.contains("option") || lower.contains("opt")
            || lower.contains("alt") || lower.contains("⌥") {
            modifiers.insert("option")
        }
        if lower.contains("shift") || lower.contains("⇧") {
            modifiers.insert("shift")
        }
        if lower.contains("command") || lower.contains("cmd") || lower.contains("⌘") {
            modifiers.insert("cmd")
        }
        let keyPattern = #"(?i)(pageup|pagedown|space|return|tab|left|right|up|down|home|end|f(?:[1-9]|1[0-9]|20)|[a-z0-9/.,;=])\s*$"#
        guard let expression = try? NSRegularExpression(pattern: keyPattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let keyRange = Range(match.range(at: 1), in: value) else { return nil }
        let key = String(value[keyRange]).lowercased()
        let ordered = ["ctrl", "option", "shift", "cmd"].filter(modifiers.contains)
        guard let chord = try? ShortcutChord((ordered + [key]).joined(separator: "+")) else {
            return nil
        }
        return chord.canonical
    }

    private static func parentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return path }
        return String(path[..<separator])
    }

    private static func nearbySiblingNodes(
        for node: AccessibilityTreeNode,
        in siblings: [AccessibilityTreeNode]
    ) -> [AccessibilityTreeNode] {
        guard let index = siblingIndex(node.path) else { return [node] }
        return siblings.filter { sibling in
            guard let siblingIndex = siblingIndex(sibling.path) else {
                return sibling.path == node.path
            }
            return abs(siblingIndex - index) <= 2
        }
    }

    private static func siblingIndex(_ path: String) -> Int? {
        guard let component = path.split(separator: "/").last else { return nil }
        return Int(component)
    }

    private static func ancestorNodes(
        for node: AccessibilityTreeNode,
        nodesByPath: [String: AccessibilityTreeNode]
    ) -> [AccessibilityTreeNode] {
        var path = node.path
        var result: [AccessibilityTreeNode] = []
        while let separator = path.lastIndex(of: "/") {
            path = String(path[..<separator])
            if let ancestor = nodesByPath[path] {
                result.append(ancestor)
            }
        }
        return result
    }

    private static func normalizeDiscoveryText(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func observedCapability(
        id: String,
        provider: String,
        positive: Bool,
        ambiguous: Bool,
        reason: String,
        locators: [CapabilityLocatorDescriptor]
    ) -> CapabilityRecord {
        let kind: CapabilityEvidenceKind = positive ? .positive : (ambiguous ? .ambiguous : .negative)
        let state: CapabilityEvidenceDisposition = switch kind {
        case .positive: .promoted
        case .negative: .demoted
        case .ambiguous: .candidate
        }
        return CapabilityRecord(
            id: id,
            provider: provider,
            state: state,
            positiveEvidenceCount: kind == .positive ? 1 : 0,
            negativeEvidenceCount: kind == .negative ? 1 : 0,
            ambiguousEvidenceCount: kind == .ambiguous ? 1 : 0,
            locatorDigests: locators.map(\.identityDigest),
            lastReason: reason
        )
    }

    private static func deduplicateLocators(
        _ locators: [CapabilityLocatorDescriptor]
    ) -> [CapabilityLocatorDescriptor] {
        var seen = Set<String>()
        return locators.filter {
            seen.insert(
                "\($0.identityDigest)|\($0.ancestorDigest ?? "")|\($0.geometryDigest ?? "")|\($0.structuralDigest ?? "")"
            ).inserted
        }
    }

    private static func hasDuplicateLocator(
        _ locators: [CapabilityLocatorDescriptor]
    ) -> Bool {
        var counts: [String: Int] = [:]
        for locator in locators {
            let key = "\(locator.identityDigest)|\(locator.ancestorDigest ?? "")|\(locator.geometryDigest ?? "")|\(locator.structuralDigest ?? "")"
            counts[key, default: 0] += 1
        }
        return counts.values.contains { $0 > 1 }
    }

    private static func ancestorDigest(
        for node: AccessibilityTreeNode,
        nodesByPath: [String: AccessibilityTreeNode]
    ) -> String? {
        var path = node.path
        var identities: [String] = []
        while let separator = path.lastIndex(of: "/") {
            path = String(path[..<separator])
            // The recursive audit's application root is a traversal anchor,
            // not a useful task scope. Windowed audits start at wN and keep
            // that concrete window descriptor in the chain.
            guard path != "0", let parent = nodesByPath[path] else { continue }
            let descriptor = CapabilityLocatorDescriptor.fromAccessibilityIdentity(
                role: parent.role,
                subrole: parent.subrole,
                identifier: parent.identifier,
                label: parent.label,
                actions: parent.actions,
                scrollable: parent.scrollable
            )
            identities.append(descriptor.identityDigest)
        }
        guard !identities.isEmpty else { return nil }
        return CapabilityProfileDigest.make(identities.reversed().joined(separator: "|"))
    }
}

public final class CapabilityProfileStore {
    private let fileManager: FileManager
    private let now: () -> Date
    public let directory: URL

    public init(
        directory: URL = MacCtlPaths.capabilityProfilesDirectory,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
    }

    public func list() -> [CapabilityAuditProfile] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONCodec.decode(CapabilityAuditProfile.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Fast lookup is identity/provider keyed and does not read the AX tree.
    /// A stale profile is returned as evidence, but its summary requires a
    /// deep audit before a new broad profile is trusted.
    public func lookup(
        application: AppInfo,
        osVersion: String,
        providerState: CapabilityProviderState
    ) -> CapabilityProfileLookup {
        let identity = WarmPathApplicationIdentity(application: application)
        let all = list()
        let exact = all.filter {
            sameCacheApplicationIdentity($0.identity.application, identity)
                && $0.identity.osVersion == osVersion
                && $0.identity.providerStateSignature == providerState.signature
                && $0.state != .invalidated
        }.sorted { $0.updatedAt > $1.updatedAt }
        // Historical profiles explain a cache miss, but they must not make a
        // newly refreshed exact profile look stale forever. Otherwise every
        // fast capability probe schedules another deep audit after an app,
        // OS, or provider transition even though current evidence exists.
        let reasons = exact.isEmpty ? all.flatMap { profile -> [CapabilityProfileInvalidationReason] in
            let sameBundleID = profile.identity.application.bundleID != nil
                && profile.identity.application.bundleID == identity.bundleID
            let samePath = profile.identity.application.path == identity.path
            guard sameBundleID || samePath else { return [] }
            var result: [CapabilityProfileInvalidationReason] = []
            if profile.identity.application.path != identity.path
                || profile.identity.application.bundleID != identity.bundleID {
                result.append(.applicationIdentityChanged)
            } else if profile.identity.application.version != identity.version {
                result.append(.applicationVersionChanged)
            }
            if profile.identity.osVersion != osVersion {
                result.append(.osChanged)
            }
            if profile.identity.providerStateSignature != providerState.signature {
                result.append(.providerStateChanged)
            }
            return result
        } : []
        return CapabilityProfileLookup(
            profile: exact.first,
            cacheHit: exact.first != nil,
            invalidationReasons: Array(Set(reasons))
        )
    }

    @discardableResult
    public func save(_ profile: CapabilityAuditProfile) throws -> CapabilityAuditProfile {
        guard profile.schemaVersion == 1 else {
            throw CapabilityProfileStoreError.invalidProfile("unsupported schema version")
        }
        guard !profile.identity.application.path.isEmpty,
              !profile.identity.osVersion.isEmpty,
              !profile.identity.treeSignature.isEmpty else {
            throw CapabilityProfileStoreError.invalidProfile("application, OS, and tree identity are required")
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try invalidateSupersededProfiles(by: profile)
            try persist(profile)
            return profile
        } catch let error as CapabilityProfileStoreError {
            throw error
        } catch {
            throw CapabilityProfileStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Records task-specific evidence only when a matching deep profile
    /// exists. It never creates a profile from an action outcome alone.
    @discardableResult
    public func recordTaskVerification(
        application: AppInfo,
        osVersion: String,
        providerState: CapabilityProviderState,
        taskID: String,
        targetFingerprint: String,
        route: ControlActionRoute,
        selector: Selector?,
        kind: CapabilityEvidenceKind,
        reason: String
    ) throws -> CapabilityAuditProfile? {
        let lookup = lookup(
            application: application,
            osVersion: osVersion,
            providerState: providerState
        )
        guard var profile = lookup.profile, profile.state != .invalidated else {
            return nil
        }
        let capabilityID = "task.\(taskID).\(route.rawValue)"
        let locator = selector.flatMap { CapabilityLocatorDescriptor.from(selector: $0, route: route) }
        let timestamp = now()
        let evidence = CapabilityEvidenceRecord(
            capabilityID: capabilityID,
            provider: "mac_control",
            kind: kind,
            reason: reason,
            taskID: taskID,
            targetFingerprintDigest: CapabilityProfileDigest.make(targetFingerprint),
            locatorDigest: locator?.identityDigest,
            observedAt: timestamp
        )
        var capabilities = profile.capabilities
        let existingIndex = capabilities.firstIndex { $0.id == capabilityID }
        let existing = existingIndex.map { capabilities[$0] }
        let state: CapabilityEvidenceDisposition = switch kind {
        case .positive: .promoted
        case .negative: .demoted
        case .ambiguous: .candidate
        }
        let updated = CapabilityRecord(
            id: capabilityID,
            provider: "mac_control",
            state: state,
            positiveEvidenceCount: (existing?.positiveEvidenceCount ?? 0) + (kind == .positive ? 1 : 0),
            negativeEvidenceCount: (existing?.negativeEvidenceCount ?? 0) + (kind == .negative ? 1 : 0),
            ambiguousEvidenceCount: (existing?.ambiguousEvidenceCount ?? 0) + (kind == .ambiguous ? 1 : 0),
            locatorDigests: (existing?.locatorDigests ?? []) + (locator.map { [$0.identityDigest] } ?? []),
            lastReason: reason,
            lastVerifiedAt: timestamp
        )
        if let existingIndex {
            capabilities[existingIndex] = updated
        } else {
            capabilities.append(updated)
        }
        let capabilityLeads = profile.capabilityLeads?.map { lead in
            guard lead.taskIDs.contains(taskID),
                  providerMatches(route: route, leadProvider: lead.provider) else {
                return lead
            }
            return lead.recording(kind: kind, reason: reason, at: timestamp)
        }
        var reasons = profile.invalidationReasons
        let invalidationReason: CapabilityProfileInvalidationReason? = switch reason {
        case "stale_element": .staleElement
        case "verification_failed": .verificationFailed
        case "target_ambiguous": .targetAmbiguous
        case "target_resolution_incomplete": .targetResolutionIncomplete
        default: kind == .negative ? .actionFailed : nil
        }
        if let invalidationReason, !reasons.contains(invalidationReason) {
            reasons.append(invalidationReason)
        }
        let updatedState: CapabilityProfileState = invalidationReason == nil
            ? profile.state
            : .stale
        profile = CapabilityAuditProfile(
            identity: profile.identity,
            providerState: profile.providerState,
            archetype: profile.archetype,
            auditDepth: profile.auditDepth,
            state: updatedState,
            treeNodeCount: profile.treeNodeCount,
            treeTruncated: profile.treeTruncated,
            locators: profile.locators,
            capabilities: capabilities,
            advertisedCapabilities: profile.advertisedCapabilities,
            capabilityLeads: capabilityLeads,
            evidence: Array((profile.evidence + [evidence]).suffix(64)),
            invalidationReasons: reasons,
            createdAt: profile.createdAt,
            updatedAt: timestamp
        )
        try persist(profile)
        return profile
    }

    /// Records a fresh task-surface observation without allowing a read-only
    /// tree match to promote, demote, or invalidate an executable capability.
    /// The wrapper deliberately records ambiguous/candidate evidence only.
    @discardableResult
    public func recordTaskObservation(
        application: AppInfo,
        osVersion: String,
        providerState: CapabilityProviderState,
        taskID: String,
        targetFingerprint: String,
        route: ControlActionRoute,
        selector: Selector?,
        reason: String
    ) throws -> CapabilityAuditProfile? {
        let normalizedReason = reason.hasPrefix("read_only_")
            ? reason
            : "read_only_\(reason)"
        return try recordTaskVerification(
            application: application,
            osVersion: osVersion,
            providerState: providerState,
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            route: route,
            selector: selector,
            kind: .ambiguous,
            reason: normalizedReason
        )
    }

    private func invalidateSupersededProfiles(by profile: CapabilityAuditProfile) throws {
        for existing in list() where existing.identity != profile.identity {
            let sameApplication = (existing.identity.application.bundleID != nil
                && existing.identity.application.bundleID == profile.identity.application.bundleID)
                || existing.identity.application.path == profile.identity.application.path
            guard sameApplication else { continue }

            let reason: CapabilityProfileInvalidationReason?
            if existing.identity.application.path != profile.identity.application.path
                || existing.identity.application.bundleID != profile.identity.application.bundleID {
                reason = .applicationIdentityChanged
            } else if existing.identity.application.version != profile.identity.application.version {
                reason = .applicationVersionChanged
            } else if existing.identity.osVersion != profile.identity.osVersion {
                reason = .osChanged
            } else if existing.identity.providerStateSignature != profile.identity.providerStateSignature {
                reason = .providerStateChanged
            } else if existing.identity.treeSignature != profile.identity.treeSignature {
                reason = .treeChanged
            } else {
                reason = nil
            }
            guard let reason, existing.state != .invalidated else { continue }
            let invalidated = CapabilityAuditProfile(
                identity: existing.identity,
                providerState: existing.providerState,
                archetype: existing.archetype,
                auditDepth: existing.auditDepth,
                state: .invalidated,
                treeNodeCount: existing.treeNodeCount,
                treeTruncated: existing.treeTruncated,
                locators: existing.locators,
                capabilities: existing.capabilities,
                advertisedCapabilities: existing.advertisedCapabilities,
                capabilityLeads: existing.capabilityLeads,
                evidence: existing.evidence,
                invalidationReasons: existing.invalidationReasons + [reason],
                createdAt: existing.createdAt,
                updatedAt: now()
            )
            try persist(invalidated)
        }
    }

    /// Names can be localized or changed by an app update without changing
    /// the install identity. Cache identity is intentionally stricter than
    /// display identity but excludes the user-facing name.
    private func sameCacheApplicationIdentity(
        _ lhs: WarmPathApplicationIdentity,
        _ rhs: WarmPathApplicationIdentity
    ) -> Bool {
        lhs.path == rhs.path
            && lhs.bundleID == rhs.bundleID
            && lhs.version == rhs.version
    }

    private func providerMatches(
        route: ControlActionRoute,
        leadProvider: AppControlProvider
    ) -> Bool {
        switch route {
        case .accessibility:
            leadProvider == .accessibility
        case .keyboard:
            leadProvider == .keyboard
        case .scroll:
            leadProvider == .semanticScroll
        case .visual, .normalizedCoordinate, .rawCoordinate:
            false
        }
    }

    private func persist(_ profile: CapabilityAuditProfile) throws {
        let data = try JSONCodec.encode(profile)
        let url = directory.appendingPathComponent(Self.filename(for: profile))
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func filename(for profile: CapabilityAuditProfile) -> String {
        let identity = [
            profile.identity.application.bundleID ?? "",
            profile.identity.application.path,
            profile.identity.application.version ?? "",
            profile.identity.osVersion,
            profile.identity.providerStateSignature,
            profile.identity.treeSignature
        ].joined(separator: "|")
        return "\(CapabilityProfileDigest.make(identity)).json"
    }
}
