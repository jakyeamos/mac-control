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

/// Confidence supplied with an observation. This is metadata for review, not
/// a promotion mechanism; every submitted candidate remains unproven.
public enum MacControlLimitationProposalConfidence: String, Codable, Equatable, Hashable {
    case low
    case medium
    case high
}

/// The stdin contract for recording a newly observed boundary. The input is
/// deliberately smaller than the persisted proposal: timestamps, identity,
/// source, and candidate state are owned by the local store.
public struct MacControlLimitationProposalInput: Codable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let posture: MacControlLimitationPosture
    public let scope: [String]
    public let trigger: String
    public let callWhen: String
    public let doNotCallWhen: String
    public let preferredAlternative: String
    public let verification: String
    public let evidence: [String]
    public let confidence: MacControlLimitationProposalConfidence
    public let notes: String?

    public init(
        id: String,
        title: String,
        posture: MacControlLimitationPosture,
        scope: [String],
        trigger: String,
        callWhen: String,
        doNotCallWhen: String,
        preferredAlternative: String,
        verification: String,
        evidence: [String],
        confidence: MacControlLimitationProposalConfidence = .medium,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.posture = posture
        self.scope = scope
        self.trigger = trigger
        self.callWhen = callWhen
        self.doNotCallWhen = doNotCallWhen
        self.preferredAlternative = preferredAlternative
        self.verification = verification
        self.evidence = evidence
        self.confidence = confidence
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case posture
        case scope
        case trigger
        case callWhen = "call_when"
        case doNotCallWhen = "do_not_call_when"
        case preferredAlternative = "preferred_alternative"
        case verification
        case evidence
        case confidence
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.posture = try container.decode(MacControlLimitationPosture.self, forKey: .posture)
        self.scope = try container.decode([String].self, forKey: .scope)
        self.trigger = try container.decode(String.self, forKey: .trigger)
        self.callWhen = try container.decode(String.self, forKey: .callWhen)
        self.doNotCallWhen = try container.decode(String.self, forKey: .doNotCallWhen)
        self.preferredAlternative = try container.decode(String.self, forKey: .preferredAlternative)
        self.verification = try container.decode(String.self, forKey: .verification)
        self.evidence = try container.decode([String].self, forKey: .evidence)
        self.confidence = try container.decodeIfPresent(
            MacControlLimitationProposalConfidence.self,
            forKey: .confidence
        ) ?? .medium
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(posture, forKey: .posture)
        try container.encode(scope, forKey: .scope)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(callWhen, forKey: .callWhen)
        try container.encode(doNotCallWhen, forKey: .doNotCallWhen)
        try container.encode(preferredAlternative, forKey: .preferredAlternative)
        try container.encode(verification, forKey: .verification)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

/// An immutable, local candidate created by an agent observation. The
/// canonical ledger remains source-controlled and reviewed; this record is a
/// queue for review, not a dynamic routing override.
public struct MacControlLimitationProposal: Codable, Equatable, Hashable {
    public static let schemaVersionValue = "mac-control-limitation-proposal/v1"

    public let schemaVersion: String
    public let proposalID: String
    public let submittedAt: Date
    public let source: String
    public let confidence: MacControlLimitationProposalConfidence
    public let candidate: MacControlLimitation
    public let notes: String?

    public init(
        proposalID: String,
        submittedAt: Date,
        source: String,
        confidence: MacControlLimitationProposalConfidence,
        candidate: MacControlLimitation,
        notes: String?
    ) {
        self.schemaVersion = Self.schemaVersionValue
        self.proposalID = proposalID
        self.submittedAt = submittedAt
        self.source = source
        self.confidence = confidence
        self.candidate = candidate
        self.notes = notes
    }
}

/// Machine-readable discovery metadata for the contribution lane. These
/// commands are local-only and do not appear as daemon execution methods.
public struct MacControlLimitationsProposalSurface: Codable, Equatable, Hashable {
    public let proposeCommand: String
    public let listCommand: String
    public let storage: String
    public let candidateState: String
    public let appendOnly: Bool
    public let executionAuthority: Bool
    public let promotion: String

    public static let current = MacControlLimitationsProposalSurface(
        proposeCommand: "macctl control limitations propose --stdin --json",
        listCommand: "macctl control limitations proposals --json",
        storage: "owner_only_local_append_only",
        candidateState: MacControlLimitationState.unproven.rawValue,
        appendOnly: true,
        executionAuthority: false,
        promotion: "reviewed_source_change"
    )

    public init(
        proposeCommand: String,
        listCommand: String,
        storage: String,
        candidateState: String,
        appendOnly: Bool,
        executionAuthority: Bool,
        promotion: String
    ) {
        self.proposeCommand = proposeCommand
        self.listCommand = listCommand
        self.storage = storage
        self.candidateState = candidateState
        self.appendOnly = appendOnly
        self.executionAuthority = executionAuthority
        self.promotion = promotion
    }
}

public struct MacControlLimitationsProposalSubmission: Codable, Equatable, Hashable {
    public static let schemaVersionValue = "mac-control-limitation-proposal-response/v1"

    public let schemaVersion: String
    public let status: String
    public let executionAuthority: Bool
    public let proposal: MacControlLimitationProposal

    public init(proposal: MacControlLimitationProposal) {
        self.schemaVersion = Self.schemaVersionValue
        self.status = "candidate"
        self.executionAuthority = false
        self.proposal = proposal
    }
}

public struct MacControlLimitationsProposalList: Codable, Equatable, Hashable {
    public static let schemaVersionValue = "mac-control-limitation-proposals/v1"

    public let schemaVersion: String
    public let proposals: [MacControlLimitationProposal]
    public let count: Int
    public let ownerOnlyStorage: Bool
    public let appendOnly: Bool
    public let executionAuthority: Bool

    public init(proposals: [MacControlLimitationProposal], ownerOnlyStorage: Bool) {
        self.schemaVersion = Self.schemaVersionValue
        self.proposals = proposals
        self.count = proposals.count
        self.ownerOnlyStorage = ownerOnlyStorage
        self.appendOnly = true
        self.executionAuthority = false
    }
}

public enum MacControlLimitationProposalStoreError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case capacityReached(Int)
    case duplicateProposalID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return "Invalid limitation proposal: \(message)"
        case .capacityReached(let maximum):
            return "Limitation proposal store reached its maximum of \(maximum) candidates"
        case .duplicateProposalID(let proposalID):
            return "Limitation proposal ID already exists: \(proposalID)"
        }
    }
}

/// Persists agent observations without allowing them to rewrite the reviewed
/// ledger. One owner-only JSON file is created per submission; there is no
/// update or delete operation, and list reads fail closed on malformed data.
public final class MacControlLimitationProposalStore {
    public static let maximumProposalCount = 512

    private let directory: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let idGenerator: () -> String

    public init(
        directory: URL = MacCtlPaths.limitationProposalsDirectory,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
        self.idGenerator = idGenerator
    }

    public func append(_ input: MacControlLimitationProposalInput) throws -> MacControlLimitationProposal {
        try validate(input)
        return try OwnerOnlyFileStore.withExclusiveDirectoryLock(directory, fileManager: fileManager) {
            let existingURLs = try proposalURLs()
            guard existingURLs.count < Self.maximumProposalCount else {
                throw MacControlLimitationProposalStoreError.capacityReached(Self.maximumProposalCount)
            }

            let proposalID = idGenerator()
            guard proposalID.count <= 80,
                  proposalID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
                throw MacControlLimitationProposalStoreError.invalidInput("generated proposal ID is not path-safe")
            }
            let destination = directory.appendingPathComponent("\(proposalID).json")
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw MacControlLimitationProposalStoreError.duplicateProposalID(proposalID)
            }

            let candidate = MacControlLimitation(
                id: input.id,
                title: input.title,
                state: .unproven,
                posture: input.posture,
                scope: input.scope,
                trigger: input.trigger,
                callWhen: input.callWhen,
                doNotCallWhen: input.doNotCallWhen,
                preferredAlternative: input.preferredAlternative,
                verification: input.verification,
                evidence: input.evidence
            )
            let proposal = MacControlLimitationProposal(
                proposalID: proposalID,
                submittedAt: now(),
                source: "agent_observation",
                confidence: input.confidence,
                candidate: candidate,
                notes: input.notes
            )
            try OwnerOnlyFileStore.write(JSONCodec.encode(proposal), to: destination, fileManager: fileManager)
            return proposal
        }
    }

    public func list() throws -> [MacControlLimitationProposal] {
        try OwnerOnlyFileStore.withExclusiveDirectoryLock(directory, fileManager: fileManager) {
            try proposalURLs().map { url in
                try JSONCodec.decode(MacControlLimitationProposal.self, from: Data(contentsOf: url))
            }.sorted {
                if $0.submittedAt == $1.submittedAt { return $0.proposalID < $1.proposalID }
                return $0.submittedAt < $1.submittedAt
            }
        }
    }

    public func ownerOnlyStorage() -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o700 else {
            return false
        }
        guard let urls = try? proposalURLs() else { return false }
        return urls.allSatisfy { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let permissions = attributes[.posixPermissions] as? NSNumber else {
                return false
            }
            return permissions.intValue & 0o777 == 0o600
        }
    }

    private func proposalURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func validate(_ input: MacControlLimitationProposalInput) throws {
        try validateIdentifier(input.id, label: "id", maximum: 80)
        try validateText(input.title, label: "title", maximum: 160)
        guard !input.scope.isEmpty, input.scope.count <= 8 else {
            throw MacControlLimitationProposalStoreError.invalidInput("scope must contain 1 to 8 entries")
        }
        for scope in input.scope {
            try validateText(scope, label: "scope entry", maximum: 80)
        }
        try validateText(input.trigger, label: "trigger", maximum: 1_000)
        try validateText(input.callWhen, label: "call_when", maximum: 1_000)
        try validateText(input.doNotCallWhen, label: "do_not_call_when", maximum: 1_000)
        try validateText(input.preferredAlternative, label: "preferred_alternative", maximum: 160)
        try validateText(input.verification, label: "verification", maximum: 1_000)
        guard !input.evidence.isEmpty, input.evidence.count <= 16 else {
            throw MacControlLimitationProposalStoreError.invalidInput("evidence must contain 1 to 16 entries")
        }
        for evidence in input.evidence {
            try validateText(evidence, label: "evidence entry", maximum: 500)
        }
        if let notes = input.notes {
            try validateText(notes, label: "notes", maximum: 1_000)
        }
    }

    private func validateIdentifier(_ value: String, label: String, maximum: Int) throws {
        guard value.count >= 1, value.count <= maximum,
              value.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw MacControlLimitationProposalStoreError.invalidInput(
                "\(label) must be lowercase kebab-case and no longer than \(maximum) characters"
            )
        }
    }

    private func validateText(_ value: String, label: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum else {
            throw MacControlLimitationProposalStoreError.invalidInput(
                "\(label) must be non-empty and no longer than \(maximum) characters"
            )
        }
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
    public let proposalSurface: MacControlLimitationsProposalSurface?
    public let entries: [MacControlLimitation]

    public init(
        schemaVersion: String,
        reviewedAt: String,
        purpose: String,
        entries: [MacControlLimitation],
        proposalSurface: MacControlLimitationsProposalSurface? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.reviewedAt = reviewedAt
        self.purpose = purpose
        self.proposalSurface = proposalSurface
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
        ],
        proposalSurface: MacControlLimitationsProposalSurface.current
    )
}
