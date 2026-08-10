import Foundation

/// Provider preferences are declarative routing hints. They never authorize
/// execution and they do not replace task-specific measured route evidence.
public enum AppControlProvider: String, Codable, Equatable, CaseIterable {
    case accessibility
    case semanticScroll = "semantic_scroll"
    case keyboard
    case browserDOM = "browser_dom"
    case cdpDOM = "cdp_dom"
    case computerUse = "computer_use"
}

public struct AppControlProfile: Codable, Equatable {
    public let archetype: MacAppArchetype
    public let preferredProviders: [AppControlProvider]
    public let taskProviderPreferences: [String: [AppControlProvider]]
    public let anchors: [String]
    public let verification: [String]
    public let invalidatesOn: [String]
    public let unsupportedCapabilities: [String]
    public let layers: [String]

    public init(
        archetype: MacAppArchetype,
        preferredProviders: [AppControlProvider],
        taskProviderPreferences: [String: [AppControlProvider]] = [:],
        anchors: [String] = [],
        verification: [String] = [],
        invalidatesOn: [String] = [],
        unsupportedCapabilities: [String] = [],
        layers: [String] = []
    ) {
        self.archetype = archetype
        self.preferredProviders = preferredProviders
        self.taskProviderPreferences = taskProviderPreferences
        self.anchors = anchors
        self.verification = verification
        self.invalidatesOn = invalidatesOn
        self.unsupportedCapabilities = unsupportedCapabilities
        self.layers = layers
    }

    public func preferredProviders(for taskID: String?) -> [AppControlProvider] {
        guard let taskID else { return preferredProviders }
        return taskProviderPreferences[taskID] ?? preferredProviders
    }
}

public struct AppControlProfileOverlay: Codable, Equatable {
    public let id: String
    public let bundleIDs: [String]
    public let archetype: MacAppArchetype?
    public let preferredProviders: [AppControlProvider]?
    public let taskProviderPreferences: [String: [AppControlProvider]]
    public let anchors: [String]
    public let verification: [String]
    public let invalidatesOn: [String]
    public let unsupportedCapabilities: [String]

    public init(
        id: String,
        bundleIDs: [String],
        archetype: MacAppArchetype? = nil,
        preferredProviders: [AppControlProvider]? = nil,
        taskProviderPreferences: [String: [AppControlProvider]] = [:],
        anchors: [String] = [],
        verification: [String] = [],
        invalidatesOn: [String] = [],
        unsupportedCapabilities: [String] = []
    ) {
        self.id = id
        self.bundleIDs = bundleIDs.map { $0.lowercased() }
        self.archetype = archetype
        self.preferredProviders = preferredProviders
        self.taskProviderPreferences = taskProviderPreferences
        self.anchors = anchors
        self.verification = verification
        self.invalidatesOn = invalidatesOn
        self.unsupportedCapabilities = unsupportedCapabilities
    }

    fileprivate func matches(_ application: WarmPathApplicationIdentity) -> Bool {
        guard let bundleID = application.bundleID?.lowercased() else { return false }
        return bundleIDs.contains(bundleID)
    }
}

private struct AppArchetypeRule {
    let archetype: MacAppArchetype
    let bundleIDs: Set<String>
    let identityTerms: [String]

    func matches(_ application: WarmPathApplicationIdentity) -> Bool {
        let bundleID = application.bundleID?.lowercased() ?? ""
        if bundleIDs.contains(bundleID) { return true }
        let identity = "\(bundleID) \(application.name.lowercased())"
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return identityTerms.contains { identity.contains($0) }
    }
}

/// Resolves `archetype baseline -> app overlay`. The short-lived session
/// route cache remains owned by MacCtlService because it is lease-scoped.
public struct AppControlProfileRegistry {
    public static let standard = AppControlProfileRegistry()

    private let baselines: [MacAppArchetype: AppControlProfile]
    private let overlays: [AppControlProfileOverlay]
    private let archetypeRules: [AppArchetypeRule]

    public init(
        baselines: [MacAppArchetype: AppControlProfile]? = nil,
        overlays: [AppControlProfileOverlay]? = nil
    ) {
        self.baselines = baselines ?? Self.standardBaselines
        self.overlays = overlays ?? Self.standardOverlays
        self.archetypeRules = Self.standardArchetypeRules
    }

    public func archetype(for application: WarmPathApplicationIdentity) -> MacAppArchetype {
        if let overlay = overlays.first(where: { $0.matches(application) }),
           let archetype = overlay.archetype {
            return archetype
        }
        return archetypeRules.first(where: { $0.matches(application) })?.archetype ?? .unknown
    }

    public func profile(for application: WarmPathApplicationIdentity) -> AppControlProfile {
        let archetype = archetype(for: application)
        let baseline = baselines[archetype] ?? Self.standardBaselines[.unknown]!
        guard let overlay = overlays.first(where: { $0.matches(application) }) else {
            return baseline
        }
        return AppControlProfile(
            archetype: overlay.archetype ?? baseline.archetype,
            preferredProviders: overlay.preferredProviders ?? baseline.preferredProviders,
            taskProviderPreferences: baseline.taskProviderPreferences.merging(
                overlay.taskProviderPreferences,
                uniquingKeysWith: { _, overlayValue in overlayValue }
            ),
            anchors: Self.orderedUnion(baseline.anchors, overlay.anchors),
            verification: Self.orderedUnion(baseline.verification, overlay.verification),
            invalidatesOn: Self.orderedUnion(baseline.invalidatesOn, overlay.invalidatesOn),
            unsupportedCapabilities: Self.orderedUnion(
                baseline.unsupportedCapabilities,
                overlay.unsupportedCapabilities
            ),
            layers: Self.orderedUnion(baseline.layers, ["app:\(overlay.id)"])
        )
    }

    private static func orderedUnion<T: Hashable>(_ lhs: [T], _ rhs: [T]) -> [T] {
        var seen = Set<T>()
        return (lhs + rhs).filter { seen.insert($0).inserted }
    }

    private static let commonInvalidations = [
        "app_version_change",
        "os_version_change",
        "provider_state_change",
        "tree_signature_change",
        "stale_element",
        "failed_action",
        "verification_failure"
    ]

    private static let standardBaselines: [MacAppArchetype: AppControlProfile] = [
        .nativeAppKit: AppControlProfile(
            archetype: .nativeAppKit,
            preferredProviders: [.accessibility, .semanticScroll, .computerUse],
            anchors: ["AXWindow", "AXGroup", "AXTable"],
            verification: ["focused_window", "semantic_state_change"],
            invalidatesOn: commonInvalidations,
            layers: ["archetype:native_appkit"]
        ),
        .swiftUI: AppControlProfile(
            archetype: .swiftUI,
            preferredProviders: [.accessibility, .semanticScroll, .computerUse],
            anchors: ["AXWindow", "AXGroup", "AXIdentifier"],
            verification: ["role_check", "semantic_identifier", "semantic_state_change"],
            invalidatesOn: commonInvalidations,
            layers: ["archetype:swiftui"]
        ),
        .electronChromium: AppControlProfile(
            archetype: .electronChromium,
            preferredProviders: [.cdpDOM, .browserDOM, .accessibility, .computerUse],
            anchors: ["dom_root", "AXWindow", "AXWebArea"],
            verification: ["dom_state_change", "focused_window"],
            invalidatesOn: commonInvalidations,
            layers: ["archetype:electron_chromium"]
        ),
        .browser: AppControlProfile(
            archetype: .browser,
            preferredProviders: [.browserDOM, .accessibility, .computerUse],
            anchors: ["dom_root", "AXWindow", "AXWebArea"],
            verification: ["dom_state_change", "focused_window"],
            invalidatesOn: commonInvalidations,
            layers: ["archetype:browser"]
        ),
        .systemSettings: AppControlProfile(
            archetype: .systemSettings,
            preferredProviders: [.accessibility, .semanticScroll, .computerUse],
            anchors: ["AXWindow", "AXSplitGroup", "AXScrollArea"],
            verification: ["selected_pane", "anchor_present", "focused_window"],
            invalidatesOn: commonInvalidations,
            layers: ["archetype:system_settings"]
        ),
        .unknown: AppControlProfile(
            archetype: .unknown,
            preferredProviders: [.accessibility, .computerUse],
            anchors: ["AXWindow"],
            verification: ["focused_window"],
            invalidatesOn: commonInvalidations,
            layers: ["archetype:unknown"]
        )
    ]

    private static let standardOverlays: [AppControlProfileOverlay] = [
        AppControlProfileOverlay(
            id: "google_chrome",
            bundleIDs: ["com.google.Chrome", "com.google.Chrome.canary"],
            archetype: .browser,
            taskProviderPreferences: ["scroll": [.browserDOM, .accessibility, .computerUse]],
            unsupportedCapabilities: ["chrome_tab_group_mutation"]
        ),
        AppControlProfileOverlay(
            id: "apple_mail",
            bundleIDs: ["com.apple.mail"],
            archetype: .nativeAppKit,
            anchors: ["AXTable"],
            verification: ["row_count_change"]
        ),
        AppControlProfileOverlay(
            id: "system_settings",
            bundleIDs: ["com.apple.systemsettings", "com.apple.systempreferences"],
            archetype: .systemSettings
        ),
    ]

    private static let standardArchetypeRules: [AppArchetypeRule] = [
        // The removed iPhone Mirroring surface must not inherit the broad
        // com.apple native-AppKit heuristic below.
        AppArchetypeRule(
            archetype: .unknown,
            bundleIDs: ["com.apple.screencontinuity"],
            identityTerms: []
        ),
        AppArchetypeRule(
            archetype: .systemSettings,
            bundleIDs: ["com.apple.systemsettings", "com.apple.systempreferences"],
            identityTerms: ["systemsettings", "systempreferences"]
        ),
        AppArchetypeRule(
            archetype: .swiftUI,
            bundleIDs: [],
            identityTerms: ["swiftui"]
        ),
        AppArchetypeRule(
            archetype: .browser,
            bundleIDs: ["com.apple.safari", "com.google.chrome", "org.mozilla.firefox"],
            identityTerms: ["chrome", "firefox", "safari", "microsoftedge", "brave"]
        ),
        AppArchetypeRule(
            archetype: .electronChromium,
            bundleIDs: [],
            identityTerms: ["electron", "visualstudio", "slack", "discord", "notion", "figma"]
        ),
        AppArchetypeRule(
            archetype: .nativeAppKit,
            bundleIDs: [],
            identityTerms: ["comapple"]
        )
    ]
}
