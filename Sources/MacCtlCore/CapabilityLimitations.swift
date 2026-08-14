import Foundation

/// The routing posture for a known Mac Control boundary. These values are
/// guidance for provider selection; they never authorize an action.
public enum MacControlLimitationPosture: String, Codable, Equatable, Hashable {
    case doNotCall = "do_not_call"
    case handoffOnly = "handoff_only"
    case callWithConstraints = "call_with_constraints"
}

/// How certain the repository is about a limitation. `unproven` means the
/// route is not a safe default until the task supplies fresh evidence.
public enum MacControlLimitationState: String, Codable, Equatable, Hashable {
    case knownBoundary = "known_boundary"
    case conditional
    case unproven
}

public struct MacControlLimitation: Codable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let state: MacControlLimitationState
    public let posture: MacControlLimitationPosture
    public let scope: [String]
    public let trigger: String
    public let callWhen: String
    public let doNotCallWhen: String
    public let preferredAlternative: String
    public let verification: String
    public let evidence: [String]

    public init(
        id: String,
        title: String,
        state: MacControlLimitationState,
        posture: MacControlLimitationPosture,
        scope: [String],
        trigger: String,
        callWhen: String,
        doNotCallWhen: String,
        preferredAlternative: String,
        verification: String,
        evidence: [String]
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.posture = posture
        self.scope = scope
        self.trigger = trigger
        self.callWhen = callWhen
        self.doNotCallWhen = doNotCallWhen
        self.preferredAlternative = preferredAlternative
        self.verification = verification
        self.evidence = evidence
    }
}

/// A small, local, versioned preflight contract for choosing whether Mac
/// Control should participate in a task. This is intentionally separate from
/// recent blocker observations: it prevents known dead ends before a live
/// probe or action is attempted.
public struct MacControlLimitationsLedger: Codable, Equatable {
    public let schemaVersion: String
    public let reviewedAt: String
    public let purpose: String
    public let entries: [MacControlLimitation]

    public init(
        schemaVersion: String,
        reviewedAt: String,
        purpose: String,
        entries: [MacControlLimitation]
    ) {
        self.schemaVersion = schemaVersion
        self.reviewedAt = reviewedAt
        self.purpose = purpose
        self.entries = entries
    }

    public static let current = MacControlLimitationsLedger(
        schemaVersion: "mac-control-limitations/v1",
        reviewedAt: "2026-08-14",
        purpose: "Choose the narrowest provider before spending time probing or executing Mac Control",
        entries: [
            MacControlLimitation(
                id: "direct-interface-first",
                title: "A mature direct interface already covers the exact task",
                state: .knownBoundary,
                posture: .doNotCall,
                scope: ["any_task"],
                trigger: "An installed, healthy CLI, API, typed connector, browser DOM route, or direct preference read performs the exact operation and exposes readback.",
                callWhen: "Use Mac Control only when that interface does not cover the exact visible mutation or native UI boundary.",
                doNotCallWhen: "Do not invoke Mac Control merely because the task happens on macOS.",
                preferredAlternative: "direct_interface",
                verification: "The owning provider returns its own exact result and postcondition.",
                evidence: ["skills/mac-control/SKILL.md", ".agents/context/architecture.md"]
            ),
            MacControlLimitation(
                id: "rendered-web-content",
                title: "Rendered webpage content belongs to the browser provider",
                state: .knownBoundary,
                posture: .doNotCall,
                scope: ["web_content", "browser_page", "tab", "frame"],
                trigger: "The target is DOM/page content inside a browser tab, frame, or web application.",
                callWhen: "Use Mac Control only for browser chrome, native menus, or an OS dialog around the page.",
                doNotCallWhen: "Do not activate the browser or retry control.perform to reach ordinary webpage content.",
                preferredAlternative: "browser_connector",
                verification: "The browser provider owns connector health, tab/frame identity, dispatch, and DOM readback.",
                evidence: ["AGENTS.md", "skills/mac-control/SKILL.md", ".agents/context/architecture.md"]
            ),
            MacControlLimitation(
                id: "no-universal-fallback-ladder",
                title: "There is no safe universal Accessibility-to-keyboard-to-visual fallback",
                state: .knownBoundary,
                posture: .callWithConstraints,
                scope: ["route_selection", "fallback", "verification"],
                trigger: "A route is stale, unmeasured, ambiguous, missing an oracle, or fails after dispatch may have happened.",
                callWhen: "Call Mac Control only with a fresh task/app/target route or an explicitly declared route and independent postcondition.",
                doNotCallWhen: "Do not spend time running broad audits or replaying another route to manufacture a fallback after an indeterminate dispatch.",
                preferredAlternative: "fresh_provider_or_computer_use_handoff",
                verification: "The selected provider returns a task-specific verified outcome or a typed handoff with fresh-state requirements.",
                evidence: ["skills/mac-control/SKILL.md", "skills/mac-control/references/routing.md", ".agents/context/failure-modes.md"]
            ),
            MacControlLimitation(
                id: "semantic-scroll-without-verified-viewport",
                title: "Semantic scroll needs a unique container and observed structural change",
                state: .conditional,
                posture: .handoffOnly,
                scope: ["semantic_scroll", "scroll", "accessibility"],
                trigger: "No unique AXScrollArea, directional action, or bounded viewport readback is available.",
                callWhen: "Call native semantic scroll only when the container is uniquely addressed and the viewport change can be verified.",
                doNotCallWhen: "Do not retry scroll after possible dispatch or treat a successful native return as proof of movement.",
                preferredAlternative: "computer_use_fresh_state",
                verification: "Compare bounded structural viewport metadata after one dispatch; otherwise hand off with a fresh state.",
                evidence: ["skills/mac-control/SKILL.md", ".agents/context/failure-modes.md"]
            ),
            MacControlLimitation(
                id: "presentation-only-accessibility-row",
                title: "A presentation-only Accessibility row is not an activation route",
                state: .knownBoundary,
                posture: .handoffOnly,
                scope: ["system_settings", "accessibility", "native_row"],
                trigger: "A System Settings row exposes presentation metadata but no stable title, unique target, or AXPress-capable control.",
                callWhen: "Use a bounded audit to describe the boundary, then hand off to Computer Use or another provider with fresh state.",
                doNotCallWhen: "Do not replay control.perform, widen to a focused row, or infer activation from AXShowDefaultUI/AXShowAlternateUI.",
                preferredAlternative: "computer_use_fresh_state",
                verification: "The receiving provider verifies the selected pane or setting after dispatch.",
                evidence: ["skills/mac-control/SKILL.md", "skills/mac-control/references/routing.md"]
            ),
            MacControlLimitation(
                id: "direct-background-control",
                title: "Direct app-level background mutation is unsupported",
                state: .conditional,
                posture: .callWithConstraints,
                scope: ["background", "focus_preservation", "native_app_ui"],
                trigger: "The unrelated foreground app must remain untouched while one named app is mutated.",
                callWhen: "Use the named task route or action.resolve/action.run front door with exact PID, instance, window, selector, and desired-state readback.",
                doNotCallWhen: "Do not use app-level control.perform, global input, activation, ambiguous selectors, or an unverified background fallback.",
                preferredAlternative: "task_run_or_action_front_door",
                verification: "The desired state passes and the unrelated foreground PID remains unchanged.",
                evidence: ["AGENTS.md", "skills/mac-control/SKILL.md", ".agents/context/architecture.md"]
            ),
            MacControlLimitation(
                id: "exact-keyboard-input",
                title: "Exact keyboard input is a narrow foreground task route",
                state: .conditional,
                posture: .callWithConstraints,
                scope: ["keyboard", "sensitive_input", "foreground"],
                trigger: "The task requires keystrokes or private text rather than a typed, semantic, or browser-owned operation.",
                callWhen: "Use only an approved foreground task.run key step with exact process/instance/window identity, lease, focus oracles, and an exact-window postcondition.",
                doNotCallWhen: "Do not send raw keys, private text, or background keyboard input through an app-level fallback.",
                preferredAlternative: "typed_connector_or_exact_task_run",
                verification: "NSWorkspace frontmost PID, AX focused-window digest, lease, and exact-window element postcondition all agree.",
                evidence: ["AGENTS.md", "skills/mac-control/SKILL.md", ".agents/context/failure-modes.md"]
            ),
            MacControlLimitation(
                id: "visual-or-coordinate-only-target",
                title: "Visual and coordinate routes are opt-in, not an implicit fallback",
                state: .conditional,
                posture: .callWithConstraints,
                scope: ["visual", "coordinate", "pointer", "drag"],
                trigger: "The target can only be described by pixels, OCR, raw coordinates, pointer motion, or drag geometry.",
                callWhen: "Call only with explicit task-manifest opt-in, fresh state, bounded authority, and a verifiable postcondition.",
                doNotCallWhen: "Do not silently widen a semantic failure into visual or coordinate input.",
                preferredAlternative: "computer_use_or_task_manifest_route",
                verification: "The chosen visual/coordinate provider verifies the target-specific state after dispatch.",
                evidence: ["skills/mac-control/SKILL.md", "skills/mac-control/references/routing.md"]
            ),
            MacControlLimitation(
                id: "unregistered-development-process",
                title: "A bare development executable is not an addressable app",
                state: .knownBoundary,
                posture: .doNotCall,
                scope: ["development", "app_bind", "accessibility"],
                trigger: "Process discovery succeeds but the exact PID does not expose a registered AXApplication root.",
                callWhen: "Use a real registered .app through app open, then rediscover and bind its exact PID.",
                doNotCallWhen: "Do not retry by app name, widen to another PID, or treat daemon health and permissions as AX addressability.",
                preferredAlternative: "registered_app_bundle",
                verification: "The exact registered app PID exposes the expected AXApplication root before inspection or input.",
                evidence: ["AGENTS.md", "skills/mac-control/SKILL.md", ".agents/context/failure-modes.md"]
            ),
            MacControlLimitation(
                id: "read-only-settings-query",
                title: "Direct preference reads should not pay a Mac Control preflight cost",
                state: .knownBoundary,
                posture: .doNotCall,
                scope: ["read_only", "macos_settings", "preference"],
                trigger: "The requested answer is a read-only macOS preference or status available from a direct command.",
                callWhen: "Use Mac Control only if the answer requires visible UI interaction or the direct provider does not expose it.",
                doNotCallWhen: "Do not run doctor, capabilities, or control status merely to answer a direct preference question.",
                preferredAlternative: "direct_preference_read",
                verification: "The direct command returns the value; missing or unreadable output remains unknown.",
                evidence: ["skills/mac-control/SKILL.md", "skills/mac-control/references/routing.md"]
            )
        ]
    )
}
