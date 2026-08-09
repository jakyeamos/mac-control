import Foundation

public enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONCodec.encode(value)
        return try JSONCodec.decode(JSONValue.self, from: data)
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }
}

public struct RequestEnvelope: Codable, Equatable {
    public let schemaVersion: Int
    public let requestID: String
    public let method: String
    public let params: [String: JSONValue]

    public init(
        schemaVersion: Int = 1,
        requestID: String = UUID().uuidString,
        method: String,
        params: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case method
        case params
    }
}

public enum OperationStatus: String, Codable, Equatable {
    case succeeded
    case prepared
    case blocked
    case failed
    case denied
    case expired
}

public struct MacCtlError: Codable, Equatable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]

    public init(code: String, message: String, details: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Provider-neutral machine-readable action result.  Agents can use this
/// contract without interpreting human error strings or assuming that every
/// failure is retryable through the same provider.
public enum AgentActionOutcomeState: String, Codable, Equatable {
    case verifiedSuccess = "verified_success"
    case targetMissing = "target_missing"
    case targetAmbiguous = "target_ambiguous"
    case actionUnavailable = "action_unavailable"
    case actionFailed = "action_failed"
    case permissionBlocked = "permission_blocked"
    case noObservedChange = "no_observed_change"
    case verificationUnavailable = "verification_unavailable"
    case foregroundRace = "foreground_race"
}

public struct AgentActionOutcome: Codable, Equatable {
    public let state: AgentActionOutcomeState
    public let provider: String
    public let route: String?
    public let verification: String?
    public let failureClass: String?
    public let fallbackAllowed: Bool
    public let recommendedProvider: String?
    public let freshStateRequired: Bool
    public let nextAction: String?

    public init(
        state: AgentActionOutcomeState,
        provider: String = "mac_control",
        route: String? = nil,
        verification: String? = nil,
        failureClass: String? = nil,
        fallbackAllowed: Bool = false,
        recommendedProvider: String? = nil,
        freshStateRequired: Bool = false,
        nextAction: String? = nil
    ) {
        self.state = state
        self.provider = provider
        self.route = route
        self.verification = verification
        self.failureClass = failureClass
        self.fallbackAllowed = fallbackAllowed
        self.recommendedProvider = recommendedProvider
        self.freshStateRequired = freshStateRequired
        self.nextAction = nextAction
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case provider
        case route
        case verification
        case failureClass = "failure_class"
        case fallbackAllowed = "fallback_allowed"
        case recommendedProvider = "recommended_provider"
        case freshStateRequired = "fresh_state_required"
        case nextAction = "next_action"
    }
}

public struct Evidence: Codable, Equatable {
    public let kind: String
    public let message: String
    public let source: String?
    public let metadata: [String: JSONValue]

    public init(
        kind: String,
        message: String,
        source: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.message = message
        self.source = source
        self.metadata = metadata
    }
}

public struct ResponseEnvelope: Codable, Equatable {
    public let schemaVersion: Int
    public let requestID: String
    public let operationID: String
    public let status: OperationStatus
    public let result: JSONValue
    public let evidence: [Evidence]
    public let error: MacCtlError?
    public let outcome: AgentActionOutcome?

    public init(
        requestID: String,
        operationID: String = UUID().uuidString,
        status: OperationStatus,
        result: JSONValue = .object([:]),
        evidence: [Evidence] = [],
        error: MacCtlError? = nil,
        outcome: AgentActionOutcome? = nil,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.operationID = operationID
        self.status = status
        self.result = result
        self.evidence = evidence
        self.error = error
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case operationID = "operation_id"
        case status
        case result
        case evidence
        case error
        case outcome
    }
}

public enum RiskLevel: String, Codable, Equatable, CaseIterable {
    case safe
    case reversible
    case sensitive

    public var requiresApproval: Bool {
        self == .sensitive
    }
}

public enum SurfaceKind: String, Codable, Equatable, CaseIterable {
    case macDesktop = "mac_desktop"
    case macApp = "mac_app"
}

public enum FocusPolicy: String, Codable, Equatable, CaseIterable {
    case foreground
    case background
}

public enum ActionKind: String, Codable, Equatable, CaseIterable {
    case launchApp
    case activateWindow
    case click
    case type
    case key
    case search
    case command
    case scroll
    case waitFor
    case capture
    case ocr
    case assert
    /// A typed operation resolved through the allowlisted application-adapter registry.
    case adapter
}

public enum SelectorTier: Int, Codable, Equatable {
    case accessibility = 1
    case visual = 2
    case normalizedCoordinate = 3
    case rawCoordinate = 4
}

/// The selector's addressability family.  This is descriptive metadata, not a
/// global route precedence rule; a task manifest chooses among measured routes.
public enum SelectorAddressability: String, Codable, Equatable, CaseIterable {
    case accessibility
    case visual
    case normalizedCoordinate = "normalized_coordinate"
    case rawCoordinate = "raw_coordinate"
}

public struct Selector: Codable, Equatable {
    public let role: String?
    public let identifier: String?
    public let title: String?
    public let subrole: String?
    public let containsText: String?
    public let normalizedX: Double?
    public let normalizedY: Double?
    public let rawX: Double?
    public let rawY: Double?
    public let imageAnchor: String?
    /// Optional Accessibility window scope. When either value is supplied,
    /// the control resolver must first select one unique matching window and
    /// then search only that window's subtree.
    public let windowTitle: String?
    public let windowIdentifier: String?

    public init(
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        subrole: String? = nil,
        containsText: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        rawX: Double? = nil,
        rawY: Double? = nil,
        imageAnchor: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.subrole = subrole
        self.containsText = containsText
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.rawX = rawX
        self.rawY = rawY
        self.imageAnchor = imageAnchor
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
    }

    public var addressability: SelectorAddressability {
        if role != nil || identifier != nil || title != nil || subrole != nil
            || windowTitle != nil || windowIdentifier != nil {
            return .accessibility
        }
        if containsText != nil || imageAnchor != nil {
            return .visual
        }
        if normalizedX != nil && normalizedY != nil {
            return .normalizedCoordinate
        }
        return .rawCoordinate
    }

    /// Compatibility projection for older workflow receipts and adapters.
    /// New route selection must use `addressability` and the task-specific
    /// warm-path manifest; this numeric value is not a ranking input.
    @available(*, deprecated, message: "Use addressability; SelectorTier is a compatibility projection, not route precedence")
    public var tier: SelectorTier {
        switch addressability {
        case .accessibility: return .accessibility
        case .visual: return .visual
        case .normalizedCoordinate: return .normalizedCoordinate
        case .rawCoordinate: return .rawCoordinate
        }
    }

    public var hasTarget: Bool {
        role != nil || identifier != nil || title != nil || subrole != nil
            || containsText != nil || imageAnchor != nil
            || (normalizedX != nil && normalizedY != nil)
            || (rawX != nil && rawY != nil)
    }
}

public struct ActionSpec: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case surface
        case selector
        case parameters
        case risk
    }

    public let kind: ActionKind
    public let surface: SurfaceKind
    public let selector: Selector?
    public let parameters: [String: JSONValue]
    public let risk: RiskLevel?

    public init(
        kind: ActionKind,
        surface: SurfaceKind,
        selector: Selector? = nil,
        parameters: [String: JSONValue] = [:],
        risk: RiskLevel? = nil
    ) {
        self.kind = kind
        self.surface = surface
        self.selector = selector
        self.parameters = parameters
        self.risk = risk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ActionKind.self, forKey: .kind)
        surface = try container.decode(SurfaceKind.self, forKey: .surface)
        selector = try container.decodeIfPresent(Selector.self, forKey: .selector)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
        risk = try container.decodeIfPresent(RiskLevel.self, forKey: .risk)
    }
}

public struct AssertionSpec: Codable, Equatable {
    public let kind: String
    public let surface: SurfaceKind
    public let expected: String?
    public let selector: Selector?
    public let parameters: [String: JSONValue]

    public init(
        kind: String,
        surface: SurfaceKind,
        expected: String? = nil,
        selector: Selector? = nil,
        parameters: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.surface = surface
        self.expected = expected
        self.selector = selector
        self.parameters = parameters
    }
}

public struct WorkflowSpec: Codable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let surface: SurfaceKind
    public let focusPolicy: FocusPolicy
    /// Physical keyboard suppression is a separate, explicit authority.  This
    /// flag is part of the approved workflow digest so a lease cannot silently
    /// escalate an ordinary workflow into a keyboard freeze.
    public let keyboardFreezeRequired: Bool
    public let actions: [ActionSpec]
    public let assertions: [AssertionSpec]
    public let recipe: String?

    public init(
        id: String,
        name: String,
        summary: String,
        surface: SurfaceKind,
        focusPolicy: FocusPolicy = .foreground,
        keyboardFreezeRequired: Bool = false,
        actions: [ActionSpec],
        assertions: [AssertionSpec] = [],
        recipe: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.surface = surface
        self.focusPolicy = focusPolicy
        self.keyboardFreezeRequired = keyboardFreezeRequired
        self.actions = actions
        self.assertions = assertions
        self.recipe = recipe
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case surface
        case focusPolicy
        case keyboardFreezeRequired
        case keyboardFreezeRequiredSnake = "keyboard_freeze_required"
        case actions
        case assertions
        case recipe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.surface = try container.decode(SurfaceKind.self, forKey: .surface)
        self.focusPolicy = try container.decodeIfPresent(FocusPolicy.self, forKey: .focusPolicy) ?? .foreground
        self.keyboardFreezeRequired = try container.decodeIfPresent(Bool.self, forKey: .keyboardFreezeRequired)
            ?? container.decodeIfPresent(Bool.self, forKey: .keyboardFreezeRequiredSnake)
            ?? false
        self.actions = try container.decode([ActionSpec].self, forKey: .actions)
        self.assertions = try container.decodeIfPresent([AssertionSpec].self, forKey: .assertions) ?? []
        self.recipe = try container.decodeIfPresent(String.self, forKey: .recipe)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(surface, forKey: .surface)
        try container.encode(focusPolicy, forKey: .focusPolicy)
        try container.encode(keyboardFreezeRequired, forKey: .keyboardFreezeRequired)
        try container.encode(actions, forKey: .actions)
        try container.encode(assertions, forKey: .assertions)
        try container.encodeIfPresent(recipe, forKey: .recipe)
    }

    public func withFocusPolicy(_ focusPolicy: FocusPolicy) -> WorkflowSpec {
        WorkflowSpec(
            id: id,
            name: name,
            summary: summary,
            surface: surface,
            focusPolicy: focusPolicy,
            keyboardFreezeRequired: keyboardFreezeRequired,
            actions: actions,
            assertions: assertions,
            recipe: recipe
        )
    }
}

public struct AppInfo: Codable, Equatable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let isRunning: Bool
    public let processID: Int32?
    public let bundleVersion: String?

    public init(
        name: String,
        bundleID: String?,
        path: String,
        isRunning: Bool,
        processID: Int32?,
        bundleVersion: String? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.isRunning = isRunning
        self.processID = processID
        self.bundleVersion = bundleVersion
    }

    private enum CodingKeys: String, CodingKey {
        case name, bundleID, path, isRunning, processID, bundleVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        path = try container.decode(String.self, forKey: .path)
        isRunning = try container.decode(Bool.self, forKey: .isRunning)
        processID = try container.decodeIfPresent(Int32.self, forKey: .processID)
        bundleVersion = try container.decodeIfPresent(String.self, forKey: .bundleVersion)
    }
}

public struct PermissionStatus: Codable, Equatable {
    public let name: String
    public let state: String
    public let requiredFor: String
    public let instruction: String

    public init(name: String, state: String, requiredFor: String, instruction: String) {
        self.name = name
        self.state = state
        self.requiredFor = requiredFor
        self.instruction = instruction
    }
}

public struct RuntimeIdentity: Codable, Equatable {
    public let processID: Int32
    public let executablePath: String?
    public let bundlePath: String?
    public let bundleIdentifier: String?
    public let bundleVersion: String?
    public let signingIdentity: String?
    public let signingTeamIdentifier: String?
    public let signatureValid: Bool?

    public init(
        processID: Int32,
        executablePath: String?,
        bundlePath: String?,
        bundleIdentifier: String?,
        bundleVersion: String?,
        signingIdentity: String? = nil,
        signingTeamIdentifier: String? = nil,
        signatureValid: Bool? = nil
    ) {
        self.processID = processID
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.signingIdentity = signingIdentity
        self.signingTeamIdentifier = signingTeamIdentifier
        self.signatureValid = signatureValid
    }

    private enum CodingKeys: String, CodingKey {
        case processID
        case executablePath
        case bundlePath
        case bundleIdentifier
        case bundleVersion
        case signingIdentity
        case signingTeamIdentifier
        case signatureValid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processID = try container.decode(Int32.self, forKey: .processID)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        bundleVersion = try container.decodeIfPresent(String.self, forKey: .bundleVersion)
        signingIdentity = try container.decodeIfPresent(String.self, forKey: .signingIdentity)
        signingTeamIdentifier = try container.decodeIfPresent(String.self, forKey: .signingTeamIdentifier)
        signatureValid = try container.decodeIfPresent(Bool.self, forKey: .signatureValid)
    }

    public static func current() -> RuntimeIdentity {
        let bundle = Bundle.main
        let executablePath = bundle.executableURL?.path ?? ProcessInfo.processInfo.arguments.first
        let bundlePath = bundle.bundleURL.path.isEmpty ? nil : bundle.bundleURL.path
        let bundleIdentifier = bundle.bundleIdentifier
        let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let isAppBundle = bundlePath?.hasSuffix(".app") == true
        let signature = isAppBundle
            ? MacCtlCodeSigning.inspect(bundleURL: bundle.bundleURL)
            : .unavailable
        return RuntimeIdentity(
            processID: ProcessInfo.processInfo.processIdentifier,
            executablePath: executablePath,
            bundlePath: bundlePath,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            signingIdentity: signature.identity,
            signingTeamIdentifier: signature.teamIdentifier,
            signatureValid: isAppBundle ? signature.valid : nil
        )
    }
}

public struct DoctorReport: Codable, Equatable {
    public let processID: Int32
    public let osVersion: String
    public let architecture: String
    public let socketPath: String
    public let socketOwnerOnly: Bool
    public let permissions: [PermissionStatus]
    public let availableFrameworks: [String]
    public let warnings: [String]
    public let permissionContext: String
    public let runtimeIdentity: RuntimeIdentity
    public let launchAgent: LaunchAgentStatus?
    public let keyboardAccess: KeyboardAccessStatus?
    public let taskCapabilities: TaskCapabilityReport?
    public let checkpointStore: TaskCheckpointStoreStatus?

    public init(
        processID: Int32,
        osVersion: String,
        architecture: String,
        socketPath: String,
        socketOwnerOnly: Bool,
        permissions: [PermissionStatus],
        availableFrameworks: [String],
        warnings: [String],
        permissionContext: String = "daemon",
        runtimeIdentity: RuntimeIdentity = .current(),
        launchAgent: LaunchAgentStatus? = nil,
        keyboardAccess: KeyboardAccessStatus? = nil,
        taskCapabilities: TaskCapabilityReport? = nil,
        checkpointStore: TaskCheckpointStoreStatus? = nil
    ) {
        self.processID = processID
        self.osVersion = osVersion
        self.architecture = architecture
        self.socketPath = socketPath
        self.socketOwnerOnly = socketOwnerOnly
        self.permissions = permissions
        self.availableFrameworks = availableFrameworks
        self.warnings = warnings
        self.permissionContext = permissionContext
        self.runtimeIdentity = runtimeIdentity
        self.launchAgent = launchAgent
        self.keyboardAccess = keyboardAccess
        self.taskCapabilities = taskCapabilities
        self.checkpointStore = checkpointStore
    }
}

public struct CapabilityReport: Codable, Equatable {
    public let capabilities: [String]
    public let optionalBackends: [String]
    public let permissionGates: [String]
    public let safety: [String]
    public let keyboardAccess: KeyboardAccessStatus?
    public let taskCapabilities: TaskCapabilityReport?
    public let adapterManifests: [AppAdapterManifest]
    public let automationPermissions: [PermissionStatus]
    public let checkpointStore: TaskCheckpointStoreStatus?
    public let shortcutCapabilities: ShortcutCapabilityReport?

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case optionalBackends
        case permissionGates
        case safety
        case keyboardAccess
        case taskCapabilities
        case adapterManifests
        case automationPermissions
        case checkpointStore
        case shortcutCapabilities
    }

    public init(
        capabilities: [String],
        optionalBackends: [String],
        permissionGates: [String],
        safety: [String],
        keyboardAccess: KeyboardAccessStatus? = nil,
        taskCapabilities: TaskCapabilityReport? = nil,
        adapterManifests: [AppAdapterManifest] = [],
        automationPermissions: [PermissionStatus] = [],
        checkpointStore: TaskCheckpointStoreStatus? = nil,
        shortcutCapabilities: ShortcutCapabilityReport? = nil
    ) {
        self.capabilities = capabilities
        self.optionalBackends = optionalBackends
        self.permissionGates = permissionGates
        self.safety = safety
        self.keyboardAccess = keyboardAccess
        self.taskCapabilities = taskCapabilities
        self.adapterManifests = adapterManifests
        self.automationPermissions = automationPermissions
        self.checkpointStore = checkpointStore
        self.shortcutCapabilities = shortcutCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        optionalBackends = try container.decode([String].self, forKey: .optionalBackends)
        permissionGates = try container.decode([String].self, forKey: .permissionGates)
        safety = try container.decode([String].self, forKey: .safety)
        keyboardAccess = try container.decodeIfPresent(KeyboardAccessStatus.self, forKey: .keyboardAccess)
        taskCapabilities = try container.decodeIfPresent(TaskCapabilityReport.self, forKey: .taskCapabilities)
        adapterManifests = try container.decodeIfPresent([AppAdapterManifest].self, forKey: .adapterManifests) ?? []
        automationPermissions = try container.decodeIfPresent([PermissionStatus].self, forKey: .automationPermissions) ?? []
        checkpointStore = try container.decodeIfPresent(TaskCheckpointStoreStatus.self, forKey: .checkpointStore)
        shortcutCapabilities = try container.decodeIfPresent(ShortcutCapabilityReport.self, forKey: .shortcutCapabilities)
    }
}

public struct DaemonStatus: Codable, Equatable {
    public let daemonName: String
    public let runtimeContext: String
    public let processID: Int32
    public let socketPath: String
    public let socketExists: Bool
    public let approvalCount: Int
    public let supportedSurfaces: [SurfaceKind]
    public let runtimeIdentity: RuntimeIdentity
    public let launchAgent: LaunchAgentStatus
    public let socketOwnerOnly: Bool
    public let receiptStore: ReceiptStoreStatus

    public init(
        daemonName: String,
        runtimeContext: String = "daemon",
        processID: Int32,
        socketPath: String,
        socketExists: Bool,
        approvalCount: Int,
        supportedSurfaces: [SurfaceKind],
        runtimeIdentity: RuntimeIdentity = .current(),
        launchAgent: LaunchAgentStatus = LaunchAgentStatus.unavailable(),
        socketOwnerOnly: Bool = false,
        receiptStore: ReceiptStoreStatus = .unavailable()
    ) {
        self.daemonName = daemonName
        self.runtimeContext = runtimeContext
        self.processID = processID
        self.socketPath = socketPath
        self.socketExists = socketExists
        self.approvalCount = approvalCount
        self.supportedSurfaces = supportedSurfaces
        self.runtimeIdentity = runtimeIdentity
        self.launchAgent = launchAgent
        self.socketOwnerOnly = socketOwnerOnly
        self.receiptStore = receiptStore
    }
}

public struct ApprovalRecord: Codable, Equatable {
    public let token: String
    public let operationID: String
    public let workflowID: String
    public let summary: String
    public let risk: RiskLevel
    public let focusPolicy: FocusPolicy
    public let keyboardFreezeRequired: Bool
    public let expiresAt: Date

    public init(
        token: String,
        operationID: String,
        workflowID: String,
        summary: String,
        risk: RiskLevel,
        focusPolicy: FocusPolicy = .foreground,
        keyboardFreezeRequired: Bool = false,
        expiresAt: Date
    ) {
        self.token = token
        self.operationID = operationID
        self.workflowID = workflowID
        self.summary = summary
        self.risk = risk
        self.focusPolicy = focusPolicy
        self.keyboardFreezeRequired = keyboardFreezeRequired
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case operationID
        case workflowID
        case summary
        case risk
        case focusPolicy
        case keyboardFreezeRequired
        case keyboardFreezeRequiredSnake = "keyboard_freeze_required"
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.operationID = try container.decode(String.self, forKey: .operationID)
        self.workflowID = try container.decode(String.self, forKey: .workflowID)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.risk = try container.decode(RiskLevel.self, forKey: .risk)
        self.focusPolicy = try container.decodeIfPresent(FocusPolicy.self, forKey: .focusPolicy) ?? .foreground
        self.keyboardFreezeRequired = try container.decodeIfPresent(Bool.self, forKey: .keyboardFreezeRequired)
            ?? container.decodeIfPresent(Bool.self, forKey: .keyboardFreezeRequiredSnake)
            ?? false
        self.expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(summary, forKey: .summary)
        try container.encode(risk, forKey: .risk)
        try container.encode(focusPolicy, forKey: .focusPolicy)
        try container.encode(keyboardFreezeRequired, forKey: .keyboardFreezeRequired)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}

public struct ExecutionReport: Codable, Equatable {
    public let runID: String
    public let workflowID: String
    public let focusPolicy: FocusPolicy
    public let completedActions: Int
    public let targetProcessIDs: [Int32]
    public let evidence: [Evidence]
    public let result: [String: JSONValue]

    public init(
        workflowID: String,
        completedActions: Int,
        evidence: [Evidence],
        result: [String: JSONValue] = [:],
        runID: String = UUID().uuidString,
        focusPolicy: FocusPolicy = .foreground,
        targetProcessIDs: [Int32] = []
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.focusPolicy = focusPolicy
        self.completedActions = completedActions
        self.targetProcessIDs = targetProcessIDs
        self.evidence = evidence
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case workflowID
        case focusPolicy
        case completedActions
        case targetProcessIDs
        case evidence
        case result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runID = try container.decodeIfPresent(String.self, forKey: .runID) ?? UUID().uuidString
        self.workflowID = try container.decode(String.self, forKey: .workflowID)
        self.focusPolicy = try container.decodeIfPresent(FocusPolicy.self, forKey: .focusPolicy) ?? .foreground
        self.completedActions = try container.decode(Int.self, forKey: .completedActions)
        self.targetProcessIDs = try container.decodeIfPresent([Int32].self, forKey: .targetProcessIDs) ?? []
        self.evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        self.result = try container.decodeIfPresent([String: JSONValue].self, forKey: .result) ?? [:]
    }
}

public enum MacCtlErrorCode: String {
    case invalidRequest = "invalid_request"
    case unsupportedMethod = "unsupported_method"
    case daemonUnavailable = "daemon_unavailable"
    case workflowNotFound = "workflow_not_found"
    case workflowInvalid = "workflow_invalid"
    case permissionDenied = "permission_denied"
    case approvalRequired = "approval_required"
    case approvalNotFound = "approval_not_found"
    case approvalExpired = "approval_expired"
    case approvalAlreadyUsed = "approval_already_used"
    case operationFailed = "operation_failed"
    case controlVerificationUnavailable = "control_verification_unavailable"
    case invalidSelector = "invalid_selector"
    case unsafeInput = "unsafe_input"
    case backgroundUnsupported = "background_unsupported"
    case focusChanged = "focus_changed"
    case launchAgentUnhealthy = "launch_agent_unhealthy"
    case receiptUnavailable = "receipt_unavailable"
    case keyboardAccessDisabled = "keyboard_access_disabled"
    case keyboardConfirmationRequired = "keyboard_confirmation_required"
    case keyboardEnableVerificationFailed = "keyboard_enable_verification_failed"
    case keyboardLeaseRequired = "keyboard_lease_required"
    case keyboardLeaseNotFound = "keyboard_lease_not_found"
    case keyboardLeaseExpired = "keyboard_lease_expired"
    case keyboardLeaseConflict = "keyboard_lease_conflict"
    case keyboardLeaseInvalid = "keyboard_lease_invalid"
    case keyboardPhysicalSuppressionUnavailable = "keyboard_physical_suppression_unavailable"
    case keyboardPhysicalSuppressionRequiresSession = "keyboard_physical_suppression_requires_session"
    case keyboardFreezeReasonRequired = "keyboard_freeze_reason_required"
    case keyboardFocusChanged = "keyboard_focus_changed"
    case keyboardFocusUnavailable = "keyboard_focus_unavailable"
    case keyboardCommandInvalid = "keyboard_command_invalid"
    case keyboardSequenceInvalid = "keyboard_sequence_invalid"
    case keyboardPrintableKeyRejected = "keyboard_printable_key_rejected"
    case taskInvalidPlan = "task_invalid_plan"
    case taskNotFound = "task_not_found"
    case taskApprovalRequired = "task_approval_required"
    case taskApprovalMismatch = "task_approval_mismatch"
    case taskStateInvalid = "task_state_invalid"
    case taskLeaseRequired = "task_lease_required"
    case taskCancelled = "task_cancelled"
    case taskExpired = "task_expired"
    case taskTimeout = "task_timeout"
    case taskActionBudgetExceeded = "task_action_budget_exceeded"
    case taskPreconditionFailed = "task_precondition_failed"
    case taskPostconditionFailed = "task_postcondition_failed"
    case taskBlocked = "task_blocked"
    case taskIndeterminate = "task_indeterminate"
    case taskCheckpointUnavailable = "task_checkpoint_unavailable"
    case adapterUnsupported = "adapter_unsupported"
    case adapterPermissionMissing = "adapter_permission_missing"
    case routeSelectionBlocked = "route_selection_blocked"
    case routeBenchmarkBlocked = "route_benchmark_blocked"
    case scrollFallbackRequired = "scroll_fallback_required"
    case scrollVerificationUnavailable = "scroll_verification_unavailable"
    case accessibilityTreeUnavailable = "accessibility_tree_unavailable"
    case accessibilityAuditFailed = "accessibility_audit_failed"
    case shortcutNotFound = "shortcut_not_found"
    case shortcutConflict = "shortcut_conflict"
    case shortcutSetupRequired = "shortcut_setup_required"
    case shortcutHandoffRequired = "shortcut_handoff_required"
    case shortcutStale = "shortcut_stale"
}

struct ApprovalDigestPayload: Codable {
    let workflow: WorkflowSpec
    let ephemeralInputs: [String: String]
}
