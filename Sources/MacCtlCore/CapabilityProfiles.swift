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
    public let identityDigest: String

    public init(
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        labelDigest: String? = nil,
        actions: [String] = [],
        scrollable: Bool = false,
        identityDigest: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.labelDigest = labelDigest
        self.actions = actions.sorted()
        self.scrollable = scrollable
        self.identityDigest = identityDigest ?? CapabilityProfileDigest.make([
            role ?? "",
            subrole ?? "",
            identifier ?? "",
            labelDigest ?? "",
            self.actions.joined(separator: ","),
            scrollable ? "1" : "0"
        ].joined(separator: "|"))
    }

    public static func from(treeNode: AccessibilityTreeNode) -> CapabilityLocatorDescriptor? {
        guard treeNode.role != nil || treeNode.identifier != nil || treeNode.label != nil else {
            return nil
        }
        return CapabilityLocatorDescriptor(
            role: treeNode.role,
            subrole: treeNode.subrole,
            identifier: treeNode.identifier,
            labelDigest: treeNode.label.map(CapabilityProfileDigest.make),
            actions: treeNode.actions,
            scrollable: treeNode.scrollable
        )
    }

    public static func from(selector: Selector, route: ControlActionRoute) -> CapabilityLocatorDescriptor? {
        guard selector.role != nil || selector.identifier != nil || selector.title != nil else {
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
            scrollable: route == .scroll
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
                String(node.childCount)
            ].joined(separator: "|")
        }.joined(separator: "||")
        let coverage = tree.coverage?.signature ?? "recursive"
        return CapabilityProfileDigest.make(
            "nodes=\(tree.nodeCount)|truncated=\(tree.truncated ? 1 : 0)|coverage=\(coverage)|\(nodes)"
        )
    }

    public static func build(
        application: AppInfo,
        osVersion: String,
        providerState: CapabilityProviderState,
        tree: AccessibilityTreeReport,
        now: Date = Date()
    ) -> CapabilityAuditProfile {
        let locators = deduplicateLocators(tree.nodes.compactMap(CapabilityLocatorDescriptor.from))
        let hasPress = tree.nodes.contains { $0.actions.contains("AXPress") }
        let hasScroll = tree.nodes.contains(where: \.scrollable)
        let hasSettableValue = tree.nodes.contains { $0.state.settable }
        let complete = !tree.truncated
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
                id: "semantic_scroll",
                provider: "accessibility",
                positive: hasScroll,
                ambiguous: !hasScroll && tree.truncated,
                reason: hasScroll ? "scrollable_AX_element_observed" : (tree.truncated ? "scrollable_element_not_observed_in_truncated_tree" : "scrollable_element_not_present_in_complete_tree"),
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
            evidence: [],
            invalidationReasons: invalidationReasons,
            createdAt: now,
            updatedAt: now
        )
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
        return locators.filter { seen.insert($0.identityDigest).inserted }
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
        let reasons = all.flatMap { profile -> [CapabilityProfileInvalidationReason] in
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
        }
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
        var reasons = profile.invalidationReasons
        let invalidationReason: CapabilityProfileInvalidationReason? = switch reason {
        case "stale_element": .staleElement
        case "verification_failed": .verificationFailed
        case "target_ambiguous": .targetAmbiguous
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
            evidence: Array((profile.evidence + [evidence]).suffix(64)),
            invalidationReasons: reasons,
            createdAt: profile.createdAt,
            updatedAt: timestamp
        )
        try persist(profile)
        return profile
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
