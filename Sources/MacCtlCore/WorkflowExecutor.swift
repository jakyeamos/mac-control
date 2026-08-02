import AppKit
import Foundation

public enum WorkflowExecutionError: Error, LocalizedError {
    case invalidWorkflow([String])
    case missingParameter(String)
    case unsupportedAction(ActionKind)
    case assertionFailed(String)
    case blocked(String)
    case unsafeInput(String)
    case backgroundUnsupported(String)
    case focusChanged(expected: String, actual: String)
    case mirroringDrivingLeaseRequired

    public var errorDescription: String? {
        switch self {
        case .invalidWorkflow(let errors):
            return "Workflow is invalid: \(errors.joined(separator: "; "))"
        case .missingParameter(let name):
            return "Missing workflow parameter: \(name)"
        case .unsupportedAction(let action):
            return "Unsupported workflow action: \(action.rawValue)"
        case .assertionFailed(let message):
            return "Workflow assertion failed: \(message)"
        case .blocked(let message):
            return "Workflow blocked: \(message)"
        case .unsafeInput(let message):
            return "Unsafe workflow input: \(message)"
        case .backgroundUnsupported(let message):
            return "Background workflow is unsupported: \(message)"
        case .focusChanged(let expected, let actual):
            return "Background workflow changed foreground focus from \(expected) to \(actual)"
        case .mirroringDrivingLeaseRequired:
            return "An explicit user-held iPhone Mirroring driving lease is required before synthetic navigation"
        }
    }
}

public final class WorkflowExecutor {
    private let appController: AppController
    private let accessibilityController: AccessibilityController
    private let inputController: InputController
    private let captureController: CaptureController
    private let iphoneController: IPhoneMirroringController

    public init(
        appController: AppController = AppController(),
        accessibilityController: AccessibilityController = AccessibilityController(),
        inputController: InputController = InputController(),
        captureController: CaptureController? = nil,
        iphoneController: IPhoneMirroringController? = nil
    ) {
        self.appController = appController
        self.accessibilityController = accessibilityController
        self.inputController = inputController
        self.captureController = captureController ?? CaptureController(appController: appController)
        self.iphoneController = iphoneController ?? IPhoneMirroringController(
            appController: appController,
            captureController: self.captureController,
            inputController: inputController
        )
    }

    public func execute(
        _ workflow: WorkflowSpec,
        ephemeralInputs: [String: String] = [:],
        mirroringDrivingLease: IPhoneMirroringDrivingLease? = nil
    ) throws -> ExecutionReport {
        let validation = WorkflowRegistry().validate(workflow)
        guard validation.valid else { throw WorkflowExecutionError.invalidWorkflow(validation.errors) }
        if requiresMirroringDrivingLease(workflow) {
            try requireDrivingLease(mirroringDrivingLease)
        }

        let runID = UUID().uuidString
        let initialForeground = workflow.focusPolicy == .background
            ? appController.foregroundApplication()
            : nil
        var evidence: [Evidence] = []
        var result: [String: JSONValue] = [:]
        var completedActions = 0
        var targetProcessIDs = Set<pid_t>()

        for action in workflow.actions {
            let actionResult = try execute(
                action,
                ephemeralInputs: ephemeralInputs,
                focusPolicy: workflow.focusPolicy,
                mirroringDrivingLease: mirroringDrivingLease
            )
            evidence.append(contentsOf: actionResult.evidence)
            for (key, value) in actionResult.result {
                result[key] = value
            }
            targetProcessIDs.formUnion(actionResult.targetProcessIDs)
            completedActions += 1
            if workflow.focusPolicy == .background {
                try ensureFocusPreserved(initialForeground)
            }
        }

        if workflow.recipe == "iphone-open-tinder" {
            let match = try iphoneController.openMirroredApp(
                "Tinder",
                drivingLease: mirroringDrivingLease
            )
            result["mirrored_app"] = .string("Tinder")
            evidence.append(Evidence(
                kind: "mirroring_driving_lease",
                message: "Synthetic Mirroring navigation ran under an active user-held exclusive driving lease",
                source: "macctld"
            ))
            evidence.append(Evidence(
                kind: "ocr_anchor",
                message: "Located the requested mirrored app using an on-demand OCR anchor",
                source: "iPhone Mirroring",
                metadata: [
                    "selector_tier": .number(Double(SelectorTier.visual.rawValue)),
                    "anchor_width": .number(Double(match.bounds.width)),
                    "anchor_height": .number(Double(match.bounds.height))
                ]
            ))
            do {
                _ = try iphoneController.verifyMirroredAppVisible("Tinder")
            } catch IPhoneMirroringError.appNotVisible {
                _ = try iphoneController.verifyMirroredAppForeground("Tinder")
            }
            evidence.append(Evidence(
                kind: "assertion",
                message: "Verified the requested mirrored app remains foregrounded in iPhone Mirroring",
                source: "iPhone Mirroring"
            ))
        }

        if workflow.recipe == "approval-smoke" {
            evidence.append(Evidence(
                kind: "approval_probe",
                message: "Completed a no-input approval probe without changing an external surface",
                source: "macctl"
            ))
        }

        for assertion in workflow.assertions {
            try verify(assertion, focusPolicy: workflow.focusPolicy)
            evidence.append(Evidence(
                kind: "assertion",
                message: "Assertion passed: \(assertion.kind)",
                source: assertion.surface.rawValue
            ))
        }

        if workflow.focusPolicy == .background {
            try ensureFocusPreserved(initialForeground)
            let finalForeground = appController.foregroundApplication()
            evidence.append(Evidence(
                kind: "focus_guard",
                message: "Foreground application was preserved for the background workflow",
                source: "macctl",
                metadata: [
                    "policy": .string(workflow.focusPolicy.rawValue),
                    "initial_foreground": .string(applicationLabel(initialForeground)),
                    "final_foreground": .string(applicationLabel(finalForeground))
                ]
            ))
        }

        result["run_id"] = .string(runID)
        result["focus_policy"] = .string(workflow.focusPolicy.rawValue)

        return ExecutionReport(
            workflowID: workflow.id,
            completedActions: completedActions,
            evidence: evidence,
            result: result,
            runID: runID,
            focusPolicy: workflow.focusPolicy,
            targetProcessIDs: targetProcessIDs.sorted()
        )
    }

    private struct ActionResult {
        let evidence: [Evidence]
        let result: [String: JSONValue]
        let targetProcessIDs: [pid_t]

        init(
            evidence: [Evidence],
            result: [String: JSONValue],
            targetProcessIDs: [pid_t] = []
        ) {
            self.evidence = evidence
            self.result = result
            self.targetProcessIDs = targetProcessIDs
        }
    }

    private func execute(
        _ action: ActionSpec,
        ephemeralInputs: [String: String],
        focusPolicy: FocusPolicy,
        mirroringDrivingLease: IPhoneMirroringDrivingLease?
    ) throws -> ActionResult {
        try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
        switch action.kind {
        case .launchApp:
            let app = try parameter(action, name: "app")
            let info = try appController.open(app, focusPolicy: focusPolicy)
            return ActionResult(
                evidence: [Evidence(kind: "app", message: "Application opened", source: info.name)],
                result: ["app": .string(info.name)],
                targetProcessIDs: info.processID.map { [$0] } ?? []
            )
        case .activateWindow:
            if focusPolicy == .background {
                throw WorkflowExecutionError.backgroundUnsupported("activateWindow would change foreground focus")
            }
            let app = try parameter(action, name: "app")
            let info = try appController.activate(app)
            return ActionResult(
                evidence: [Evidence(kind: "window", message: "Application activated", source: info.name)],
                result: ["app": .string(info.name)]
            )
        case .click:
            return try executeClick(
                action,
                focusPolicy: focusPolicy,
                mirroringDrivingLease: mirroringDrivingLease
            )
        case .type:
            let text = try ephemeralText(action, inputs: ephemeralInputs)
            if focusPolicy == .background {
                guard action.surface == .macApp,
                      let selector = action.selector,
                      selector.tier == .accessibility else {
                    throw WorkflowExecutionError.backgroundUnsupported(
                        "type requires an Accessibility selector on a macOS app"
                    )
                }
                let pid = try requiredTargetPID(for: action)
                _ = try accessibilityController.setValue(pid: pid, selector: selector, value: text)
                return ActionResult(
                    evidence: [Evidence(
                        kind: "input",
                        message: "Ephemeral text was set through the target Accessibility element",
                        metadata: [
                            "focus_policy": .string(focusPolicy.rawValue),
                            "selector_tier": .number(Double(SelectorTier.accessibility.rawValue))
                        ]
                    )],
                    result: ["typed": .bool(true)],
                    targetProcessIDs: [pid]
                )
            }
            try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
            try inputController.type(text)
            return ActionResult(
                evidence: [Evidence(kind: "input", message: "Ephemeral text was typed")],
                result: ["typed": .bool(true)]
            )
        case .key:
            let key = try parameter(action, name: "key")
            if focusPolicy == .background {
                let pid = try requiredTargetPID(for: action)
                try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
                try inputController.key(key, toProcess: pid)
                return ActionResult(
                    evidence: [Evidence(
                        kind: "input",
                        message: "Keyboard key was sent to the target process",
                        metadata: ["focus_policy": .string(focusPolicy.rawValue)]
                    )],
                    result: ["key": .string(key)],
                    targetProcessIDs: [pid]
                )
            }
            try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
            try inputController.key(key)
            return ActionResult(
                evidence: [Evidence(kind: "input", message: "Keyboard key was sent")],
                result: ["key": .string(key)]
            )
        case .scroll:
            if focusPolicy == .background {
                throw WorkflowExecutionError.backgroundUnsupported("scroll uses global mouse input")
            }
            let direction = try parameter(action, name: "direction")
            let amount = action.parameters["amount"]?.intValue ?? 3
            try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
            try inputController.scroll(amount: Int32(amount), direction: direction)
            return ActionResult(
                evidence: [Evidence(kind: "input", message: "Scroll event was sent")],
                result: ["direction": .string(direction), "amount": .number(Double(amount))]
            )
        case .waitFor:
            let seconds = min(max(action.parameters["seconds"]?.doubleValue ?? 0.2, 0), 60)
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            return ActionResult(
                evidence: [Evidence(kind: "wait", message: "Wait condition elapsed")],
                result: ["seconds": .number(seconds)]
            )
        case .capture:
            if focusPolicy == .background {
                guard action.surface == .macApp, hasAppParameter(action.parameters) else {
                    throw WorkflowExecutionError.backgroundUnsupported(
                        "background capture requires a named macOS app"
                    )
                }
            }
            let app = action.parameters["app"]?.stringValue
            let frame = try captureController.capture(surface: action.surface, app: app)
            return ActionResult(
                evidence: [Evidence(
                    kind: "capture",
                    message: "Captured an ephemeral frame for this operation",
                    source: frame.source,
                    metadata: [
                        "width": .number(Double(frame.image.width)),
                        "height": .number(Double(frame.image.height))
                    ]
                )],
                result: ["captured": .bool(true)]
            )
        case .ocr:
            if focusPolicy == .background {
                guard action.surface == .macApp, hasAppParameter(action.parameters) else {
                    throw WorkflowExecutionError.backgroundUnsupported(
                        "background OCR requires a named macOS app"
                    )
                }
            }
            let app = action.parameters["app"]?.stringValue
            let frame = try captureController.capture(surface: action.surface, app: app)
            let ocr = try captureController.ocr(frame)
            return ActionResult(
                evidence: [Evidence(
                    kind: "ocr",
                    message: "Vision OCR completed in memory",
                    source: frame.source,
                    metadata: ["match_count": .number(Double(ocr.matches.count))]
                )],
                result: ["match_count": .number(Double(ocr.matches.count))]
            )
        case .assert:
            try verifyActionAssertion(action, focusPolicy: focusPolicy)
            return ActionResult(
                evidence: [Evidence(kind: "assertion", message: "Inline assertion passed")],
                result: ["assertion": .bool(true)]
            )
        case .adapter:
            throw WorkflowExecutionError.unsupportedAction(.adapter)
        }
    }

    private func executeClick(
        _ action: ActionSpec,
        focusPolicy: FocusPolicy,
        mirroringDrivingLease: IPhoneMirroringDrivingLease?
    ) throws -> ActionResult {
        try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
        if focusPolicy == .background {
            guard action.surface == .macApp,
                  let selector = action.selector,
                  selector.tier == .accessibility else {
                throw WorkflowExecutionError.backgroundUnsupported(
                    "click requires an Accessibility selector on a macOS app"
                )
            }
            let pid = try requiredTargetPID(for: action)
            try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
            let bounds = try accessibilityController.press(pid: pid, selector: selector)
            return ActionResult(
                evidence: [Evidence(
                    kind: "click",
                    message: "Clicked an Accessibility element in the target process",
                    metadata: [
                        "focus_policy": .string(focusPolicy.rawValue),
                        "selector_tier": .number(Double(SelectorTier.accessibility.rawValue)),
                        "x": .number(Double(bounds.midX)),
                        "y": .number(Double(bounds.midY))
                    ]
                )],
                result: ["selector_tier": .number(Double(SelectorTier.accessibility.rawValue))],
                targetProcessIDs: [pid]
            )
        }

        if let selector = action.selector {
            if selector.tier == .accessibility,
               let pid = try targetPID(for: action) {
                try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
                let bounds = try accessibilityController.press(pid: pid, selector: selector)
                return ActionResult(
                    evidence: [Evidence(
                        kind: "click",
                        message: "Clicked an Accessibility element",
                        metadata: [
                            "selector_tier": .number(Double(SelectorTier.accessibility.rawValue)),
                            "x": .number(Double(bounds.midX)),
                            "y": .number(Double(bounds.midY))
                        ]
                    )],
                    result: ["selector_tier": .number(Double(SelectorTier.accessibility.rawValue))],
                    targetProcessIDs: [pid]
                )
            }
            if selector.tier == .visual {
                let app = action.parameters["app"]?.stringValue
                let frame = try captureController.capture(surface: action.surface, app: app)
                if let text = selector.containsText {
                    let ocr = try captureController.ocr(frame)
                    if let match = ocr.matches.first(where: { $0.text.localizedCaseInsensitiveContains(text) }) {
                        try click(
                            at: CGPoint(x: match.bounds.midX, y: match.bounds.midY),
                            action: action,
                            mirroringDrivingLease: mirroringDrivingLease
                        )
                        return ActionResult(
                            evidence: [Evidence(
                                kind: "click",
                                message: "Clicked an OCR anchor",
                                source: frame.source,
                                metadata: ["selector_tier": .number(Double(SelectorTier.visual.rawValue))]
                            )],
                            result: ["selector_tier": .number(Double(SelectorTier.visual.rawValue))]
                        )
                    }
                }
                if let anchorPath = selector.imageAnchor {
                    let match = try captureController.findImageAnchor(in: frame, path: anchorPath)
                    try click(
                        at: CGPoint(x: match.bounds.midX, y: match.bounds.midY),
                        action: action,
                        mirroringDrivingLease: mirroringDrivingLease
                    )
                    return ActionResult(
                        evidence: [Evidence(
                            kind: "click",
                            message: "Clicked an image anchor",
                            source: frame.source,
                            metadata: [
                                "selector_tier": .number(Double(SelectorTier.visual.rawValue)),
                                "match_score": .number(match.score)
                            ]
                        )],
                        result: ["selector_tier": .number(Double(SelectorTier.visual.rawValue))]
                    )
                }
                throw WorkflowExecutionError.blocked("visual selector was not found")
            }
            if selector.tier == .normalizedCoordinate,
               let x = selector.normalizedX,
               let y = selector.normalizedY {
                let point = try normalizedPoint(for: action, x: x, y: y)
                try click(at: point, action: action, mirroringDrivingLease: mirroringDrivingLease)
                return ActionResult(
                    evidence: [Evidence(
                        kind: "click",
                        message: "Clicked a normalized coordinate fallback",
                        metadata: ["selector_tier": .number(Double(SelectorTier.normalizedCoordinate.rawValue))]
                    )],
                    result: ["selector_tier": .number(Double(SelectorTier.normalizedCoordinate.rawValue))]
                )
            }
            if selector.tier == .rawCoordinate,
               let x = selector.rawX,
               let y = selector.rawY,
               action.parameters["coordinate_mode"]?.stringValue == "raw" {
                try click(
                    at: CGPoint(x: x, y: y),
                    action: action,
                    mirroringDrivingLease: mirroringDrivingLease
                )
                return ActionResult(
                    evidence: [Evidence(
                        kind: "click",
                        message: "Clicked an explicitly marked raw coordinate fallback",
                        metadata: ["selector_tier": .number(Double(SelectorTier.rawCoordinate.rawValue))]
                    )],
                    result: ["selector_tier": .number(Double(SelectorTier.rawCoordinate.rawValue))]
                )
            }
        }
        if let x = action.parameters["x"]?.doubleValue,
           let y = action.parameters["y"]?.doubleValue,
           action.parameters["coordinate_mode"]?.stringValue == "normalized" {
            let point = try normalizedPoint(for: action, x: x, y: y)
            try click(at: point, action: action, mirroringDrivingLease: mirroringDrivingLease)
            return ActionResult(
                evidence: [Evidence(
                    kind: "click",
                    message: "Clicked a normalized coordinate fallback",
                    metadata: ["selector_tier": .number(Double(SelectorTier.normalizedCoordinate.rawValue))]
                )],
                result: ["selector_tier": .number(Double(SelectorTier.normalizedCoordinate.rawValue))]
            )
        }
        throw WorkflowExecutionError.blocked("click has no usable selector")
    }

    private func click(
        at point: CGPoint,
        action: ActionSpec,
        mirroringDrivingLease: IPhoneMirroringDrivingLease?
    ) throws {
        try requireDrivingLeaseIfNeeded(for: action, lease: mirroringDrivingLease)
        try inputController.click(at: point)
    }

    private func requiresMirroringDrivingLease(_ workflow: WorkflowSpec) -> Bool {
        workflow.recipe == "iphone-open-tinder"
            || workflow.actions.contains { action in
                action.surface == .iphoneMirroring && isSyntheticMirroringInput(action.kind)
            }
    }

    private func requireDrivingLeaseIfNeeded(
        for action: ActionSpec,
        lease: IPhoneMirroringDrivingLease?
    ) throws {
        guard action.surface == .iphoneMirroring,
              isSyntheticMirroringInput(action.kind) else { return }
        try requireDrivingLease(lease)
    }

    private func requireDrivingLease(_ lease: IPhoneMirroringDrivingLease?) throws {
        guard let lease else {
            throw WorkflowExecutionError.mirroringDrivingLeaseRequired
        }
        do {
            try lease.requireHeld()
        } catch {
            throw WorkflowExecutionError.mirroringDrivingLeaseRequired
        }
    }

    private func isSyntheticMirroringInput(_ kind: ActionKind) -> Bool {
        switch kind {
        case .click, .type, .key, .scroll:
            return true
        default:
            return false
        }
    }

    private func verify(_ assertion: AssertionSpec, focusPolicy: FocusPolicy) throws {
        switch assertion.kind {
        case "foregroundApp":
            if focusPolicy == .background {
                throw WorkflowExecutionError.backgroundUnsupported("foregroundApp is not a background assertion")
            }
            let actual = appController.foregroundApplication()?.name
            guard let expected = assertion.expected,
                  actual?.caseInsensitiveCompare(expected) == .orderedSame else {
                throw WorkflowExecutionError.assertionFailed(
                    "foreground app was \(actual ?? "unknown"), expected \(assertion.expected ?? "unknown")"
                )
            }
        case "iphoneMirroringForeground":
            if focusPolicy == .background {
                throw WorkflowExecutionError.backgroundUnsupported("iPhone Mirroring requires foreground focus")
            }
            guard iphoneController.state().foreground else {
                throw WorkflowExecutionError.assertionFailed("iPhone Mirroring is not foreground")
            }
        case "ocrContains":
            if focusPolicy == .background {
                guard assertion.surface == .macApp, hasAppParameter(assertion.parameters) else {
                    throw WorkflowExecutionError.backgroundUnsupported(
                        "background OCR requires a named macOS app"
                    )
                }
            }
            guard let expected = assertion.expected else {
                throw WorkflowExecutionError.assertionFailed("ocrContains has no expected text")
            }
            let frame = try captureController.capture(
                surface: assertion.surface,
                app: assertion.parameters["app"]?.stringValue
            )
            let ocr = try captureController.ocr(frame)
            guard ocr.contains(expected) else {
                throw WorkflowExecutionError.assertionFailed("OCR did not contain the expected marker")
            }
        case "elementExists":
            guard let selector = assertion.selector,
                  let pid = try targetPID(
                      surface: assertion.surface,
                      parameters: assertion.parameters,
                      requiresRunning: focusPolicy == .background
                  ) else {
                throw WorkflowExecutionError.assertionFailed("elementExists has no app or selector")
            }
            _ = try accessibilityController.findElement(pid: pid, selector: selector)
        default:
            throw WorkflowExecutionError.assertionFailed("unsupported assertion: \(assertion.kind)")
        }
    }

    private func verifyActionAssertion(
        _ action: ActionSpec,
        focusPolicy: FocusPolicy
    ) throws {
        let kind = action.parameters["condition"]?.stringValue ?? "foregroundApp"
        let assertion = AssertionSpec(
            kind: kind,
            surface: action.surface,
            expected: action.parameters["expected"]?.stringValue,
            selector: action.selector,
            parameters: action.parameters
        )
        try verify(assertion, focusPolicy: focusPolicy)
    }

    private func targetPID(for action: ActionSpec) throws -> pid_t? {
        try targetPID(surface: action.surface, parameters: action.parameters)
    }

    private func requiredTargetPID(for action: ActionSpec) throws -> pid_t {
        guard let pid = try targetPID(
            surface: action.surface,
            parameters: action.parameters,
            requiresRunning: true
        ) else {
            throw WorkflowExecutionError.backgroundUnsupported(
                "the target app is not running; launch it with launchApp first"
            )
        }
        return pid
    }

    private func targetPID(
        surface: SurfaceKind,
        parameters: [String: JSONValue],
        requiresRunning: Bool = false
    ) throws -> pid_t? {
        switch surface {
        case .macDesktop:
            return nil
        case .macApp:
            let app = parameters["app"]?.stringValue
            guard let app else {
                if requiresRunning { return nil }
                return appController.foregroundApplication()?.processID
            }
            let resolved = try appController.resolve(app)
            if requiresRunning, !resolved.isRunning { return nil }
            return resolved.processID
        case .iphoneMirroring:
            return try appController.resolve("iPhone Mirroring").processID
        }
    }

    private func normalizedPoint(for action: ActionSpec, x: Double, y: Double) throws -> CGPoint {
        if action.surface == .macDesktop {
            return try CoordinateMapper.mainDisplayPoint(NormalizedPoint(x: x, y: y))
        }
        if action.surface == .iphoneMirroring,
           let frame = try? captureController.capture(surface: .iphoneMirroring) {
            return try CoordinateMapper.windowPoint(
                normalized: NormalizedPoint(x: x, y: y),
                in: frame.bounds
            )
        }
        if let pid = try targetPID(for: action),
           let bounds = accessibilityController.windowBounds(pid: pid) {
            return try CoordinateMapper.windowPoint(
                normalized: NormalizedPoint(x: x, y: y),
                in: bounds
            )
        }
        return try CoordinateMapper.mainDisplayPoint(NormalizedPoint(x: x, y: y))
    }

    private func ensureFocusPreserved(_ expected: AppInfo?) throws {
        let actual = appController.foregroundApplication()
        guard sameApplication(expected, actual) else {
            throw WorkflowExecutionError.focusChanged(
                expected: applicationLabel(expected),
                actual: applicationLabel(actual)
            )
        }
    }

    private func sameApplication(_ lhs: AppInfo?, _ rhs: AppInfo?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            if let lhsBundleID = lhs.bundleID, let rhsBundleID = rhs.bundleID {
                return lhsBundleID == rhsBundleID
            }
            return lhs.path == rhs.path || lhs.name == rhs.name
        default:
            return false
        }
    }

    private func applicationLabel(_ app: AppInfo?) -> String {
        app?.bundleID ?? app?.path ?? app?.name ?? "none"
    }

    private func parameter(_ action: ActionSpec, name: String) throws -> String {
        guard let value = action.parameters[name]?.stringValue, !value.isEmpty else {
            throw WorkflowExecutionError.missingParameter(name)
        }
        return value
    }

    private func hasAppParameter(_ parameters: [String: JSONValue]) -> Bool {
        guard let app = parameters["app"]?.stringValue else { return false }
        return !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ephemeralText(_ action: ActionSpec, inputs: [String: String]) throws -> String {
        let key = action.parameters["text_key"]?.stringValue ?? "text"
        guard action.parameters["text_source"]?.stringValue == "ephemeral" else {
            throw WorkflowExecutionError.unsafeInput("type actions must use text_source=ephemeral")
        }
        guard let text = inputs[key] else {
            throw WorkflowExecutionError.unsafeInput("ephemeral text input \(key) was not supplied")
        }
        return text
    }
}
