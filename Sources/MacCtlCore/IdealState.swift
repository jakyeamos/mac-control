import Foundation

public struct MacControlIdealStateApplication: Codable, Equatable {
    public let name: String
    public let bundleID: String?
    public let version: String?

    public init(name: String, bundleID: String? = nil, version: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case version
    }
}

public struct MacControlIdealStateRouteCandidate: Codable, Equatable {
    public let id: String
    public let provider: String
    public let method: String
    public let interactionMode: String

    public init(id: String, provider: String, method: String, interactionMode: String) {
        self.id = id
        self.provider = provider
        self.method = method
        self.interactionMode = interactionMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case method
        case interactionMode = "interaction_mode"
    }
}

public struct MacControlIdealStateSourceReference: Codable, Equatable {
    public let path: String
    public let anchor: String
    public let evidenceTokens: [String]

    public init(path: String, anchor: String, evidenceTokens: [String]) {
        self.path = path
        self.anchor = anchor
        self.evidenceTokens = evidenceTokens
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case anchor
        case evidenceTokens = "evidence_tokens"
    }
}

public struct MacControlIdealStateSemanticEvidence: Codable, Equatable {
    public let level: String
    public let claims: [String: String]
    public let sourceReferences: [MacControlIdealStateSourceReference]

    public init(
        level: String,
        claims: [String: String],
        sourceReferences: [MacControlIdealStateSourceReference]
    ) {
        self.level = level
        self.claims = claims
        self.sourceReferences = sourceReferences
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case claims
        case sourceReferences = "source_refs"
    }
}

public struct MacControlIdealStateVerificationOracle: Codable, Equatable {
    public let oracleID: String
    public let kind: String
    public let expectedState: String
    public let independentReadback: Bool

    public init(oracleID: String, kind: String, expectedState: String, independentReadback: Bool) {
        self.oracleID = oracleID
        self.kind = kind
        self.expectedState = expectedState
        self.independentReadback = independentReadback
    }

    private enum CodingKeys: String, CodingKey {
        case oracleID = "oracle_id"
        case kind
        case expectedState = "expected_state"
        case independentReadback = "independent_readback"
    }
}

public struct MacControlIdealStateShortcutAcceleration: Codable, Equatable {
    public let disposition: String
    public let commandID: String?
    public let chord: String?
    public let menuPath: [String]
    public let customizationSurface: String?
    public let conflictPolicy: String?
    public let contextualAvailability: Bool?
    public let reversibleAssignment: Bool?
    public let reason: String?

    public init(
        disposition: String,
        commandID: String? = nil,
        chord: String? = nil,
        menuPath: [String] = [],
        customizationSurface: String? = nil,
        conflictPolicy: String? = nil,
        contextualAvailability: Bool? = nil,
        reversibleAssignment: Bool? = nil,
        reason: String? = nil
    ) {
        self.disposition = disposition
        self.commandID = commandID
        self.chord = chord
        self.menuPath = menuPath
        self.customizationSurface = customizationSurface
        self.conflictPolicy = conflictPolicy
        self.contextualAvailability = contextualAvailability
        self.reversibleAssignment = reversibleAssignment
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case disposition
        case commandID = "command_id"
        case chord
        case menuPath = "menu_path"
        case customizationSurface = "customization_surface"
        case conflictPolicy = "conflict_policy"
        case contextualAvailability = "contextual_availability"
        case reversibleAssignment = "reversible_assignment"
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disposition = try container.decode(String.self, forKey: .disposition)
        commandID = try container.decodeIfPresent(String.self, forKey: .commandID)
        chord = try container.decodeIfPresent(String.self, forKey: .chord)
        menuPath = try container.decodeIfPresent([String].self, forKey: .menuPath) ?? []
        customizationSurface = try container.decodeIfPresent(String.self, forKey: .customizationSurface)
        conflictPolicy = try container.decodeIfPresent(String.self, forKey: .conflictPolicy)
        contextualAvailability = try container.decodeIfPresent(Bool.self, forKey: .contextualAvailability)
        reversibleAssignment = try container.decodeIfPresent(Bool.self, forKey: .reversibleAssignment)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

public struct MacControlIdealStateTask: Codable, Equatable {
    public let taskID: String
    public let surfaceKind: String?
    public let stableTargetID: String
    public let hierarchy: String
    public let semanticAction: String
    public let observablePostcondition: String
    public let observableStates: [String]
    public let navigationStrategy: String
    public let eligibleRoutes: [String]
    public let selectedRoute: String?
    public let changeStates: [String]
    public let accessibility: AccessibilityAuditControl?
    public let stateExemptions: [String: String]
    public let changeStateExemptions: [String: String]
    public let focusPolicy: String?
    public let foregroundPostcondition: String?
    public let fallbackPolicy: String?
    public let verificationOracle: MacControlIdealStateVerificationOracle?
    public let routeCandidates: [MacControlIdealStateRouteCandidate]
    public let shortcutAcceleration: MacControlIdealStateShortcutAcceleration?
    public let semanticEvidence: [String: MacControlIdealStateSemanticEvidence]

    public init(
        taskID: String,
        surfaceKind: String? = nil,
        stableTargetID: String,
        hierarchy: String,
        semanticAction: String,
        observablePostcondition: String,
        observableStates: [String],
        navigationStrategy: String,
        eligibleRoutes: [String] = [],
        selectedRoute: String? = nil,
        changeStates: [String],
        accessibility: AccessibilityAuditControl? = nil,
        stateExemptions: [String: String] = [:],
        changeStateExemptions: [String: String] = [:],
        focusPolicy: String? = nil,
        foregroundPostcondition: String? = nil,
        fallbackPolicy: String? = nil,
        verificationOracle: MacControlIdealStateVerificationOracle? = nil,
        routeCandidates: [MacControlIdealStateRouteCandidate] = [],
        shortcutAcceleration: MacControlIdealStateShortcutAcceleration? = nil,
        semanticEvidence: [String: MacControlIdealStateSemanticEvidence] = [:]
    ) {
        self.taskID = taskID
        self.surfaceKind = surfaceKind
        self.stableTargetID = stableTargetID
        self.hierarchy = hierarchy
        self.semanticAction = semanticAction
        self.observablePostcondition = observablePostcondition
        self.observableStates = observableStates
        self.navigationStrategy = navigationStrategy
        self.eligibleRoutes = eligibleRoutes
        self.selectedRoute = selectedRoute
        self.changeStates = changeStates
        self.accessibility = accessibility
        self.stateExemptions = stateExemptions
        self.changeStateExemptions = changeStateExemptions
        self.focusPolicy = focusPolicy
        self.foregroundPostcondition = foregroundPostcondition
        self.fallbackPolicy = fallbackPolicy
        self.verificationOracle = verificationOracle
        self.routeCandidates = routeCandidates
        self.shortcutAcceleration = shortcutAcceleration
        self.semanticEvidence = semanticEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case surfaceKind = "surface_kind"
        case stableTargetID = "stable_target_id"
        case hierarchy
        case semanticAction = "semantic_action"
        case observablePostcondition = "observable_postcondition"
        case observableStates = "observable_states"
        case navigationStrategy = "navigation_strategy"
        case eligibleRoutes = "eligible_routes"
        case selectedRoute = "selected_route"
        case changeStates = "change_states"
        case accessibility
        case stateExemptions = "state_exemptions"
        case changeStateExemptions = "change_state_exemptions"
        case focusPolicy = "focus_policy"
        case foregroundPostcondition = "foreground_postcondition"
        case fallbackPolicy = "fallback_policy"
        case verificationOracle = "verification_oracle"
        case routeCandidates = "route_candidates"
        case shortcutAcceleration = "shortcut_acceleration"
        case semanticEvidence = "semantic_evidence"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(String.self, forKey: .taskID)
        surfaceKind = try container.decodeIfPresent(String.self, forKey: .surfaceKind)
        stableTargetID = try container.decode(String.self, forKey: .stableTargetID)
        hierarchy = try container.decode(String.self, forKey: .hierarchy)
        semanticAction = try container.decode(String.self, forKey: .semanticAction)
        observablePostcondition = try container.decode(String.self, forKey: .observablePostcondition)
        observableStates = try container.decodeIfPresent([String].self, forKey: .observableStates) ?? []
        navigationStrategy = try container.decode(String.self, forKey: .navigationStrategy)
        eligibleRoutes = try container.decodeIfPresent([String].self, forKey: .eligibleRoutes) ?? []
        selectedRoute = try container.decodeIfPresent(String.self, forKey: .selectedRoute)
        changeStates = try container.decodeIfPresent([String].self, forKey: .changeStates) ?? []
        accessibility = try container.decodeIfPresent(AccessibilityAuditControl.self, forKey: .accessibility)
        stateExemptions = try container.decodeIfPresent([String: String].self, forKey: .stateExemptions) ?? [:]
        changeStateExemptions = try container.decodeIfPresent([String: String].self, forKey: .changeStateExemptions) ?? [:]
        focusPolicy = try container.decodeIfPresent(String.self, forKey: .focusPolicy)
        foregroundPostcondition = try container.decodeIfPresent(String.self, forKey: .foregroundPostcondition)
        fallbackPolicy = try container.decodeIfPresent(String.self, forKey: .fallbackPolicy)
        verificationOracle = try container.decodeIfPresent(
            MacControlIdealStateVerificationOracle.self,
            forKey: .verificationOracle
        )
        routeCandidates = try container.decodeIfPresent(
            [MacControlIdealStateRouteCandidate].self,
            forKey: .routeCandidates
        ) ?? []
        shortcutAcceleration = try container.decodeIfPresent(
            MacControlIdealStateShortcutAcceleration.self,
            forKey: .shortcutAcceleration
        )
        semanticEvidence = try container.decodeIfPresent(
            [String: MacControlIdealStateSemanticEvidence].self,
            forKey: .semanticEvidence
        ) ?? [:]
    }
}

public struct MacControlIdealStateManifest: Codable, Equatable {
    public let schema: String
    public let repositoryID: String
    public let repositoryName: String
    public let applicability: String
    public let applicabilityReason: String
    public let app: MacControlIdealStateApplication?
    public let criteria: [String: Bool]
    public let tasks: [MacControlIdealStateTask]

    public init(
        schema: String,
        repositoryID: String,
        repositoryName: String,
        applicability: String,
        applicabilityReason: String,
        app: MacControlIdealStateApplication? = nil,
        criteria: [String: Bool] = [:],
        tasks: [MacControlIdealStateTask] = []
    ) {
        self.schema = schema
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.applicability = applicability
        self.applicabilityReason = applicabilityReason
        self.app = app
        self.criteria = criteria
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case repositoryID = "repository_id"
        case repositoryName = "repository_name"
        case applicability
        case applicabilityReason = "applicability_reason"
        case app
        case criteria
        case tasks
    }
}

public struct MacControlIdealStateManifestValidation: Codable, Equatable {
    public let schema: String
    public let producer: String
    public let valid: Bool
    public let repositoryID: String
    public let taskIDs: [String]
    public let errors: [String]
    public let warnings: [String]

    public init(
        valid: Bool,
        repositoryID: String,
        taskIDs: [String],
        errors: [String],
        warnings: [String] = []
    ) {
        self.schema = "mac-control-ideal-state-manifest-validation/v1"
        self.producer = "mac-control"
        self.valid = valid
        self.repositoryID = repositoryID
        self.taskIDs = taskIDs
        self.errors = errors
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case producer
        case valid
        case repositoryID = "repository_id"
        case taskIDs = "task_ids"
        case errors
        case warnings
    }
}

public struct MacControlIdealStateLiveAudit: Codable, Equatable {
    public let schema: String
    public let producer: String
    public let observedAt: String
    public let application: AppInfo
    public let manifestValid: Bool
    public let structuralValid: Bool
    public let redacted: Bool
    public let findings: [AccessibilityAuditFinding]

    public init(
        application: AppInfo,
        manifestValid: Bool,
        structuralValid: Bool,
        findings: [AccessibilityAuditFinding],
        observedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.schema = "mac-control-ideal-state-live-audit/v1"
        self.producer = "mac-control"
        self.observedAt = observedAt
        self.application = application
        self.manifestValid = manifestValid
        self.structuralValid = structuralValid
        self.redacted = true
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case producer
        case observedAt = "observed_at"
        case application
        case manifestValid = "manifest_valid"
        case structuralValid = "structural_valid"
        case redacted
        case findings
    }
}

public enum MacControlIdealStateManifestValidator {
    public static let schema = "mac-control-task-manifest/v4"
    public static let previousSchema = "mac-control-task-manifest/v3"
    public static let v2Schema = "mac-control-task-manifest/v2"
    public static let legacySchema = "mac-control-task-manifest/v1"
    public static let criteria = [
        "stable_identity",
        "correct_semantics",
        "observable_state",
        "useful_hierarchy",
        "efficient_navigation",
        "verifiable_outcomes",
        "route_flexibility",
        "stable_change_behavior"
    ]
    public static let observableStates = [
        "enabled", "focused", "selected", "expanded", "visible", "loading", "completed"
    ]
    public static let changeStates = ["loading", "modal", "disabled", "permission_unavailable"]
    public static let routes = [
        "native_api", "adapter", "accessibility", "keyboard", "scrolling", "visual_fallback_approved"
    ]
    public static let providers = [
        "native", "mac_control", "app_connector", "browser_connector", "computer_use", "caller"
    ]
    public static let methods = [
        "native_api", "adapter", "accessibility", "keyboard", "shortcut", "scroll", "pointer", "visual", "drag"
    ]
    public static let interactionModes = ["semantic", "keyboard", "pointer", "scroll", "drag", "mixed"]
    public static let oracleKinds = [
        "element_state", "window_state", "application_state", "task_state", "receipt_state", "provider_readback"
    ]
    public static let shortcutDispositions = [
        "built_in_verified", "customizable_verified", "not_applicable"
    ]
    public static let shortcutCustomizationSurfaces = [
        "macos_app_shortcut", "app_managed", "chrome_extension"
    ]
    public static let shortcutConflictPolicies = [
        "app_managed", "detect_before_assignment", "system_resolved"
    ]
    public static let surfaceKinds = [
        "native_app_ui", "browser_chrome", "web_content", "os_dialog", "hybrid_transition"
    ]
    public static let semanticClaimKeys: [String: [String]] = [
        "stable_identity": ["selector_kind", "selector_value", "scope", "uniqueness"],
        "correct_semantics": ["role", "accessible_name", "action"],
        "observable_state": ["property", "unavailable_behavior"],
        "useful_hierarchy": ["container", "relationship", "uniqueness"],
        "efficient_navigation": ["strategy", "entry_point"],
        "verifiable_outcomes": ["readback_provider", "property", "operator", "expected"],
        "route_flexibility": ["primary_provider", "secondary_provider", "fallback_policy"],
        "stable_change_behavior": ["scenarios", "failure_behavior"]
    ]
    public static let failureBehaviors = [
        "fail_closed", "block_and_explain", "provider_handoff", "retryable_no_change"
    ]
    public static let implementationSourceExtensions = [
        "c", "cpp", "cs", "dart", "go", "h", "html", "java", "js", "json", "jsx", "kt", "kts",
        "m", "mm", "plist", "py", "rb", "rs", "storyboard", "svelte", "swift", "toml", "ts", "tsx",
        "vue", "xib", "yaml", "yml"
    ]
    public static let nonImplementationSourceComponents = [
        ".mac-control", "docs", "fixtures", "snapshots", "test", "tests"
    ]

    public static func validate(
        _ manifest: MacControlIdealStateManifest
    ) -> MacControlIdealStateManifestValidation {
        var errors: [String] = []
        let applicability = token(manifest.applicability)
        if manifest.schema != schema,
           manifest.schema != previousSchema,
           manifest.schema != v2Schema,
           manifest.schema != legacySchema {
            errors.append("schema must be \(schema), \(previousSchema), \(v2Schema), or \(legacySchema)")
        }
        if manifest.repositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("repository_id is required")
        }
        if manifest.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("repository_name is required")
        }
        if manifest.applicabilityReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("applicability_reason is required")
        }
        guard applicability == "applicable" || applicability == "not_applicable" else {
            errors.append("applicability must be applicable or not_applicable")
            return result(manifest, errors: errors)
        }
        if applicability == "not_applicable" {
            if !manifest.tasks.isEmpty {
                errors.append("not_applicable manifests must not declare tasks")
            }
            return result(manifest, errors: errors)
        }
        if manifest.app?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            errors.append("app.name is required for applicable manifests")
        }
        if manifest.schema == schema {
            if !manifest.criteria.isEmpty {
                errors.append("v4 criteria must be empty; semantic dimensions are derived from task evidence")
            }
        } else {
            for criterion in criteria {
                if manifest.criteria[criterion] != true {
                    errors.append("criteria.\(criterion) must be true")
                }
            }
            for criterion in manifest.criteria.keys where !criteria.contains(criterion) {
                errors.append("criteria contains unsupported key \(criterion)")
            }
        }
        if manifest.tasks.isEmpty {
            errors.append("applicable manifests must declare at least one task")
        }
        var taskIDs = Set<String>()
        for (index, task) in manifest.tasks.enumerated() {
            let label = task.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "tasks[\(index)]"
                : task.taskID
            if task.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("\(label) requires task_id")
            } else if !taskIDs.insert(task.taskID).inserted {
                errors.append("task \(task.taskID) is duplicated")
            }
            for (value, key) in [
                (task.stableTargetID, "stable_target_id"),
                (task.hierarchy, "hierarchy"),
                (task.semanticAction, "semantic_action"),
                (task.observablePostcondition, "observable_postcondition"),
                (task.navigationStrategy, "navigation_strategy")
            ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("task \(label) requires \(key)")
            }
            if let accessibility = task.accessibility,
               accessibility.identifier == nil,
               accessibility.label == nil,
               accessibility.role == nil,
               accessibility.subrole == nil {
                errors.append("task \(label) accessibility needs identifier, label, role, or subrole")
            }
            if manifest.schema == schema || manifest.schema == previousSchema || manifest.schema == v2Schema {
                validateV2(task, label: label, errors: &errors)
                if manifest.schema == schema || manifest.schema == previousSchema {
                    validateShortcutAcceleration(task, label: label, errors: &errors)
                }
                if manifest.schema == schema {
                    validateV4(task, label: label, errors: &errors)
                }
                continue
            }
            if task.selectedRoute?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                errors.append("task \(label) requires selected_route")
            }
            if token(task.navigationStrategy) == "sequential_tabbing" {
                errors.append("task \(label) must not rely on sequential tabbing")
            }
            require(task.observableStates, values: observableStates, label: "task \(label) observable_states", errors: &errors)
            require(task.changeStates, values: changeStates, label: "task \(label) change_states", errors: &errors)
            let eligible = Set(task.eligibleRoutes.map(token))
            if eligible.isEmpty {
                errors.append("task \(label) requires eligible_routes")
            }
            for route in eligible where !routes.contains(route) {
                errors.append("task \(label) has unsupported route \(route)")
            }
            if !eligible.contains(token(task.selectedRoute ?? "")) {
                errors.append("task \(label) selected_route must be eligible")
            }
            if token(task.navigationStrategy) == "search_shortcut" {
                if token(task.semanticAction) != "search" {
                    errors.append("task \(label) search_shortcut requires semantic_action search")
                }
                if !eligible.contains("keyboard") {
                    errors.append("task \(label) search_shortcut requires keyboard in eligible_routes")
                }
                if token(task.selectedRoute ?? "") != "keyboard" {
                    errors.append("task \(label) search_shortcut requires selected_route keyboard")
                }
                if token(task.observablePostcondition) != "search_field_focused" {
                    errors.append("task \(label) search_shortcut requires observable_postcondition search_field_focused")
                }
                guard let accessibility = task.accessibility else {
                    errors.append("task \(label) search_shortcut requires Accessibility metadata")
                    continue
                }
                if token(accessibility.role ?? "") != "axtextfield" {
                    errors.append("task \(label) search_shortcut requires Accessibility role AXTextField")
                }
                if token(accessibility.subrole ?? "") != "axsearchfield" {
                    errors.append("task \(label) search_shortcut requires Accessibility subrole AXSearchField")
                }
            }
        }
        return result(manifest, errors: errors)
    }

    private static func validateV4(
        _ task: MacControlIdealStateTask,
        label: String,
        errors: inout [String]
    ) {
        let surfaceKind = token(task.surfaceKind ?? "")
        if !surfaceKinds.contains(surfaceKind) {
            errors.append("task \(label) surface_kind must name a supported surface")
        }
        let providerSet = Set(task.routeCandidates.map { token($0.provider) })
        let nativeProviders: Set<String> = ["native", "mac_control", "app_connector"]
        let browserProviders: Set<String> = ["browser_connector"]
        if task.routeCandidates.count < 2 {
            errors.append("task \(label) route_flexibility requires at least two route candidates")
        }
        if surfaceKind == "web_content" {
            if providerSet.isDisjoint(with: browserProviders) {
                errors.append("task \(label) web_content requires a browser_connector route")
            }
            if !providerSet.isDisjoint(with: nativeProviders) {
                errors.append("task \(label) web_content must not claim a native Mac Control route")
            }
        } else if ["native_app_ui", "browser_chrome", "os_dialog"].contains(surfaceKind) {
            if providerSet.isDisjoint(with: nativeProviders) {
                errors.append("task \(label) \(surfaceKind) requires a native semantic route")
            }
            if !providerSet.isDisjoint(with: browserProviders) {
                errors.append("task \(label) \(surfaceKind) must not claim a browser_connector route")
            }
        } else if surfaceKind == "hybrid_transition",
                  providerSet.isDisjoint(with: nativeProviders)
                    || providerSet.isDisjoint(with: browserProviders) {
            errors.append("task \(label) hybrid_transition requires native and browser routes")
        }
        for candidate in task.routeCandidates {
            let method = token(candidate.method)
            if method == "accessibility",
               task.accessibility?.identifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                errors.append("task \(label) accessibility route requires accessibility.identifier")
            }
            if ["pointer", "visual", "drag"].contains(method),
               !["explicit_handoff", "fresh_state_handoff"].contains(token(task.fallbackPolicy ?? "")) {
                errors.append("task \(label) \(method) route requires explicit_handoff or fresh_state_handoff")
            }
        }
        if let oracle = task.verificationOracle,
           ["visible", "readable", "available", "success", "succeeded", "completed"]
            .contains(token(oracle.expectedState)) {
            errors.append("task \(label) verification_oracle expected_state must name a machine-checkable value")
        }

        for criterion in task.semanticEvidence.keys where !criteria.contains(criterion) {
            errors.append("task \(label) semantic_evidence contains unsupported key \(criterion)")
        }
        var seenEvidence: [MacControlIdealStateSemanticEvidence] = []
        for criterion in criteria {
            let evidenceLabel = "task \(label) semantic_evidence.\(criterion)"
            guard let evidence = task.semanticEvidence[criterion] else {
                errors.append("\(evidenceLabel) is required")
                continue
            }
            if token(evidence.level) != "source_grounded" {
                errors.append("\(evidenceLabel).level must be source_grounded")
            }
            for key in semanticClaimKeys[criterion] ?? []
            where evidence.claims[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                errors.append("\(evidenceLabel).claims.\(key) is required")
            }
            validateSemanticClaims(
                criterion,
                evidence: evidence,
                task: task,
                providers: providerSet,
                label: evidenceLabel,
                errors: &errors
            )
            if evidence.sourceReferences.isEmpty {
                errors.append("\(evidenceLabel).source_refs requires at least one source reference")
            }
            for (index, reference) in evidence.sourceReferences.enumerated() {
                let referenceLabel = "\(evidenceLabel).source_refs[\(index)]"
                let components = reference.path.split(separator: "/", omittingEmptySubsequences: false)
                if reference.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || reference.path.hasPrefix("/")
                    || components.contains("..") {
                    errors.append("\(referenceLabel).path must be repository-relative without traversal")
                }
                let normalizedComponents = Set(components.map { $0.lowercased() })
                if !normalizedComponents.isDisjoint(with: nonImplementationSourceComponents) {
                    errors.append(
                        "\(referenceLabel).path must reference implementation source, not docs, tests, or fixtures"
                    )
                }
                let sourceExtension = URL(fileURLWithPath: reference.path).pathExtension.lowercased()
                if !implementationSourceExtensions.contains(sourceExtension) {
                    errors.append(
                        "\(referenceLabel).path must use a supported implementation-source extension"
                    )
                }
                if reference.anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("\(referenceLabel).anchor is required")
                }
                if reference.evidenceTokens.isEmpty
                    || reference.evidenceTokens.contains(where: {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }) {
                    errors.append("\(referenceLabel).evidence_tokens requires non-empty source tokens")
                }
            }
            if seenEvidence.contains(evidence) {
                errors.append("task \(label) semantic evidence must be criterion-specific, not cloned")
            }
            seenEvidence.append(evidence)
        }
    }

    private static func validateSemanticClaims(
        _ criterion: String,
        evidence: MacControlIdealStateSemanticEvidence,
        task: MacControlIdealStateTask,
        providers: Set<String>,
        label: String,
        errors: inout [String]
    ) {
        let claims = evidence.claims
        switch criterion {
        case "stable_identity":
            let selectorKind = token(claims["selector_kind"] ?? "")
            if !["ax_identifier", "data_attribute", "dom_test_id", "command_id"]
                .contains(selectorKind) {
                errors.append("\(label).claims.selector_kind is unsupported")
            }
            let surfaceKind = token(task.surfaceKind ?? "")
            if surfaceKind == "web_content",
               !["data_attribute", "dom_test_id"].contains(selectorKind) {
                errors.append("\(label).claims.selector_kind must be DOM-native for web_content")
            }
            if ["native_app_ui", "browser_chrome", "os_dialog"].contains(surfaceKind),
               !["ax_identifier", "command_id"].contains(selectorKind) {
                errors.append("\(label).claims.selector_kind must be native for \(surfaceKind)")
            }
            if claims["selector_value"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                != task.stableTargetID.trimmingCharacters(in: .whitespacesAndNewlines) {
                errors.append("\(label).claims.selector_value must equal stable_target_id")
            }
            if token(claims["uniqueness"] ?? "") != "exactly_one" {
                errors.append("\(label).claims.uniqueness must be exactly_one")
            }
        case "useful_hierarchy":
            if token(claims["uniqueness"] ?? "") != "exactly_one" {
                errors.append("\(label).claims.uniqueness must be exactly_one")
            }
        case "efficient_navigation":
            let strategy = token(claims["strategy"] ?? "")
            if !["direct_semantic", "menu_command", "search", "shortcut", "typed_provider_handoff"]
                .contains(strategy) {
                errors.append("\(label).claims.strategy is unsupported")
            }
            if strategy != token(task.navigationStrategy) {
                errors.append("\(label).claims.strategy must match task navigation_strategy")
            }
            if strategy == "direct_semantic",
               claims["entry_point"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                != task.stableTargetID.trimmingCharacters(in: .whitespacesAndNewlines) {
                errors.append("\(label).claims.entry_point must equal stable_target_id")
            }
        case "verifiable_outcomes":
            if !["equals", "not_equals", "contains", "exists"]
                .contains(token(claims["operator"] ?? "")) {
                errors.append("\(label).claims.operator is unsupported")
            }
            if ["visible", "readable", "available", "success", "succeeded", "completed"]
                .contains(token(claims["expected"] ?? "")) {
                errors.append("\(label).claims.expected must name a machine-checkable value")
            }
            if claims["expected"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                != task.verificationOracle?.expectedState.trimmingCharacters(in: .whitespacesAndNewlines) {
                errors.append("\(label).claims.expected must match verification_oracle.expected_state")
            }
            if !providers.contains(token(claims["readback_provider"] ?? "")) {
                errors.append("\(label).claims.readback_provider must match a route candidate")
            }
        case "route_flexibility":
            let primaryProvider = token(claims["primary_provider"] ?? "")
            let secondaryProvider = token(claims["secondary_provider"] ?? "")
            if !providers.contains(primaryProvider) {
                errors.append("\(label).claims.primary_provider must match a route candidate")
            }
            if !providers.contains(secondaryProvider) {
                errors.append("\(label).claims.secondary_provider must match a route candidate")
            }
            if primaryProvider == secondaryProvider {
                errors.append("\(label).claims.secondary_provider must differ from primary_provider")
            }
            if token(claims["fallback_policy"] ?? "") != token(task.fallbackPolicy ?? "") {
                errors.append("\(label).claims.fallback_policy must match the task fallback_policy")
            }
        case "stable_change_behavior":
            let scenarios = Set((claims["scenarios"] ?? "").split(separator: ",").map { token(String($0)) })
            for state in changeStates where !scenarios.contains(state) {
                errors.append("\(label).claims.scenarios is missing \(state)")
            }
            if !failureBehaviors.contains(token(claims["failure_behavior"] ?? "")) {
                errors.append("\(label).claims.failure_behavior is unsupported")
            }
        default:
            break
        }
    }

    private static func validateV2(
        _ task: MacControlIdealStateTask,
        label: String,
        errors: inout [String]
    ) {
        if task.selectedRoute?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            errors.append("task \(label) selected_route is runtime evidence and must not be declared")
        }
        if !task.eligibleRoutes.isEmpty {
            errors.append("task \(label) must use route_candidates instead of eligible_routes")
        }
        requireAccounting(
            task.observableStates,
            exemptions: task.stateExemptions,
            values: observableStates,
            label: "task \(label) observable state contract",
            errors: &errors
        )
        requireAccounting(
            task.changeStates,
            exemptions: task.changeStateExemptions,
            values: changeStates,
            label: "task \(label) change state contract",
            errors: &errors
        )
        let focusPolicy = token(task.focusPolicy ?? "")
        if !["foreground", "background"].contains(focusPolicy) {
            errors.append("task \(label) focus_policy must be foreground or background")
        }
        let foregroundPostcondition = token(task.foregroundPostcondition ?? "")
        let expectedForegroundPostcondition = focusPolicy == "background"
            ? "unrelated_foreground_preserved"
            : "target_foreground"
        if foregroundPostcondition != expectedForegroundPostcondition {
            errors.append(
                "task \(label) foreground_postcondition must be \(expectedForegroundPostcondition) for focus_policy \(focusPolicy)"
            )
        }
        if !["none", "explicit_handoff", "fresh_state_handoff"].contains(token(task.fallbackPolicy ?? "")) {
            errors.append("task \(label) fallback_policy must be none, explicit_handoff, or fresh_state_handoff")
        }
        guard let oracle = task.verificationOracle else {
            errors.append("task \(label) requires verification_oracle")
            return validateRouteCandidates(task, label: label, errors: &errors)
        }
        if oracle.oracleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("task \(label) verification_oracle requires oracle_id")
        }
        if !oracleKinds.contains(token(oracle.kind)) {
            errors.append("task \(label) verification_oracle has unsupported kind \(oracle.kind)")
        }
        if oracle.expectedState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("task \(label) verification_oracle requires expected_state")
        }
        if !oracle.independentReadback {
            errors.append("task \(label) verification_oracle requires independent_readback true")
        }
        validateRouteCandidates(task, label: label, errors: &errors)
    }

    private static func validateRouteCandidates(
        _ task: MacControlIdealStateTask,
        label: String,
        errors: inout [String]
    ) {
        if task.routeCandidates.isEmpty {
            errors.append("task \(label) requires route_candidates")
            return
        }
        var IDs = Set<String>()
        for candidate in task.routeCandidates {
            let candidateID = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidateID.isEmpty {
                errors.append("task \(label) route candidate requires id")
            } else if !IDs.insert(candidateID).inserted {
                errors.append("task \(label) route candidate \(candidateID) is duplicated")
            }
            if !providers.contains(token(candidate.provider)) {
                errors.append("task \(label) route candidate \(candidateID) has unsupported provider \(candidate.provider)")
            }
            if !methods.contains(token(candidate.method)) {
                errors.append("task \(label) route candidate \(candidateID) has unsupported method \(candidate.method)")
            }
            if !interactionModes.contains(token(candidate.interactionMode)) {
                errors.append(
                    "task \(label) route candidate \(candidateID) has unsupported interaction_mode \(candidate.interactionMode)"
                )
            }
        }
    }

    private static func validateShortcutAcceleration(
        _ task: MacControlIdealStateTask,
        label: String,
        errors: inout [String]
    ) {
        guard let shortcut = task.shortcutAcceleration else {
            errors.append("task \(label) requires shortcut_acceleration")
            return
        }
        let disposition = token(shortcut.disposition)
        if !shortcutDispositions.contains(disposition) {
            errors.append("task \(label) shortcut_acceleration has unsupported disposition \(shortcut.disposition)")
            return
        }
        let shortcutCandidates = task.routeCandidates.filter { token($0.method) == "shortcut" }
        for candidate in shortcutCandidates where token(candidate.interactionMode) != "keyboard" {
            errors.append("task \(label) shortcut route candidate \(candidate.id) requires interaction_mode keyboard")
        }
        if disposition == "not_applicable" {
            if shortcut.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                errors.append("task \(label) shortcut_acceleration not_applicable requires reason")
            }
            if !shortcutCandidates.isEmpty {
                errors.append("task \(label) shortcut_acceleration not_applicable must not declare a shortcut route candidate")
            }
            return
        }
        if shortcut.commandID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            errors.append("task \(label) shortcut_acceleration requires command_id")
        }
        if shortcut.contextualAvailability != true {
            errors.append("task \(label) shortcut_acceleration requires contextual_availability true")
        }
        if !shortcutConflictPolicies.contains(token(shortcut.conflictPolicy ?? "")) {
            errors.append("task \(label) shortcut_acceleration has unsupported conflict_policy")
        }
        if disposition == "built_in_verified" {
            if shortcut.chord?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                errors.append("task \(label) built_in_verified shortcut_acceleration requires chord")
            }
            if shortcutCandidates.isEmpty {
                errors.append("task \(label) built_in_verified shortcut_acceleration requires a shortcut route candidate")
            }
            return
        }
        let customizationSurface = token(shortcut.customizationSurface ?? "")
        if !shortcutCustomizationSurfaces.contains(customizationSurface) {
            errors.append("task \(label) customizable_verified shortcut_acceleration has unsupported customization_surface")
        }
        if customizationSurface == "macos_app_shortcut",
           shortcut.menuPath.isEmpty || shortcut.menuPath.contains(where: {
               $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            errors.append("task \(label) macos_app_shortcut shortcut_acceleration requires an exact menu_path")
        }
        if shortcut.reversibleAssignment != true {
            errors.append("task \(label) customizable_verified shortcut_acceleration requires reversible_assignment true")
        }
        if shortcut.chord?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           shortcutCandidates.isEmpty {
            errors.append("task \(label) assigned customizable shortcut requires a shortcut route candidate")
        }
    }

    private static func requireAccounting(
        _ declared: [String],
        exemptions: [String: String],
        values: [String],
        label: String,
        errors: inout [String]
    ) {
        let present = Set(declared.map(token))
        var exempt: [String: String] = [:]
        for (state, reason) in exemptions {
            let normalized = token(state)
            if exempt[normalized] != nil {
                errors.append("\(label) contains duplicated exemption \(normalized)")
            } else {
                exempt[normalized] = reason
            }
        }
        for value in present where !values.contains(value) {
            errors.append("\(label) contains unsupported state \(value)")
        }
        for value in exempt.keys where !values.contains(value) {
            errors.append("\(label) exempts unsupported state \(value)")
        }
        for value in present.intersection(exempt.keys) {
            errors.append("\(label) must not both declare and exempt \(value)")
        }
        for value in values where !present.contains(value) && exempt[value] == nil {
            errors.append("\(label) must declare or exempt \(value)")
        }
        for (value, reason) in exempt where reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("\(label) exemption for \(value) requires a reason")
        }
    }

    private static func result(
        _ manifest: MacControlIdealStateManifest,
        errors: [String]
    ) -> MacControlIdealStateManifestValidation {
        MacControlIdealStateManifestValidation(
            valid: errors.isEmpty,
            repositoryID: manifest.repositoryID,
            taskIDs: manifest.tasks.map(\.taskID),
            errors: errors
        )
    }

    private static func require(
        _ values: [String],
        values required: [String],
        label: String,
        errors: inout [String]
    ) {
        let present = Set(values.map(token))
        for value in required where !present.contains(value) {
            errors.append("\(label) is missing \(value)")
        }
    }

    public static func token(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
