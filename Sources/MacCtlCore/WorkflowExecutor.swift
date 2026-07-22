import AppKit
import Foundation

public enum WorkflowExecutionError: Error, LocalizedError {
    case invalidWorkflow([String])
    case missingParameter(String)
    case unsupportedAction(ActionKind)
    case assertionFailed(String)
    case blocked(String)
    case unsafeInput(String)

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
        ephemeralInputs: [String: String] = [:]
    ) throws -> ExecutionReport {
        let validation = WorkflowRegistry().validate(workflow)
        guard validation.valid else { throw WorkflowExecutionError.invalidWorkflow(validation.errors) }
        var evidence: [Evidence] = []
        var result: [String: JSONValue] = [:]
        var completedActions = 0

        for action in workflow.actions {
            let actionEvidence = try execute(action, ephemeralInputs: ephemeralInputs)
            evidence.append(contentsOf: actionEvidence.evidence)
            for (key, value) in actionEvidence.result {
                result[key] = value
            }
            completedActions += 1
        }

        if workflow.recipe == "iphone-open-tinder" {
            let match = try iphoneController.openMirroredApp("Tinder")
            result["mirrored_app"] = .string("Tinder")
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
            _ = try iphoneController.verifyMirroredAppVisible("Tinder")
            evidence.append(Evidence(
                kind: "assertion",
                message: "Verified the mirrored app remains visible in iPhone Mirroring",
                source: "iPhone Mirroring"
            ))
        }

        for assertion in workflow.assertions {
            try verify(assertion)
            evidence.append(Evidence(
                kind: "assertion",
                message: "Assertion passed: \(assertion.kind)",
                source: assertion.surface.rawValue
            ))
        }

        return ExecutionReport(
            workflowID: workflow.id,
            completedActions: completedActions,
            evidence: evidence,
            result: result
        )
    }

    private struct ActionResult {
        let evidence: [Evidence]
        let result: [String: JSONValue]
    }

    private func execute(_ action: ActionSpec, ephemeralInputs: [String: String]) throws -> ActionResult {
        switch action.kind {
        case .launchApp:
            let app = try parameter(action, name: "app")
            let info = try appController.open(app)
            return ActionResult(
                evidence: [Evidence(kind: "app", message: "Application opened", source: info.name)],
                result: ["app": .string(info.name)]
            )
        case .activateWindow:
            let app = try parameter(action, name: "app")
            let info = try appController.activate(app)
            return ActionResult(
                evidence: [Evidence(kind: "window", message: "Application activated", source: info.name)],
                result: ["app": .string(info.name)]
            )
        case .click:
            return try executeClick(action)
        case .type:
            let text = try ephemeralText(action, inputs: ephemeralInputs)
            try inputController.type(text)
            return ActionResult(
                evidence: [Evidence(kind: "input", message: "Ephemeral text was typed")],
                result: ["typed": .bool(true)]
            )
        case .key:
            let key = try parameter(action, name: "key")
            try inputController.key(key)
            return ActionResult(
                evidence: [Evidence(kind: "input", message: "Keyboard key was sent")],
                result: ["key": .string(key)]
            )
        case .scroll:
            let direction = try parameter(action, name: "direction")
            let amount = action.parameters["amount"]?.intValue ?? 3
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
            try verifyActionAssertion(action)
            return ActionResult(
                evidence: [Evidence(kind: "assertion", message: "Inline assertion passed")],
                result: ["assertion": .bool(true)]
            )
        }
    }

    private func executeClick(_ action: ActionSpec) throws -> ActionResult {
        if let selector = action.selector {
            if selector.tier == .accessibility,
               let pid = try targetPID(for: action) {
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
                    result: ["selector_tier": .number(Double(SelectorTier.accessibility.rawValue))]
                )
            }
            if selector.tier == .visual {
                let app = action.parameters["app"]?.stringValue
                let frame = try captureController.capture(surface: action.surface, app: app)
                if let text = selector.containsText {
                    let ocr = try captureController.ocr(frame)
                    if let match = ocr.matches.first(where: { $0.text.localizedCaseInsensitiveContains(text) }) {
                        try inputController.click(at: CGPoint(x: match.bounds.midX, y: match.bounds.midY))
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
                    try inputController.click(at: CGPoint(x: match.bounds.midX, y: match.bounds.midY))
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
                try inputController.click(at: point)
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
                try inputController.click(at: CGPoint(x: x, y: y))
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
            try inputController.click(at: point)
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

    private func verify(_ assertion: AssertionSpec) throws {
        switch assertion.kind {
        case "foregroundApp":
            let actual = appController.foregroundApplication()?.name
            guard let expected = assertion.expected,
                  actual?.caseInsensitiveCompare(expected) == .orderedSame else {
                throw WorkflowExecutionError.assertionFailed(
                    "foreground app was \(actual ?? "unknown"), expected \(assertion.expected ?? "unknown")"
                )
            }
        case "iphoneMirroringForeground":
            guard iphoneController.state().foreground else {
                throw WorkflowExecutionError.assertionFailed("iPhone Mirroring is not foreground")
            }
        case "ocrContains":
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
                  let pid = try targetPID(surface: assertion.surface, parameters: assertion.parameters) else {
                throw WorkflowExecutionError.assertionFailed("elementExists has no app or selector")
            }
            _ = try accessibilityController.findElement(pid: pid, selector: selector)
        default:
            throw WorkflowExecutionError.assertionFailed("unsupported assertion: \(assertion.kind)")
        }
    }

    private func verifyActionAssertion(_ action: ActionSpec) throws {
        let kind = action.parameters["condition"]?.stringValue ?? "foregroundApp"
        let assertion = AssertionSpec(
            kind: kind,
            surface: action.surface,
            expected: action.parameters["expected"]?.stringValue,
            selector: action.selector,
            parameters: action.parameters
        )
        try verify(assertion)
    }

    private func targetPID(for action: ActionSpec) throws -> pid_t? {
        try targetPID(surface: action.surface, parameters: action.parameters)
    }

    private func targetPID(surface: SurfaceKind, parameters: [String: JSONValue]) throws -> pid_t? {
        switch surface {
        case .macDesktop:
            return nil
        case .macApp:
            let app = parameters["app"]?.stringValue
            guard let app else { return appController.foregroundApplication()?.processID }
            return try appController.resolve(app).processID
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

    private func parameter(_ action: ActionSpec, name: String) throws -> String {
        guard let value = action.parameters[name]?.stringValue, !value.isEmpty else {
            throw WorkflowExecutionError.missingParameter(name)
        }
        return value
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
