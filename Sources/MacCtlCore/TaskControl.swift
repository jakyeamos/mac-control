import CryptoKit
import Foundation

private struct TaskCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

/// The lifecycle of a checkpointed task.  A task never resumes implicitly after
/// a process restart; `resume` must supply fresh authority and approval.
public enum TaskLifecycleState: String, Codable, Equatable, CaseIterable {
    case prepared
    case running
    case paused
    case blocked
    case indeterminate
    case completed
    case cancelled
    case expired
}

public enum TaskPredicateKind: String, Codable, Equatable, CaseIterable {
    case foregroundApplication = "foreground_application"
    case focusedElement = "focused_element"
    case elementExists = "element_exists"
    case windowVisible = "window_visible"
    case applicationRunning = "application_running"
    case adapterState = "adapter_state"
    case modalAbsent = "modal_absent"
    case focusReadable = "focus_readable"
    case menuItemState = "menu_item_state"
}

/// A stable identity supplied by the plan.  Runtime fingerprints are derived
/// from it and are never written into a plan receipt as raw selector data.
public struct TaskTargetIdentity: Codable, Equatable {
    public let application: String?
    public let bundleID: String?
    public let processID: Int32?
    public let windowFingerprint: String?
    public let focusedElementFingerprint: String?
    public let selector: Selector?

    public init(
        application: String? = nil,
        bundleID: String? = nil,
        processID: Int32? = nil,
        windowFingerprint: String? = nil,
        focusedElementFingerprint: String? = nil,
        selector: Selector? = nil
    ) {
        self.application = application
        self.bundleID = bundleID
        self.processID = processID
        self.windowFingerprint = windowFingerprint
        self.focusedElementFingerprint = focusedElementFingerprint
        self.selector = selector
    }

    private enum CodingKeys: String, CodingKey {
        case application, bundleID, processID, windowFingerprint, focusedElementFingerprint, selector
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaskCodingKey.self)
        application = try container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "application")!)
        bundleID = try (container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "bundleID")!)
            ?? container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "bundle_id")!))
        processID = try (container.decodeIfPresent(Int32.self, forKey: TaskCodingKey(stringValue: "processID")!)
            ?? container.decodeIfPresent(Int32.self, forKey: TaskCodingKey(stringValue: "process_id")!))
        windowFingerprint = try (container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "windowFingerprint")!)
            ?? container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "window_fingerprint")!))
        focusedElementFingerprint = try (container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "focusedElementFingerprint")!)
            ?? container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "focused_element_fingerprint")!))
        selector = try container.decodeIfPresent(Selector.self, forKey: TaskCodingKey(stringValue: "selector")!)
    }
}

public struct TaskPredicate: Codable, Equatable {
    public let kind: TaskPredicateKind
    public let expected: String?
    public let application: String?
    public let bundleID: String?
    public let selector: Selector?
    public let parameters: [String: JSONValue]

    public init(
        kind: TaskPredicateKind,
        expected: String? = nil,
        application: String? = nil,
        bundleID: String? = nil,
        selector: Selector? = nil,
        parameters: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.expected = expected
        self.application = application
        self.bundleID = bundleID
        self.selector = selector
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case kind, expected, application, bundleID, selector, parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaskCodingKey.self)
        kind = try container.decode(TaskPredicateKind.self, forKey: TaskCodingKey(stringValue: "kind")!)
        expected = try container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "expected")!)
        application = try container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "application")!)
        bundleID = try (container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "bundleID")!)
            ?? container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "bundle_id")!))
        selector = try container.decodeIfPresent(Selector.self, forKey: TaskCodingKey(stringValue: "selector")!)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: TaskCodingKey(stringValue: "parameters")!) ?? [:]
    }
}

/// Adaptive recovery is deliberately declared in the plan.  The runner still
/// caps attempts by risk, so a plan cannot turn a sensitive action into a
/// retry loop.
public struct TaskRecoveryPolicy: Codable, Equatable {
    public let mode: String
    public let alternateRoutes: [String]
    public let maxAttempts: Int?

    public init(
        mode: String = "adaptive",
        alternateRoutes: [String] = [],
        maxAttempts: Int? = nil
    ) {
        self.mode = mode
        self.alternateRoutes = alternateRoutes
        self.maxAttempts = maxAttempts
    }

    public static let adaptive = TaskRecoveryPolicy()
    public static let strict = TaskRecoveryPolicy(mode: "strict")
    public static let retry = TaskRecoveryPolicy(mode: "retry")

    public var permitsAlternateRoute: Bool {
        !alternateRoutes.isEmpty && mode != "strict"
    }

    private enum CodingKeys: String, CodingKey {
        case mode, alternateRoutes, maxAttempts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaskCodingKey.self)
        mode = try container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "mode")!) ?? "adaptive"
        alternateRoutes = try (container.decodeIfPresent([String].self, forKey: TaskCodingKey(stringValue: "alternateRoutes")!)
            ?? container.decodeIfPresent([String].self, forKey: TaskCodingKey(stringValue: "alternate_routes")!))
            ?? []
        maxAttempts = try (container.decodeIfPresent(Int.self, forKey: TaskCodingKey(stringValue: "maxAttempts")!)
            ?? container.decodeIfPresent(Int.self, forKey: TaskCodingKey(stringValue: "max_attempts")!))
    }
}

public struct TaskStep: Codable, Equatable {
    public let id: String
    public let action: ActionSpec
    public let target: TaskTargetIdentity?
    public let preconditions: [TaskPredicate]
    public let postconditions: [TaskPredicate]
    public let risk: RiskLevel
    public let approvalReason: String?
    public let timeout: TimeInterval
    public let recovery: TaskRecoveryPolicy

    public init(
        id: String,
        action: ActionSpec,
        target: TaskTargetIdentity? = nil,
        preconditions: [TaskPredicate] = [],
        postconditions: [TaskPredicate] = [],
        risk: RiskLevel? = nil,
        approvalReason: String? = nil,
        timeout: TimeInterval = 30,
        recovery: TaskRecoveryPolicy = .adaptive
    ) {
        self.id = id
        self.action = action
        self.target = target
        self.preconditions = preconditions
        self.postconditions = postconditions
        self.risk = risk ?? ActionRiskClassifier.classify(action)
        self.approvalReason = approvalReason
        self.timeout = timeout
        self.recovery = recovery
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, target, preconditions, postconditions, risk, approvalReason, timeout, recovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaskCodingKey.self)
        id = try container.decode(String.self, forKey: TaskCodingKey(stringValue: "id")!)
        action = try container.decode(ActionSpec.self, forKey: TaskCodingKey(stringValue: "action")!)
        target = try container.decodeIfPresent(TaskTargetIdentity.self, forKey: TaskCodingKey(stringValue: "target")!)
        preconditions = try container.decodeIfPresent([TaskPredicate].self, forKey: TaskCodingKey(stringValue: "preconditions")!) ?? []
        postconditions = try container.decodeIfPresent([TaskPredicate].self, forKey: TaskCodingKey(stringValue: "postconditions")!) ?? []
        risk = try container.decodeIfPresent(RiskLevel.self, forKey: TaskCodingKey(stringValue: "risk")!)
            ?? action.risk
            ?? ActionRiskClassifier.classify(action)
        approvalReason = try (container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "approvalReason")!)
            ?? container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "approval_reason")!))
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: TaskCodingKey(stringValue: "timeout")!) ?? 30
        recovery = try container.decodeIfPresent(TaskRecoveryPolicy.self, forKey: TaskCodingKey(stringValue: "recovery")!) ?? .adaptive
    }
}

public struct TaskPlan: Codable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let surface: SurfaceKind
    public let focusPolicy: FocusPolicy
    public let keyboardFreezeRequired: Bool
    public let steps: [TaskStep]
    public let totalTimeout: TimeInterval
    public let maxActions: Int
    public let recipe: String?

    public init(
        id: String,
        name: String,
        summary: String,
        surface: SurfaceKind = .macApp,
        focusPolicy: FocusPolicy = .foreground,
        keyboardFreezeRequired: Bool = false,
        steps: [TaskStep],
        totalTimeout: TimeInterval = 300,
        maxActions: Int = 128,
        recipe: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.surface = surface
        self.focusPolicy = focusPolicy
        self.keyboardFreezeRequired = keyboardFreezeRequired
        self.steps = steps
        self.totalTimeout = totalTimeout
        self.maxActions = maxActions
        self.recipe = recipe
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, surface, focusPolicy, keyboardFreezeRequired, steps, totalTimeout, maxActions, recipe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TaskCodingKey.self)
        id = try container.decode(String.self, forKey: TaskCodingKey(stringValue: "id")!)
        name = try container.decode(String.self, forKey: TaskCodingKey(stringValue: "name")!)
        summary = try container.decode(String.self, forKey: TaskCodingKey(stringValue: "summary")!)
        surface = try container.decodeIfPresent(SurfaceKind.self, forKey: TaskCodingKey(stringValue: "surface")!) ?? .macApp
        focusPolicy = try (container.decodeIfPresent(FocusPolicy.self, forKey: TaskCodingKey(stringValue: "focusPolicy")!)
            ?? container.decodeIfPresent(FocusPolicy.self, forKey: TaskCodingKey(stringValue: "focus_policy")!))
            ?? .foreground
        keyboardFreezeRequired = try container.decodeIfPresent(
            Bool.self,
            forKey: TaskCodingKey(stringValue: "keyboardFreezeRequired")!
        ) ?? container.decodeIfPresent(
            Bool.self,
            forKey: TaskCodingKey(stringValue: "keyboard_freeze_required")!
        ) ?? false
        steps = try container.decode([TaskStep].self, forKey: TaskCodingKey(stringValue: "steps")!)
        totalTimeout = try (container.decodeIfPresent(TimeInterval.self, forKey: TaskCodingKey(stringValue: "totalTimeout")!)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: TaskCodingKey(stringValue: "total_timeout")!))
            ?? 300
        maxActions = try (container.decodeIfPresent(Int.self, forKey: TaskCodingKey(stringValue: "maxActions")!)
            ?? container.decodeIfPresent(Int.self, forKey: TaskCodingKey(stringValue: "max_actions")!))
            ?? TaskPlanValidator.maximumActions
        recipe = try container.decodeIfPresent(String.self, forKey: TaskCodingKey(stringValue: "recipe")!)
    }

    public var requiresInputAuthority: Bool {
        requiresInputAuthority(using: nil)
    }

    public func requiresInputAuthority(using adapterRegistry: AppAdapterRegistry?) -> Bool {
        steps.contains { step in
            switch step.action.kind {
            case .click, .type, .key, .search, .command, .scroll, .activateWindow, .adapter:
                if step.action.kind == .adapter {
                    if let adapterRegistry,
                       let adapterID = step.action.parameters["adapter_id"]?.stringValue,
                       let operationName = step.action.parameters["operation"]?.stringValue,
                       let operation = try? adapterRegistry.operation(
                           adapterID: adapterID,
                           name: operationName
                       ) {
                        return operation.mutating
                    }
                    return step.action.parameters["mutating"]?.boolValue ?? (step.risk != .safe)
                }
                return true
            case .launchApp, .waitFor, .capture, .ocr, .assert:
                return false
            }
        }
    }

    public static func digest(
        _ plan: TaskPlan,
        ephemeralInputs: [String: String] = [:]
    ) -> String {
        let payload = TaskPlanDigestPayload(plan: plan, ephemeralInputs: ephemeralInputs)
        guard let data = try? JSONCodec.encode(payload) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func remaining(from stepIndex: Int) -> TaskPlan {
        TaskPlan(
            id: id,
            name: name,
            summary: summary,
            surface: surface,
            focusPolicy: focusPolicy,
            keyboardFreezeRequired: keyboardFreezeRequired,
            steps: Array(steps.dropFirst(max(0, stepIndex))),
            totalTimeout: totalTimeout,
            maxActions: maxActions,
            recipe: recipe
        )
    }

    public func withFocusPolicy(_ focusPolicy: FocusPolicy) -> TaskPlan {
        TaskPlan(
            id: id,
            name: name,
            summary: summary,
            surface: surface,
            focusPolicy: focusPolicy,
            keyboardFreezeRequired: keyboardFreezeRequired,
            steps: steps,
            totalTimeout: totalTimeout,
            maxActions: maxActions,
            recipe: recipe
        )
    }
}

public enum TaskInputChannelRoute: String, Codable, Equatable, CaseIterable {
    case accessibility
    case processDirected = "process_directed"
}

/// An in-memory input authority bound to one approved background task and one
/// running application process. It is not a system-wide virtual HID device and
/// cannot be reused by another task or plan digest.
public struct TaskInputChannel: Codable, Equatable {
    public let channelID: String
    public let taskID: String
    public let planDigest: String
    public let focusPolicy: FocusPolicy
    public let targetApplication: AppInfo
    public let routes: [TaskInputChannelRoute]
    public let expiresAt: Date

    public init(
        channelID: String = "input_\(UUID().uuidString)",
        taskID: String,
        planDigest: String,
        focusPolicy: FocusPolicy,
        targetApplication: AppInfo,
        routes: [TaskInputChannelRoute],
        expiresAt: Date
    ) {
        self.channelID = channelID
        self.taskID = taskID
        self.planDigest = planDigest
        self.focusPolicy = focusPolicy
        self.targetApplication = targetApplication
        self.routes = routes
        self.expiresAt = expiresAt
    }

    public func permits(_ route: TaskInputChannelRoute) -> Bool {
        routes.contains(route)
    }
}

public struct TaskPlanValidation: Codable, Equatable {
    public let taskID: String
    public let valid: Bool
    public let risk: RiskLevel
    public let errors: [String]

    public init(taskID: String, valid: Bool, risk: RiskLevel, errors: [String]) {
        self.taskID = taskID
        self.valid = valid
        self.risk = risk
        self.errors = errors
    }
}

public enum TaskPlanValidator {
    public static let maximumSteps = 64
    public static let maximumTotalTimeout: TimeInterval = 300
    public static let maximumActions = 128

    public static func validate(
        _ plan: TaskPlan,
        adapterRegistry: AppAdapterRegistry? = nil
    ) -> TaskPlanValidation {
        var errors: [String] = []
        if plan.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Task id must not be empty")
        }
        if plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Task name must not be empty")
        }
        if plan.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Task summary must not be empty")
        }
        if plan.steps.isEmpty {
            errors.append("Task must contain at least one step")
        }
        if plan.steps.count > maximumSteps {
            errors.append("Task contains more than \(maximumSteps) steps")
        }
        if !(0.001...maximumTotalTimeout).contains(plan.totalTimeout) {
            errors.append("Task total timeout must be between 0.001 and \(Int(maximumTotalTimeout)) seconds")
        }
        if !(1...maximumActions).contains(plan.maxActions) {
            errors.append("Task action budget must be between 1 and \(maximumActions)")
        }
        var ids = Set<String>()
        for (index, step) in plan.steps.enumerated() {
            let trimmedID = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedID.isEmpty {
                errors.append("Step \(index) id must not be empty")
            } else if !ids.insert(trimmedID).inserted {
                errors.append("Step id is duplicated: \(trimmedID)")
            }
            if step.action.surface != plan.surface {
                errors.append("Step \(trimmedID) targets \(step.action.surface.rawValue), not \(plan.surface.rawValue)")
            }
            if !(0.05...30).contains(step.timeout) {
                errors.append("Step \(trimmedID) timeout must be between 0.05 and 30 seconds")
            }
            if step.risk == .sensitive {
                let reason = step.approvalReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if reason.isEmpty {
                    errors.append("Sensitive step \(trimmedID) must declare approval_reason")
                }
            }
            if step.action.parameters["physical_input_mode"]?.stringValue?.lowercased() == "suppressed",
               !plan.keyboardFreezeRequired {
                errors.append("Suppressed physical keyboard input step \(trimmedID) requires keyboard_freeze_required=true")
            }
            if step.recovery.maxAttempts != nil, step.recovery.maxAttempts! < 1 {
                errors.append("Step \(trimmedID) recovery max_attempts must be positive")
            }
            if !["adaptive", "strict", "retry"].contains(step.recovery.mode) {
                errors.append("Step \(trimmedID) recovery mode is unsupported")
            }
            if step.recovery.mode == "strict", !step.recovery.alternateRoutes.isEmpty {
                errors.append("Step \(trimmedID) strict recovery cannot declare alternate routes")
            }
            for route in step.recovery.alternateRoutes {
                if !knownRecoveryRoutes.contains(route) {
                    errors.append("Step \(trimmedID) recovery route is unsupported: \(route)")
                }
            }
            if step.action.kind == .search,
               step.recovery.alternateRoutes.contains(where: { $0 != "keyboard" }) {
                errors.append("Step \(trimmedID) search recovery may only use the keyboard route")
            }
            let inferredRisk = minimumRisk(for: step.action, adapterRegistry: adapterRegistry)
            if rank(step.risk) < rank(inferredRisk) {
                errors.append("Step \(trimmedID) risk \(step.risk.rawValue) is below the required \(inferredRisk.rawValue) floor")
            }
            validateAction(
                step.action,
                stepID: trimmedID,
                adapterRegistry: adapterRegistry,
                errors: &errors
            )
            validatePredicates(step.preconditions, label: "precondition", stepID: trimmedID, errors: &errors)
            validatePredicates(step.postconditions, label: "postcondition", stepID: trimmedID, errors: &errors)
        }
        if plan.focusPolicy == .background {
            validateBackgroundInputChannel(plan, adapterRegistry: adapterRegistry, errors: &errors)
        }
        let risk = plan.steps.map(\.risk).max(by: { rank($0) < rank($1) }) ?? .safe
        return TaskPlanValidation(taskID: plan.id, valid: errors.isEmpty, risk: risk, errors: errors)
    }

    private static func validateBackgroundInputChannel(
        _ plan: TaskPlan,
        adapterRegistry: AppAdapterRegistry?,
        errors: inout [String]
    ) {
        var inputTargets = Set<String>()
        for step in plan.steps {
            switch step.action.kind {
            case .click, .type, .search, .scroll:
                if step.action.surface != .macApp {
                    errors.append("Background step \(step.id) must target a macOS app")
                }
                if step.action.selector?.addressability != .accessibility {
                    errors.append("Background step \(step.id) requires an Accessibility selector")
                }
                if step.action.kind == .search,
                   step.action.parameters["replace_existing"]?.boolValue == false {
                    errors.append("Background step \(step.id) search must replace existing text")
                }
                collectBackgroundTarget(step, targets: &inputTargets, errors: &errors)
            case .key:
                if step.action.surface != .macApp {
                    errors.append("Background step \(step.id) must target a macOS app")
                }
                collectBackgroundTarget(step, targets: &inputTargets, errors: &errors)
            case .adapter:
                if step.action.surface != .macApp {
                    errors.append("Background step \(step.id) must target a macOS app")
                }
                let adapterID = step.action.parameters["adapter_id"]?.stringValue
                let operationName = step.action.parameters["operation"]?.stringValue
                let operation = adapterID.flatMap { adapterID in
                    operationName.flatMap { try? adapterRegistry?.operation(adapterID: adapterID, name: $0) }
                }
                if operation?.focusSupport != .backgroundSafe {
                    errors.append("Background step \(step.id) requires a background-safe adapter operation")
                }
                collectBackgroundTarget(step, targets: &inputTargets, errors: &errors)
            case .launchApp, .waitFor, .assert:
                break
            case .activateWindow, .command, .capture, .ocr:
                errors.append("Background step \(step.id) cannot use \(step.action.kind.rawValue)")
            }
            if step.action.parameters["physical_input_mode"]?.stringValue?.lowercased() == "suppressed" {
                errors.append("Background step \(step.id) cannot suppress the physical keyboard")
            }
        }
        if inputTargets.count > 1 {
            errors.append("A background task input channel must target exactly one application")
        }
    }

    private static func collectBackgroundTarget(
        _ step: TaskStep,
        targets: inout Set<String>,
        errors: inout [String]
    ) {
        let target = step.target?.bundleID
            ?? step.target?.application
            ?? step.action.parameters["app"]?.stringValue
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errors.append("Background step \(step.id) must name its target application")
            return
        }
        targets.insert(target.lowercased())
    }

    private static func validateAction(
        _ action: ActionSpec,
        stepID: String,
        adapterRegistry: AppAdapterRegistry?,
        errors: inout [String]
    ) {
        switch action.kind {
        case .click:
            let hasCoordinate = action.parameters["x"]?.doubleValue != nil
                && action.parameters["y"]?.doubleValue != nil
            if action.selector?.hasTarget != true && !hasCoordinate {
                errors.append("Step \(stepID) click needs a target")
            }
            if action.selector?.addressability == .rawCoordinate,
               action.parameters["coordinate_mode"]?.stringValue != "raw" {
                errors.append("Step \(stepID) raw coordinates require coordinate_mode=raw")
            }
        case .type:
            if action.parameters["text_source"]?.stringValue != "ephemeral" {
                errors.append("Step \(stepID) type must use text_source=ephemeral")
            }
            if action.parameters["input_key"]?.stringValue == nil {
                errors.append("Step \(stepID) type must name an ephemeral input_key")
            }
        case .search:
            do {
                _ = try SearchActionContract.parameters(for: action)
            } catch {
                errors.append("Step \(stepID) search is invalid: \(error.localizedDescription)")
            }
        case .command:
            if action.parameters["binding_id"]?.stringValue == nil
                || action.parameters["binding_digest"]?.stringValue == nil
                || action.parameters["operation"]?.stringValue == nil {
                errors.append("Step \(stepID) command requires binding_id, binding_digest, and operation")
            }
        case .key:
            guard let key = action.parameters["key"]?.stringValue else {
                errors.append("Step \(stepID) key requires a key specification")
                return
            }
            do {
                _ = try KeyboardAccessController.validateRawSequence([key])
            } catch KeyboardControlError.printableKeyRejected {
                errors.append("Step \(stepID) key cannot be a bare printable character")
            } catch {
                errors.append("Step \(stepID) key is invalid")
            }
        case .adapter:
            guard let adapterID = action.parameters["adapter_id"]?.stringValue else {
                errors.append("Step \(stepID) adapter action requires adapter_id")
                return
            }
            guard let operation = action.parameters["operation"]?.stringValue else {
                errors.append("Step \(stepID) adapter action requires operation")
                return
            }
            if action.parameters["script"] != nil || action.parameters["jxa"] != nil {
                errors.append("Step \(stepID) adapter actions cannot contain arbitrary script or JXA")
            }
            let privateKeys = [
                "body", "content", "document_text", "email", "message", "password",
                "credential", "secret", "subject", "text", "title", "token"
            ]
            for key in privateKeys where action.parameters[key] != nil {
                errors.append("Step \(stepID) adapter private input \(key) must use an ephemeral key")
            }
            if let adapterRegistry {
                do {
                    _ = try adapterRegistry.operation(adapterID: adapterID, name: operation)
                } catch let error as AppAdapterError {
                    errors.append(error.localizedDescription)
                } catch {
                    errors.append("Step \(stepID) adapter operation is not allowlisted")
                }
            }
        case .launchApp, .activateWindow, .scroll, .waitFor, .capture, .ocr, .assert:
            break
        }
    }

    private static let knownRecoveryRoutes: Set<String> = [
        "native", "accessibility", "keyboard", "visual", "apple_script"
    ]

    private static func minimumRisk(
        for action: ActionSpec,
        adapterRegistry: AppAdapterRegistry?
    ) -> RiskLevel {
        if action.kind == .adapter,
           let adapterID = action.parameters["adapter_id"]?.stringValue,
           let operationName = action.parameters["operation"]?.stringValue,
           let adapterRegistry,
           let operation = try? adapterRegistry.operation(adapterID: adapterID, name: operationName) {
            return maxRisk(operation.risk, action.risk ?? .safe)
        }
        return ActionRiskClassifier.classify(action)
    }

    private static func maxRisk(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func validatePredicates(
        _ predicates: [TaskPredicate],
        label: String,
        stepID: String,
        errors: inout [String]
    ) {
        for predicate in predicates {
            switch predicate.kind {
            case .focusedElement, .elementExists:
                guard predicate.selector?.hasTarget == true else {
                    errors.append("Step \(stepID) \(label) \(predicate.kind.rawValue) requires a selector")
                    continue
                }
            case .foregroundApplication, .applicationRunning:
                if (predicate.application ?? predicate.expected ?? predicate.bundleID ?? "").isEmpty {
                    errors.append("Step \(stepID) \(label) \(predicate.kind.rawValue) requires an application")
                }
            case .adapterState:
                if predicate.parameters["adapter_id"]?.stringValue == nil
                    || predicate.parameters["state"]?.stringValue == nil {
                    errors.append("Step \(stepID) \(label) adapter_state requires adapter_id and state")
                }
            case .menuItemState:
                guard let path = predicate.parameters["menu_path"]?.arrayValue,
                      path.count >= 2,
                      path.allSatisfy({ $0.stringValue?.isEmpty == false }) else {
                    errors.append("Step \(stepID) \(label) menu_item_state requires an exact menu_path")
                    continue
                }
                if !["checked", "unchecked", "toggled", "enabled", "disabled"].contains(predicate.expected ?? "") {
                    errors.append("Step \(stepID) \(label) menu_item_state has an unsupported expected state")
                }
            case .windowVisible, .modalAbsent, .focusReadable:
                break
            }
        }
    }

    public static func maximumAttempts(
        for risk: RiskLevel,
        recovery: TaskRecoveryPolicy
    ) -> Int {
        let cap: Int
        switch risk {
        case .safe: cap = 3
        case .reversible: cap = 2
        case .sensitive: cap = 1
        }
        guard let requested = recovery.maxAttempts else { return cap }
        return min(cap, max(1, requested))
    }

    private static func rank(_ risk: RiskLevel) -> Int {
        switch risk {
        case .safe: return 0
        case .reversible: return 1
        case .sensitive: return 2
        }
    }
}

public struct TaskCheckpoint: Codable, Equatable {
    public let schemaVersion: Int
    public let taskID: String
    public let planDigest: String
    public let currentStepID: String?
    public let lastStepID: String?
    public let stepIndex: Int
    public let state: TaskLifecycleState
    public let route: String?
    public let attempts: Int
    public let targetFingerprint: String?
    public let preconditionHash: String?
    public let postconditionHash: String?
    public let verificationResult: String
    public let lastErrorCode: String?
    public let createdAt: Date
    public let updatedAt: Date
    /// The first execution start is retained so a resumed task cannot reset
    /// the plan-wide timeout after a daemon restart or pause.
    public let startedAt: Date?

    public init(
        taskID: String,
        planDigest: String,
        currentStepID: String?,
        lastStepID: String? = nil,
        stepIndex: Int,
        state: TaskLifecycleState,
        route: String? = nil,
        attempts: Int = 0,
        targetFingerprint: String? = nil,
        preconditionHash: String? = nil,
        postconditionHash: String? = nil,
        verificationResult: String = "not_run",
        lastErrorCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.planDigest = planDigest
        self.currentStepID = currentStepID
        self.lastStepID = lastStepID
        self.stepIndex = stepIndex
        self.state = state
        self.route = route
        self.attempts = attempts
        self.targetFingerprint = targetFingerprint
        self.preconditionHash = preconditionHash
        self.postconditionHash = postconditionHash
        self.verificationResult = verificationResult
        self.lastErrorCode = lastErrorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, taskID, planDigest, currentStepID, lastStepID, stepIndex, state
        case route, attempts, targetFingerprint, preconditionHash, postconditionHash
        case verificationResult, lastErrorCode, createdAt, updatedAt, startedAt
        case startedAtUnixSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(planDigest, forKey: .planDigest)
        try container.encodeIfPresent(currentStepID, forKey: .currentStepID)
        try container.encodeIfPresent(lastStepID, forKey: .lastStepID)
        try container.encode(stepIndex, forKey: .stepIndex)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(route, forKey: .route)
        try container.encode(attempts, forKey: .attempts)
        try container.encodeIfPresent(targetFingerprint, forKey: .targetFingerprint)
        try container.encodeIfPresent(preconditionHash, forKey: .preconditionHash)
        try container.encodeIfPresent(postconditionHash, forKey: .postconditionHash)
        try container.encode(verificationResult, forKey: .verificationResult)
        try container.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        if let startedAt {
            // Keep the legacy ISO field for older readers while the numeric
            // projection preserves sub-second timeout state across restarts.
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(startedAt.timeIntervalSince1970, forKey: .startedAtUnixSeconds)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        taskID = try container.decode(String.self, forKey: .taskID)
        planDigest = try container.decode(String.self, forKey: .planDigest)
        currentStepID = try container.decodeIfPresent(String.self, forKey: .currentStepID)
        lastStepID = try container.decodeIfPresent(String.self, forKey: .lastStepID)
        stepIndex = try container.decode(Int.self, forKey: .stepIndex)
        state = try container.decode(TaskLifecycleState.self, forKey: .state)
        route = try container.decodeIfPresent(String.self, forKey: .route)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        targetFingerprint = try container.decodeIfPresent(String.self, forKey: .targetFingerprint)
        preconditionHash = try container.decodeIfPresent(String.self, forKey: .preconditionHash)
        postconditionHash = try container.decodeIfPresent(String.self, forKey: .postconditionHash)
        verificationResult = try container.decodeIfPresent(String.self, forKey: .verificationResult) ?? "not_run"
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let unixSeconds = try container.decodeIfPresent(Double.self, forKey: .startedAtUnixSeconds) {
            startedAt = Date(timeIntervalSince1970: unixSeconds)
        } else {
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        }
    }
}

public struct TaskStatusReport: Codable, Equatable {
    public let taskID: String
    public let planDigest: String
    public let state: TaskLifecycleState
    public let stepIndex: Int
    public let currentStepID: String?
    public let lastStepID: String?
    public let attempts: Int
    public let lastRoute: String?
    public let lastErrorCode: String?
    public let checkpointUpdatedAt: Date?
    public let completedAt: Date?

    public init(
        taskID: String,
        planDigest: String,
        state: TaskLifecycleState,
        stepIndex: Int,
        currentStepID: String?,
        lastStepID: String? = nil,
        attempts: Int,
        lastRoute: String?,
        lastErrorCode: String?,
        checkpointUpdatedAt: Date?,
        completedAt: Date? = nil
    ) {
        self.taskID = taskID
        self.planDigest = planDigest
        self.state = state
        self.stepIndex = stepIndex
        self.currentStepID = currentStepID
        self.lastStepID = lastStepID
        self.attempts = attempts
        self.lastRoute = lastRoute
        self.lastErrorCode = lastErrorCode
        self.checkpointUpdatedAt = checkpointUpdatedAt
        self.completedAt = completedAt
    }

    public var lifecycleState: TaskLifecycleState { state }
}

public struct TaskPreparedReport: Codable, Equatable {
    public let taskID: String
    public let planDigest: String
    public let state: TaskLifecycleState
    public let approval: ApprovalRecord

    public init(taskID: String, planDigest: String, state: TaskLifecycleState, approval: ApprovalRecord) {
        self.taskID = taskID
        self.planDigest = planDigest
        self.state = state
        self.approval = approval
    }
}

public struct TaskCapabilityReport: Codable, Equatable {
    public let methods: [String]
    public let maximumSteps: Int
    public let maximumTaskTimeout: TimeInterval
    public let maximumActions: Int
    public let automaticResume: Bool

    public init(
        methods: [String] = ["task.prepare", "task.run", "task.status", "task.resume", "task.cancel"],
        maximumSteps: Int = TaskPlanValidator.maximumSteps,
        maximumTaskTimeout: TimeInterval = TaskPlanValidator.maximumTotalTimeout,
        maximumActions: Int = TaskPlanValidator.maximumActions,
        automaticResume: Bool = false
    ) {
        self.methods = methods
        self.maximumSteps = maximumSteps
        self.maximumTaskTimeout = maximumTaskTimeout
        self.maximumActions = maximumActions
        self.automaticResume = automaticResume
    }
}

public enum TaskControlError: Error, LocalizedError, Equatable {
    case invalidPlan([String])
    case notFound(String)
    case approvalRequired
    case approvalMismatch
    case invalidState(TaskLifecycleState)
    case leaseRequired
    case leaseExpired
    case cancelled
    case timedOut
    case actionBudgetExceeded
    case preconditionFailed(String)
    case postconditionFailed(String)
    case indeterminate(String)
    case checkpointUnavailable(String)
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlan(let errors): return "Task plan is invalid: \(errors.joined(separator: "; "))"
        case .notFound(let taskID): return "Task checkpoint was not found: \(taskID)"
        case .approvalRequired: return "An approved token bound to the exact task plan is required"
        case .approvalMismatch: return "Task approval does not match the supplied plan or ephemeral inputs"
        case .invalidState(let state): return "Task cannot be run from state \(state.rawValue)"
        case .leaseRequired: return "A fresh control lease is required for this task"
        case .leaseExpired: return "The task control lease expired"
        case .cancelled: return "Task was cancelled"
        case .timedOut: return "Task exceeded its timeout"
        case .actionBudgetExceeded: return "Task exceeded its action budget"
        case .preconditionFailed(let message): return "Task precondition failed: \(message)"
        case .postconditionFailed(let message): return "Task postcondition failed: \(message)"
        case .indeterminate(let message): return "Task outcome is indeterminate: \(message)"
        case .checkpointUnavailable(let message): return "Task checkpoint is unavailable: \(message)"
        case .blocked(let message): return "Task is blocked: \(message)"
        }
    }
}

private struct TaskPlanDigestPayload: Codable {
    let plan: TaskPlan
    let ephemeralInputs: [String: String]
}
