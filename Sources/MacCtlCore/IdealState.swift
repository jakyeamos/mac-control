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

public struct MacControlIdealStateTask: Codable, Equatable {
    public let taskID: String
    public let stableTargetID: String
    public let hierarchy: String
    public let semanticAction: String
    public let observablePostcondition: String
    public let observableStates: [String]
    public let navigationStrategy: String
    public let eligibleRoutes: [String]
    public let selectedRoute: String
    public let changeStates: [String]
    public let accessibility: AccessibilityAuditControl?

    public init(
        taskID: String,
        stableTargetID: String,
        hierarchy: String,
        semanticAction: String,
        observablePostcondition: String,
        observableStates: [String],
        navigationStrategy: String,
        eligibleRoutes: [String],
        selectedRoute: String,
        changeStates: [String],
        accessibility: AccessibilityAuditControl? = nil
    ) {
        self.taskID = taskID
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
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
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
    public static let schema = "mac-control-task-manifest/v1"
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

    public static func validate(
        _ manifest: MacControlIdealStateManifest
    ) -> MacControlIdealStateManifestValidation {
        var errors: [String] = []
        let applicability = token(manifest.applicability)
        if manifest.schema != schema {
            errors.append("schema must be \(schema)")
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
        for criterion in criteria {
            if manifest.criteria[criterion] != true {
                errors.append("criteria.\(criterion) must be true")
            }
        }
        for criterion in manifest.criteria.keys where !criteria.contains(criterion) {
            errors.append("criteria contains unsupported key \(criterion)")
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
                (task.navigationStrategy, "navigation_strategy"),
                (task.selectedRoute, "selected_route")
            ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("task \(label) requires \(key)")
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
            if !eligible.contains(token(task.selectedRoute)) {
                errors.append("task \(label) selected_route must be eligible")
            }
            if token(task.navigationStrategy) == "search_shortcut" {
                if token(task.semanticAction) != "search" {
                    errors.append("task \(label) search_shortcut requires semantic_action search")
                }
                if !eligible.contains("keyboard") {
                    errors.append("task \(label) search_shortcut requires keyboard in eligible_routes")
                }
                if token(task.selectedRoute) != "keyboard" {
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
            if let accessibility = task.accessibility,
               accessibility.identifier == nil,
               accessibility.label == nil,
               accessibility.role == nil,
               accessibility.subrole == nil {
                errors.append("task \(label) accessibility needs identifier, label, role, or subrole")
            }
        }
        return result(manifest, errors: errors)
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
