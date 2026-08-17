import CryptoKit
import Foundation

public struct FocusSessionPlanEffect: Codable, Equatable {
    public let id: String
    public let title: String
    public let target: String
    public let effect: String
    public let rollback: String
    public let verification: String
    public let risk: RiskLevel

    public init(
        id: String,
        title: String,
        target: String,
        effect: String,
        rollback: String,
        verification: String,
        risk: RiskLevel
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.effect = effect
        self.rollback = rollback
        self.verification = verification
        self.risk = risk
    }
}

public struct FocusSessionPlanPreview: Codable, Equatable {
    public let schemaVersion: String
    public let status: String
    public let executable: Bool
    public let request: String
    public let name: String
    public let fixtureID: String
    public let effects: [FocusSessionPlanEffect]
    public let planDigest: String
    public let blockedBy: [String]

    public init(
        request: String,
        name: String,
        fixtureID: String,
        effects: [FocusSessionPlanEffect],
        planDigest: String,
        blockedBy: [String]
    ) {
        self.schemaVersion = "macctl-focus-session-plan-preview/v2"
        self.status = "ready"
        self.executable = true
        self.request = request
        self.name = name
        self.fixtureID = fixtureID
        self.effects = effects
        self.planDigest = planDigest
        self.blockedBy = blockedBy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status, executable, request, name
        case fixtureID = "fixture_id"
        case effects
        case planDigest = "plan_digest"
        case blockedBy = "blocked_by"
    }
}

public enum FocusSessionPlanError: Error, LocalizedError, Equatable {
    case unsupportedRequest

    public var errorDescription: String? {
        switch self {
        case .unsupportedRequest:
            return "The focus-session composer accepts only: Prepare my research session"
        }
    }
}

public enum FocusSessionPlanComposer {
    public static let canonicalRequest = "Prepare my research session"

    public static func compose(request: String = canonicalRequest) throws -> FocusSessionPlanPreview {
        guard normalize(request) == normalize(canonicalRequest) else {
            throw FocusSessionPlanError.unsupportedRequest
        }

        let effects = [
            FocusSessionPlanEffect(
                id: "open-brief",
                title: "Open the research brief",
                target: "Synthetic Research Brief in Preview",
                effect: "Open the bundled synthetic brief in a visible Preview window",
                rollback: "Close the synthetic brief without saving changes",
                verification: "Read back the fixture identity and visible brief window",
                risk: .reversible
            ),
            FocusSessionPlanEffect(
                id: "open-scratchpad",
                title: "Open the research scratchpad",
                target: "Synthetic Research Scratchpad in TextEdit",
                effect: "Open the bundled synthetic scratchpad in a visible TextEdit window",
                rollback: "Close the synthetic scratchpad without saving changes",
                verification: "Read back the fixture identity and visible scratchpad window",
                risk: .reversible
            ),
            FocusSessionPlanEffect(
                id: "arrange-workspace",
                title: "Arrange the research workspace",
                target: "Preview and TextEdit windows",
                effect: "Place the brief and scratchpad windows in the defined research layout",
                rollback: "Restore both windows to their captured pre-session frames",
                verification: "Read back both window frames against the defined layout targets",
                risk: .reversible
            )
        ]
        let payload = DigestPayload(
            request: canonicalRequest,
            name: "Research focus session",
            fixtureID: "synthetic-research-brief-v1",
            effects: effects
        )
        let digest = try JSONCodec.encode(payload)
        let planDigest = SHA256.hash(data: digest)
            .map { String(format: "%02x", $0) }
            .joined()

        return FocusSessionPlanPreview(
            request: canonicalRequest,
            name: payload.name,
            fixtureID: payload.fixtureID,
            effects: effects,
            planDigest: planDigest,
            blockedBy: []
        )
    }

    /// Produces the exact executable candidate behind the concept preview.
    /// Its three operations accept no caller-controlled path, content, app, or
    /// frame, and every step requires a post-dispatch observer to pass.
    public static func taskPlan(request: String = canonicalRequest) throws -> TaskPlan {
        _ = try compose(request: request)
        return TaskPlan(
            id: "showcase.focus-session.v6",
            name: "Research focus session",
            summary: "Open and arrange the exact public-safe research fixtures",
            focusPolicy: .foreground,
            steps: [
                focusStep(
                    id: "open-brief",
                    adapterID: "preview",
                    application: "Preview",
                    bundleID: FocusSessionVerifier.previewBundleID,
                    operation: .openBrief,
                    reason: "Open the exact public-safe research brief fixture"
                ),
                focusStep(
                    id: "open-scratchpad",
                    adapterID: "textedit",
                    application: "TextEdit",
                    bundleID: FocusSessionVerifier.textEditBundleID,
                    operation: .openScratchpad,
                    reason: "Open the exact public-safe research scratchpad fixture"
                ),
                focusStep(
                    id: "arrange-workspace",
                    adapterID: "preview",
                    application: "Preview",
                    bundleID: FocusSessionVerifier.previewBundleID,
                    operation: .arrangeWorkspace,
                    reason: "Arrange only the verified brief and scratchpad windows"
                )
            ],
            totalTimeout: 90,
            recipe: "focus-session-v6"
        )
    }

    private static func focusStep(
        id: String,
        adapterID: String,
        application: String,
        bundleID: String,
        operation: FocusSessionExecutionOperation,
        reason: String
    ) -> TaskStep {
        TaskStep(
            id: id,
            action: ActionSpec(
                kind: .adapter,
                surface: .macApp,
                parameters: [
                    "adapter_id": .string(adapterID),
                    "app": .string(application),
                    "operation": .string(operation.rawValue)
                ],
                risk: .reversible
            ),
            target: TaskTargetIdentity(application: application, bundleID: bundleID),
            postconditions: [TaskPredicate(
                kind: .adapterState,
                parameters: [
                    "adapter_id": .string(adapterID),
                    "state": .string("focus_session_verified"),
                    "focus_session_effect": .string(operation.rawValue)
                ]
            )],
            risk: .reversible,
            approvalReason: reason,
            timeout: 20,
            recovery: .strict
        )
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private struct DigestPayload: Codable {
        let request: String
        let name: String
        let fixtureID: String
        let effects: [FocusSessionPlanEffect]

        private enum CodingKeys: String, CodingKey {
            case request, name
            case fixtureID = "fixture_id"
            case effects
        }
    }
}
