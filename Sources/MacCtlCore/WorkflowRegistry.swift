import Foundation

public struct WorkflowValidation: Codable, Equatable {
    public let workflowID: String
    public let valid: Bool
    public let risk: RiskLevel
    public let errors: [String]

    public init(workflowID: String, valid: Bool, risk: RiskLevel, errors: [String]) {
        self.workflowID = workflowID
        self.valid = valid
        self.risk = risk
        self.errors = errors
    }
}

public enum ActionRiskClassifier {
    public static func classify(_ action: ActionSpec) -> RiskLevel {
        let inferred: RiskLevel
        switch action.kind {
        case .launchApp, .activateWindow, .waitFor, .capture, .ocr, .assert:
            inferred = .safe
        case .click, .key:
            inferred = .sensitive
        case .scroll:
            inferred = .reversible
        case .type:
            inferred = .sensitive
        }
        guard let declared = action.risk else { return inferred }
        let rank: (RiskLevel) -> Int = {
            switch $0 {
            case .safe: return 0
            case .reversible: return 1
            case .sensitive: return 2
            }
        }
        return rank(declared) > rank(inferred) ? declared : inferred
    }

    public static func classify(_ workflow: WorkflowSpec) -> RiskLevel {
        workflow.actions
            .map(classify)
            .max(by: { rank($0) < rank($1) }) ?? .safe
    }

    private static func rank(_ risk: RiskLevel) -> Int {
        switch risk {
        case .safe: return 0
        case .reversible: return 1
        case .sensitive: return 2
        }
    }
}

public final class WorkflowRegistry {
    private let fileManager = FileManager.default
    private let builtins: [WorkflowSpec]

    public init() {
        builtins = Self.makeBuiltins()
    }

    public func list() -> [WorkflowSpec] {
        let external = loadExternalWorkflows()
        return (builtins + external).sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    public func workflow(id: String) -> WorkflowSpec? {
        list().first { $0.id == id }
    }

    public func validate(id: String) -> WorkflowValidation {
        guard let workflow = workflow(id: id) else {
            return WorkflowValidation(
                workflowID: id,
                valid: false,
                risk: .safe,
                errors: ["Workflow does not exist"]
            )
        }
        return validate(workflow)
    }

    public func validate(_ workflow: WorkflowSpec) -> WorkflowValidation {
        var errors: [String] = []
        if workflow.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Workflow id must not be empty")
        }
        if workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Workflow name must not be empty")
        }
        if workflow.actions.isEmpty {
            errors.append("Workflow must contain at least one action")
        }
        for (index, action) in workflow.actions.enumerated() {
            if action.surface != workflow.surface {
                errors.append("Action \(index) targets \(action.surface.rawValue), not \(workflow.surface.rawValue)")
            }
            if action.kind == .click {
                let hasCoordinate = action.parameters["x"]?.doubleValue != nil
                    && action.parameters["y"]?.doubleValue != nil
                if action.selector?.hasTarget != true && !hasCoordinate {
                    errors.append("Click action \(index) needs an Accessibility, visual, or coordinate selector")
                }
            }
            if action.kind == .type,
               action.parameters["text_source"]?.stringValue != "ephemeral" {
                errors.append("Type action \(index) must use text_source=ephemeral")
            }
            if ActionRiskClassifier.classify(action) == .sensitive,
               action.parameters["approval_reason"]?.stringValue == nil {
                errors.append("Sensitive action \(index) must declare approval_reason")
            }
        }
        return WorkflowValidation(
            workflowID: workflow.id,
            valid: errors.isEmpty,
            risk: ActionRiskClassifier.classify(workflow),
            errors: errors
        )
    }

    private func loadExternalWorkflows() -> [WorkflowSpec] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: MacCtlPaths.workflowDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.caseInsensitiveCompare("json") == .orderedSame }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONCodec.decode(WorkflowSpec.self, from: data)
            }
    }

    private static func makeBuiltins() -> [WorkflowSpec] {
        let safeOpenWorkflows = [
            ("finder.open", "Open Finder", "Open Finder and activate its front window", "Finder"),
            ("textedit.open", "Open TextEdit", "Open TextEdit and activate its front window", "TextEdit"),
            ("system-settings.open", "Open System Settings", "Open System Settings and activate its front window", "System Settings"),
            ("safari.open", "Open Safari", "Open Safari and activate its front window", "Safari"),
            ("notes.open", "Open Notes", "Open Notes and activate its front window", "Notes")
        ].map { id, name, summary, app in
            WorkflowSpec(
                id: id,
                name: name,
                summary: summary,
                surface: .macApp,
                actions: [
                    ActionSpec(
                        kind: .launchApp,
                        surface: .macApp,
                        parameters: ["app": .string(app)]
                    ),
                    ActionSpec(
                        kind: .activateWindow,
                        surface: .macApp,
                        parameters: ["app": .string(app)]
                    )
                ],
                assertions: [
                    AssertionSpec(
                        kind: "foregroundApp",
                        surface: .macApp,
                        expected: app
                    )
                ],
                recipe: "open-app"
            )
        }

        let iPhoneWorkflow = WorkflowSpec(
            id: "iphone.open-tinder",
            name: "Open Tinder in iPhone Mirroring",
            summary: "Bring iPhone Mirroring forward and locate Tinder without swiping, messaging, purchasing, or submitting",
            surface: .iphoneMirroring,
            actions: [
                ActionSpec(
                    kind: .launchApp,
                    surface: .iphoneMirroring,
                    parameters: ["app": .string("iPhone Mirroring")]
                ),
                ActionSpec(
                    kind: .activateWindow,
                    surface: .iphoneMirroring,
                    parameters: ["app": .string("iPhone Mirroring")]
                ),
                ActionSpec(
                    kind: .waitFor,
                    surface: .iphoneMirroring,
                    parameters: ["seconds": .number(1)]
                )
            ],
            assertions: [
                AssertionSpec(
                    kind: "iphoneMirroringForeground",
                    surface: .iphoneMirroring,
                    expected: "iPhone Mirroring"
                )
            ],
            recipe: "iphone-open-tinder"
        )

        return safeOpenWorkflows + [iPhoneWorkflow]
    }
}
