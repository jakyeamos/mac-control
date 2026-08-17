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
        case .click, .key, .search, .scroll:
            inferred = .reversible
        case .command, .adapter:
            inferred = .sensitive
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
            if action.kind == .search {
                do {
                    _ = try SearchActionContract.parameters(for: action)
                } catch {
                    errors.append("Search action \(index) is invalid: \(error.localizedDescription)")
                }
            }
            if action.parameters["physical_input_mode"]?.stringValue?.lowercased() == "suppressed",
               !workflow.keyboardFreezeRequired {
                errors.append("Suppressed physical keyboard input action \(index) requires keyboard_freeze_required=true")
            }
            if ActionRiskClassifier.classify(action) == .sensitive,
               action.parameters["boundary_reason"]?.stringValue == nil,
               action.parameters["approval_reason"]?.stringValue == nil {
                errors.append("Sensitive action \(index) must declare boundary_reason")
            }
        }
        if workflow.focusPolicy == .background {
            for (index, action) in workflow.actions.enumerated() {
                switch action.kind {
                case .activateWindow, .command:
                    errors.append("Background action \(index) cannot use \(action.kind.rawValue)")
                case .search:
                    if action.surface != .macApp
                        || action.selector?.addressability != .accessibility
                        || !Self.hasAppParameter(action.parameters) {
                        errors.append("Background search action \(index) requires a named macOS app and Accessibility selector")
                    }
                    if action.parameters["replace_existing"]?.boolValue == false {
                        errors.append("Background search action \(index) must replace existing text")
                    }
                case .scroll:
                    if action.surface != .macApp
                        || action.selector?.addressability != .accessibility
                        || action.selector?.role != "AXScrollArea"
                        || !Self.hasAppParameter(action.parameters) {
                        errors.append("Background scroll action \(index) requires a named AXScrollArea target")
                    }
                case .click:
                    if action.surface != .macApp {
                        errors.append("Background click action \(index) must target a macOS app")
                    }
                    if action.selector?.addressability != .accessibility {
                        errors.append("Background click action \(index) requires an Accessibility selector")
                    }
                    if !Self.hasAppParameter(action.parameters) {
                        errors.append("Background click action \(index) must name its target app")
                    }
                case .type:
                    if action.surface != .macApp {
                        errors.append("Background type action \(index) must target a macOS app")
                    }
                    if action.selector?.addressability != .accessibility {
                        errors.append("Background type action \(index) requires an Accessibility selector")
                    }
                    if !Self.hasAppParameter(action.parameters) {
                        errors.append("Background type action \(index) must name its target app")
                    }
                case .key:
                    if action.surface != .macApp {
                        errors.append("Background key action \(index) must target a macOS app")
                    }
                    if !Self.hasAppParameter(action.parameters) {
                        errors.append("Background key action \(index) must name its target app")
                    }
                case .capture, .ocr:
                    if action.surface != .macApp {
                        errors.append("Background \(action.kind.rawValue) action \(index) must target a macOS app")
                    }
                    if !Self.hasAppParameter(action.parameters) {
                        errors.append("Background \(action.kind.rawValue) action \(index) must name its target app")
                    }
                case .launchApp:
                    if action.surface != .macApp || !Self.hasAppParameter(action.parameters) {
                        errors.append("Background launchApp action \(index) must name a macOS app")
                    }
                case .waitFor:
                    break
                case .assert:
                    let condition = action.parameters["condition"]?.stringValue ?? "foregroundApp"
                    if condition == "foregroundApp" {
                        errors.append("Background assert action \(index) cannot inspect foreground focus")
                    }
                    if condition == "ocrContains"
                        && (action.surface != .macApp || !Self.hasAppParameter(action.parameters)) {
                        errors.append("Background OCR assert action \(index) must target a named macOS app")
                    }
                    if condition == "elementExists" {
                        if action.surface != .macApp || !Self.hasAppParameter(action.parameters) {
                            errors.append("Background element assert action \(index) must target a named macOS app")
                        }
                    if action.selector?.addressability != .accessibility {
                            errors.append("Background element assert action \(index) requires an Accessibility selector")
                        }
                    }
                case .adapter:
                    errors.append("Background adapter action \(index) must declare an isolated typed operation")
                }
            }
            for (index, assertion) in workflow.assertions.enumerated() {
                switch assertion.kind {
                case "foregroundApp":
                    errors.append("Background assertion \(index) cannot inspect foreground focus")
                case "ocrContains":
                    if assertion.surface != .macApp || !Self.hasAppParameter(assertion.parameters) {
                        errors.append("Background OCR assertion \(index) must target a named macOS app")
                    }
                case "elementExists":
                    if assertion.surface != .macApp || !Self.hasAppParameter(assertion.parameters) {
                        errors.append("Background element assertion \(index) must target a named macOS app")
                    }
                    if assertion.selector?.addressability != .accessibility {
                        errors.append("Background element assertion \(index) requires an Accessibility selector")
                    }
                default:
                    break
                }
            }
        }
        return WorkflowValidation(
            workflowID: workflow.id,
            valid: errors.isEmpty,
            risk: ActionRiskClassifier.classify(workflow),
            errors: errors
        )
    }

    private static func hasAppParameter(_ parameters: [String: JSONValue]) -> Bool {
        guard let app = parameters["app"]?.stringValue else { return false }
        return !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            ("chrome.open", "Open Google Chrome", "Open Google Chrome and activate its front window", "Google Chrome"),
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

        let directExecutionSmokeWorkflow = WorkflowSpec(
            id: "execution.smoke",
            name: "Direct Execution Smoke",
            summary: "Exercise direct agent execution without external input or account changes",
            surface: .macDesktop,
            actions: [
                ActionSpec(
                    kind: .waitFor,
                    surface: .macDesktop,
                    parameters: [
                        "seconds": .number(0.2),
                        "boundary_reason": .string("Tier-1 direct-execution smoke; no external input or account change")
                    ],
                    risk: .sensitive
                )
            ],
            recipe: "execution-smoke"
        )

        return safeOpenWorkflows + [directExecutionSmokeWorkflow]
    }
}
