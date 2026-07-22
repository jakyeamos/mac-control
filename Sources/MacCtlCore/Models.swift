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

    public init(
        requestID: String,
        operationID: String = UUID().uuidString,
        status: OperationStatus,
        result: JSONValue = .object([:]),
        evidence: [Evidence] = [],
        error: MacCtlError? = nil,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.operationID = operationID
        self.status = status
        self.result = result
        self.evidence = evidence
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case operationID = "operation_id"
        case status
        case result
        case evidence
        case error
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
    case iphoneMirroring = "iphone_mirroring"
}

public enum ActionKind: String, Codable, Equatable, CaseIterable {
    case launchApp
    case activateWindow
    case click
    case type
    case key
    case scroll
    case waitFor
    case capture
    case ocr
    case assert
}

public enum SelectorTier: Int, Codable, Equatable {
    case accessibility = 1
    case visual = 2
    case normalizedCoordinate = 3
    case rawCoordinate = 4
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
        imageAnchor: String? = nil
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
    }

    public var tier: SelectorTier {
        if role != nil || identifier != nil || title != nil || subrole != nil {
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

    public var hasTarget: Bool {
        role != nil || identifier != nil || title != nil || subrole != nil
            || containsText != nil || imageAnchor != nil
            || (normalizedX != nil && normalizedY != nil)
            || (rawX != nil && rawY != nil)
    }
}

public struct ActionSpec: Codable, Equatable {
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
    public let actions: [ActionSpec]
    public let assertions: [AssertionSpec]
    public let recipe: String?

    public init(
        id: String,
        name: String,
        summary: String,
        surface: SurfaceKind,
        actions: [ActionSpec],
        assertions: [AssertionSpec] = [],
        recipe: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.surface = surface
        self.actions = actions
        self.assertions = assertions
        self.recipe = recipe
    }
}

public struct AppInfo: Codable, Equatable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let isRunning: Bool
    public let processID: Int32?

    public init(
        name: String,
        bundleID: String?,
        path: String,
        isRunning: Bool,
        processID: Int32?
    ) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.isRunning = isRunning
        self.processID = processID
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
        launchAgent: LaunchAgentStatus? = nil
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
    }
}

public struct CapabilityReport: Codable, Equatable {
    public let capabilities: [String]
    public let optionalBackends: [String]
    public let permissionGates: [String]
    public let safety: [String]

    public init(
        capabilities: [String],
        optionalBackends: [String],
        permissionGates: [String],
        safety: [String]
    ) {
        self.capabilities = capabilities
        self.optionalBackends = optionalBackends
        self.permissionGates = permissionGates
        self.safety = safety
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
    public let expiresAt: Date

    public init(
        token: String,
        operationID: String,
        workflowID: String,
        summary: String,
        risk: RiskLevel,
        expiresAt: Date
    ) {
        self.token = token
        self.operationID = operationID
        self.workflowID = workflowID
        self.summary = summary
        self.risk = risk
        self.expiresAt = expiresAt
    }
}

public struct ExecutionReport: Codable, Equatable {
    public let workflowID: String
    public let completedActions: Int
    public let evidence: [Evidence]
    public let result: [String: JSONValue]

    public init(
        workflowID: String,
        completedActions: Int,
        evidence: [Evidence],
        result: [String: JSONValue] = [:]
    ) {
        self.workflowID = workflowID
        self.completedActions = completedActions
        self.evidence = evidence
        self.result = result
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
    case invalidSelector = "invalid_selector"
    case unsafeInput = "unsafe_input"
    case launchAgentUnhealthy = "launch_agent_unhealthy"
    case receiptUnavailable = "receipt_unavailable"
}

struct ApprovalDigestPayload: Codable {
    let workflow: WorkflowSpec
    let ephemeralInputs: [String: String]
}
