import Foundation

public struct FocusSessionWindowFrame: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate func approximatelyEquals(_ other: FocusSessionWindowFrame, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

/// A privacy-bounded observation collected after dispatch. Visible titles,
/// document contents, and file paths never enter the verification receipt.
public struct FocusSessionWindowObservation: Codable, Equatable {
    public let applicationBundleID: String
    public let visible: Bool
    public let fixtureDigest: String
    public let windowIdentityDigest: String
    public let frame: FocusSessionWindowFrame

    public init(
        applicationBundleID: String,
        visible: Bool,
        fixtureDigest: String,
        windowIdentityDigest: String,
        frame: FocusSessionWindowFrame
    ) {
        self.applicationBundleID = applicationBundleID
        self.visible = visible
        self.fixtureDigest = fixtureDigest
        self.windowIdentityDigest = windowIdentityDigest
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey {
        case applicationBundleID = "application_bundle_id"
        case visible
        case fixtureDigest = "fixture_digest"
        case windowIdentityDigest = "window_identity_digest"
        case frame
    }
}

public struct FocusSessionVerificationSnapshot: Codable, Equatable {
    public let planDigest: String
    public let displayID: UInt32
    public let layoutName: FocusSessionLayoutName
    public let brief: FocusSessionWindowObservation
    public let scratchpad: FocusSessionWindowObservation

    public init(
        planDigest: String,
        displayID: UInt32,
        layoutName: FocusSessionLayoutName,
        brief: FocusSessionWindowObservation,
        scratchpad: FocusSessionWindowObservation
    ) {
        self.planDigest = planDigest
        self.displayID = displayID
        self.layoutName = layoutName
        self.brief = brief
        self.scratchpad = scratchpad
    }

    private enum CodingKeys: String, CodingKey {
        case planDigest = "plan_digest"
        case displayID = "display_id"
        case layoutName = "layout_name"
        case brief, scratchpad
    }
}

public enum FocusSessionVerificationState: String, Codable, Equatable {
    case verified
    case failed
}

public struct FocusSessionVerificationRecord: Codable, Equatable {
    public let schemaVersion: String
    public let planDigest: String
    public let effectID: String
    public let observer: String
    public let state: FocusSessionVerificationState
    public let evidence: [String: String]

    public init(
        planDigest: String,
        effectID: String,
        observer: String,
        state: FocusSessionVerificationState,
        evidence: [String: String]
    ) {
        self.schemaVersion = "macctl-focus-session-verification/v2"
        self.planDigest = planDigest
        self.effectID = effectID
        self.observer = observer
        self.state = state
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case planDigest = "plan_digest"
        case effectID = "effect_id"
        case observer, state, evidence
    }
}

public enum FocusSessionVerifier {
    public static let previewBundleID = "com.apple.Preview"
    public static let textEditBundleID = "com.apple.TextEdit"

    /// Produces three independent, redacted records. Callers must collect this
    /// snapshot through read surfaces after mutation; action return values are
    /// deliberately not accepted by this API.
    public static func verify(
        preview: FocusSessionPlanPreview,
        snapshot: FocusSessionVerificationSnapshot,
        expectedBriefFixtureDigest: String,
        expectedScratchpadFixtureDigest: String,
        expectedBriefFrame: FocusSessionWindowFrame,
        expectedScratchpadFrame: FocusSessionWindowFrame,
        frameTolerance: Double = 2
    ) -> [FocusSessionVerificationRecord] {
        let planMatches = snapshot.planDigest == preview.approvalDigest
        let briefVerified = planMatches
            && snapshot.brief.applicationBundleID == previewBundleID
            && snapshot.brief.visible
            && snapshot.brief.fixtureDigest == expectedBriefFixtureDigest
            && !snapshot.brief.windowIdentityDigest.isEmpty
        let scratchpadVerified = planMatches
            && snapshot.scratchpad.applicationBundleID == textEditBundleID
            && snapshot.scratchpad.visible
            && snapshot.scratchpad.fixtureDigest == expectedScratchpadFixtureDigest
            && !snapshot.scratchpad.windowIdentityDigest.isEmpty
        let layoutVerified = planMatches
            && snapshot.displayID == preview.display.id
            && snapshot.layoutName == preview.layoutName
            && snapshot.brief.frame.approximatelyEquals(expectedBriefFrame, tolerance: frameTolerance)
            && snapshot.scratchpad.frame.approximatelyEquals(expectedScratchpadFrame, tolerance: frameTolerance)

        return [
            record(
                planDigest: preview.approvalDigest,
                effectID: "open-brief",
                observer: "fixture_digest+accessibility_window",
                verified: briefVerified,
                evidence: [
                    "application_bundle_id": snapshot.brief.applicationBundleID,
                    "fixture_digest": snapshot.brief.fixtureDigest,
                    "window_identity_digest": snapshot.brief.windowIdentityDigest,
                    "visible": String(snapshot.brief.visible)
                ]
            ),
            record(
                planDigest: preview.approvalDigest,
                effectID: "open-scratchpad",
                observer: "fixture_digest+accessibility_window",
                verified: scratchpadVerified,
                evidence: [
                    "application_bundle_id": snapshot.scratchpad.applicationBundleID,
                    "fixture_digest": snapshot.scratchpad.fixtureDigest,
                    "window_identity_digest": snapshot.scratchpad.windowIdentityDigest,
                    "visible": String(snapshot.scratchpad.visible)
                ]
            ),
            record(
                planDigest: preview.approvalDigest,
                effectID: "arrange-workspace",
                observer: "accessibility_window_frames",
                verified: layoutVerified,
                evidence: [
                    "brief_frame": frameDescription(snapshot.brief.frame),
                    "display_id": String(snapshot.displayID),
                    "frame_tolerance_points": String(frameTolerance),
                    "layout_name": snapshot.layoutName.rawValue,
                    "scratchpad_frame": frameDescription(snapshot.scratchpad.frame)
                ]
            )
        ]
    }

    private static func record(
        planDigest: String,
        effectID: String,
        observer: String,
        verified: Bool,
        evidence: [String: String]
    ) -> FocusSessionVerificationRecord {
        FocusSessionVerificationRecord(
            planDigest: planDigest,
            effectID: effectID,
            observer: observer,
            state: verified ? .verified : .failed,
            evidence: evidence
        )
    }

    private static func frameDescription(_ frame: FocusSessionWindowFrame) -> String {
        [frame.x, frame.y, frame.width, frame.height]
            .map { String(format: "%.1f", $0) }
            .joined(separator: ",")
    }
}
