import ApplicationServices
import AppKit
import Foundation

public enum ExactActionKind: String, Codable, Equatable {
    case press
}

public struct ExactActionSelector: Codable, Equatable {
    public let role: String?
    public let identifier: String?
    public let locatorDigest: String?
    public let ancestorDigest: String?
    public let geometryDigest: String?
    public let title: String?
    public let subrole: String?
    public let containsText: String?

    public init(
        role: String? = nil,
        identifier: String? = nil,
        locatorDigest: String? = nil,
        ancestorDigest: String? = nil,
        geometryDigest: String? = nil,
        title: String? = nil,
        subrole: String? = nil,
        containsText: String? = nil
    ) {
        self.role = role
        self.identifier = identifier
        self.locatorDigest = locatorDigest
        self.ancestorDigest = ancestorDigest
        self.geometryDigest = geometryDigest
        self.title = title
        self.subrole = subrole
        self.containsText = containsText
    }

    public var selector: Selector {
        Selector(
            role: role,
            identifier: identifier,
            locatorDigest: locatorDigest,
            ancestorDigest: ancestorDigest,
            geometryDigest: geometryDigest,
            title: title,
            subrole: subrole,
            containsText: containsText
        )
    }

    public var fields: [String] {
        [
            ("role", role), ("identifier", identifier), ("locator_digest", locatorDigest),
            ("ancestor_digest", ancestorDigest), ("geometry_digest", geometryDigest),
            ("title", title), ("subrole", subrole), ("contains_text", containsText)
        ].compactMap { $0.1 == nil ? nil : $0.0 }
    }

    public var hasStableIdentity: Bool {
        identifier?.isEmpty == false || locatorDigest?.isEmpty == false
    }

    private enum CodingKeys: String, CodingKey {
        case role, identifier, title, subrole
        case locatorDigest = "locator_digest"
        case ancestorDigest = "ancestor_digest"
        case geometryDigest = "geometry_digest"
        case containsText = "contains_text"
    }
}

public struct ExactActionTarget: Codable, Equatable {
    public let application: String
    public let processID: Int32
    public let instanceRef: String
    public let windowRef: String
    public let selector: ExactActionSelector

    public init(
        application: String,
        processID: Int32,
        instanceRef: String,
        windowRef: String,
        selector: ExactActionSelector
    ) {
        self.application = application
        self.processID = processID
        self.instanceRef = instanceRef
        self.windowRef = windowRef
        self.selector = selector
    }

    private enum CodingKeys: String, CodingKey {
        case application, selector
        case processID = "process_id"
        case instanceRef = "instance_ref"
        case windowRef = "window_ref"
    }
}

public struct ExactActionDesiredState: Codable, Equatable {
    public let selector: ExactActionSelector
    public let exists: Bool

    public init(selector: ExactActionSelector, exists: Bool = true) {
        self.selector = selector
        self.exists = exists
    }
}

public struct ExactActionIntent: Codable, Equatable {
    public let schemaVersion: Int
    public let action: ExactActionKind
    public let target: ExactActionTarget
    public let desiredState: ExactActionDesiredState
    public let focusPolicy: FocusPolicy
    public let foregroundBudget: Int
    public let risk: RiskLevel
    public let verificationTimeout: TimeInterval

    public init(
        action: ExactActionKind,
        target: ExactActionTarget,
        desiredState: ExactActionDesiredState,
        focusPolicy: FocusPolicy = .background,
        foregroundBudget: Int = 0,
        risk: RiskLevel = .safe,
        verificationTimeout: TimeInterval = 1,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.action = action
        self.target = target
        self.desiredState = desiredState
        self.focusPolicy = focusPolicy
        self.foregroundBudget = foregroundBudget
        self.risk = risk
        self.verificationTimeout = verificationTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case action, target, risk
        case schemaVersion = "schema_version"
        case desiredState = "desired_state"
        case focusPolicy = "focus_policy"
        case foregroundBudget = "foreground_budget"
        case verificationTimeout = "verification_timeout"
    }
}

public struct ExactActionTargetProjection: Codable, Equatable {
    public let application: String
    public let bundleID: String?
    public let processID: Int32
    public let instanceRef: String
    public let windowRef: String
    public let selectorFields: [String]
    public let locatorDigest: String

    public init(
        application: String,
        bundleID: String?,
        processID: Int32,
        instanceRef: String,
        windowRef: String,
        selectorFields: [String],
        locatorDigest: String
    ) {
        self.application = application
        self.bundleID = bundleID
        self.processID = processID
        self.instanceRef = instanceRef
        self.windowRef = windowRef
        self.selectorFields = selectorFields.sorted()
        self.locatorDigest = locatorDigest
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case bundleID = "bundle_id"
        case processID = "process_id"
        case instanceRef = "instance_ref"
        case windowRef = "window_ref"
        case selectorFields = "selector_fields"
        case locatorDigest = "locator_digest"
    }
}

public struct ExactActionResolutionReport: Codable, Equatable {
    public let schemaVersion = "macctl-action-resolution/v1"
    public let resolutionID: String
    public let resolveRequestID: String
    public let route: String
    public let focusPolicy: FocusPolicy
    public let foregroundBudget: Int
    public let oneShot: Bool
    public let graphGeneration: UInt64
    public let expiresAt: Date
    public let target: ExactActionTargetProjection

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case resolutionID = "resolution_id"
        case resolveRequestID = "resolve_request_id"
        case route
        case focusPolicy = "focus_policy"
        case foregroundBudget = "foreground_budget"
        case oneShot = "one_shot"
        case graphGeneration = "graph_generation"
        case expiresAt = "expires_at"
        case target
    }
}

public struct ExactActionExecutionReport: Codable, Equatable {
    public let schemaVersion = "macctl-action-execution/v1"
    public let resolutionID: String
    public let resolveRequestID: String
    public let route: String
    public let focusPolicy: FocusPolicy
    public let foregroundBudget: Int
    public let dispatchStatus: String
    public let nativeDispatchCode: Int32?
    public let verification: String
    public let foregroundPreserved: Bool
    public let target: ExactActionTargetProjection

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case resolutionID = "resolution_id"
        case resolveRequestID = "resolve_request_id"
        case route
        case focusPolicy = "focus_policy"
        case foregroundBudget = "foreground_budget"
        case dispatchStatus = "dispatch_status"
        case nativeDispatchCode = "native_dispatch_code"
        case verification
        case foregroundPreserved = "foreground_preserved"
        case target
    }
}

public enum ExactActionIntentError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unsupported(String)
    case resolutionNotFound
    case resolutionExpired
    case resolutionAlreadyUsed
    case targetMissing
    case targetAmbiguous(Int?)
    case targetChanged
    case actionUnavailable
    case verificationUnavailable
    case noObservedChange
    case dispatchIndeterminate(Int32)
    case foregroundRace

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid action intent: \(reason)"
        case .unsupported(let reason): return "Action intent is unsupported: \(reason)"
        case .resolutionNotFound: return "The action resolution was not found"
        case .resolutionExpired: return "The action resolution expired"
        case .resolutionAlreadyUsed: return "The action resolution was already consumed"
        case .targetMissing: return "The exact action target disappeared"
        case .targetAmbiguous: return "The exact action target is ambiguous"
        case .targetChanged: return "The exact action target changed after resolution"
        case .actionUnavailable: return "The exact target does not expose AXPress"
        case .verificationUnavailable: return "The exact action postcondition could not be verified"
        case .noObservedChange: return "The declared desired state was not observed"
        case .dispatchIndeterminate(let code): return "The one-shot Accessibility dispatch was indeterminate (AXError \(code))"
        case .foregroundRace: return "Foreground ownership changed during a zero-focus action"
        }
    }

    public var failureClass: String {
        switch self {
        case .invalid: return "invalid_intent"
        case .unsupported, .actionUnavailable: return "action_unavailable"
        case .resolutionNotFound: return "resolution_not_found"
        case .resolutionExpired: return "resolution_expired"
        case .resolutionAlreadyUsed: return "resolution_already_used"
        case .targetMissing: return "target_missing"
        case .targetAmbiguous: return "target_ambiguous"
        case .targetChanged: return "target_changed"
        case .verificationUnavailable: return "verification_unavailable"
        case .noObservedChange: return "no_observed_change"
        case .dispatchIndeterminate: return "dispatch_indeterminate"
        case .foregroundRace: return "foreground_race"
        }
    }
}

public struct ExactAccessibilityPressTarget: Equatable {
    public let role: String?
    public let subrole: String?
    public let action: String
    public let locatorDigest: String
}

public enum ExactAccessibilityDispatchResult: Equatable {
    case accepted
    case indeterminate(Int32)
}

public protocol ExactAccessibilityActionPerforming {
    func inspectPressTarget(
        pid: pid_t,
        windowRef: String,
        selector: Selector
    ) throws -> ExactAccessibilityPressTarget
    func press(pid: pid_t, windowRef: String, selector: Selector) throws -> ExactAccessibilityDispatchResult
    func elementExists(pid: pid_t, windowRef: String, selector: Selector, maxNodes: Int) throws -> Bool
}

extension AccessibilityController: ExactAccessibilityActionPerforming {}

public protocol ExactActionIntentControlling: AnyObject {
    func resolve(_ intent: ExactActionIntent, requestID: String) throws -> ExactActionResolutionReport
    func run(resolutionID: String) throws -> ExactActionExecutionReport
    func shutdown()
}

private struct ExactActionResolutionRecord {
    let resolutionID: String
    let resolveRequestID: String
    let intent: ExactActionIntent
    let instance: ApplicationInstanceInfo
    let projection: ExactActionTargetProjection
    let targetGeneration: UInt64
    let foregroundGeneration: UInt64
    let foregroundProcessID: Int32
    let expiresAt: Date
}

/// A daemon-local, event-invalidated graph. It stores no AX handles and emits
/// only opaque one-shot resolution IDs; every mutation still re-resolves the
/// process, window, and control from fresh Accessibility state.
public final class EphemeralTargetGraph {
    private let lock = NSLock()
    private let now: () -> Date
    private let workspaceNotificationCenter: NotificationCenter?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var targetGenerations: [pid_t: UInt64] = [:]
    private var foregroundGeneration: UInt64 = 0
    private var resolutions: [String: ExactActionResolutionRecord] = [:]
    private var consumed: [String: Date] = [:]

    public init(
        observeSystemEvents: Bool = true,
        now: @escaping () -> Date = Date.init,
        workspaceNotificationCenter: NotificationCenter? = nil
    ) {
        self.now = now
        self.workspaceNotificationCenter = observeSystemEvents
            ? (workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter)
            : nil
        if observeSystemEvents { startWorkspaceObservation() }
    }

    fileprivate func register(
        intent: ExactActionIntent,
        requestID: String,
        instance: ApplicationInstanceInfo,
        projection: ExactActionTargetProjection,
        foregroundProcessID: Int32,
        lifetime: TimeInterval
    ) -> ExactActionResolutionRecord {
        attachAXObserver(pid: instance.processID)
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        let resolutionID = "action_\(UUID().uuidString)"
        let record = ExactActionResolutionRecord(
            resolutionID: resolutionID,
            resolveRequestID: requestID,
            intent: intent,
            instance: instance,
            projection: projection,
            targetGeneration: targetGenerations[instance.processID, default: 0],
            foregroundGeneration: foregroundGeneration,
            foregroundProcessID: foregroundProcessID,
            expiresAt: now().addingTimeInterval(lifetime)
        )
        resolutions[resolutionID] = record
        return record
    }

    fileprivate func consume(_ resolutionID: String) throws -> ExactActionResolutionRecord {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        consumed = consumed.filter { $0.value > current }
        if consumed[resolutionID] != nil { throw ExactActionIntentError.resolutionAlreadyUsed }
        guard let record = resolutions.removeValue(forKey: resolutionID) else {
            throw ExactActionIntentError.resolutionNotFound
        }
        consumed[resolutionID] = record.expiresAt.addingTimeInterval(30)
        guard record.expiresAt > current else { throw ExactActionIntentError.resolutionExpired }
        guard targetGenerations[record.instance.processID, default: 0] == record.targetGeneration else {
            throw ExactActionIntentError.targetChanged
        }
        guard foregroundGeneration == record.foregroundGeneration else {
            throw ExactActionIntentError.foregroundRace
        }
        return record
    }

    public func invalidate(processID: pid_t) {
        lock.lock()
        targetGenerations[processID, default: 0] &+= 1
        lock.unlock()
    }

    public func noteForegroundChange() {
        lock.lock()
        foregroundGeneration &+= 1
        lock.unlock()
    }

    public func currentForegroundGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return foregroundGeneration
    }

    public func shutdown() {
        if let center = workspaceNotificationCenter {
            workspaceObservers.forEach(center.removeObserver)
        }
        workspaceObservers.removeAll()
        for observer in axObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObservers.removeAll()
        lock.lock()
        resolutions.removeAll()
        consumed.removeAll()
        lock.unlock()
    }

    private func startWorkspaceObservation() {
        guard let center = workspaceNotificationCenter else { return }
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.noteForegroundChange() },
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.invalidate(processID: self?.applicationPID(from: notification) ?? -1)
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.invalidate(processID: self?.applicationPID(from: notification) ?? -1)
            }
        ]
    }

    private func attachAXObserver(pid: pid_t) {
        guard workspaceNotificationCenter != nil else { return }
        lock.lock()
        let alreadyAttached = axObservers[pid] != nil
        lock.unlock()
        guard !alreadyAttached else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [CFString] = [
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXTitleChangedNotification as CFString
        ]
        for notification in notifications {
            _ = AXObserverAddNotification(created, application, notification, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        lock.lock()
        axObservers[pid] = created
        lock.unlock()
    }

    private func applicationPID(from notification: Notification) -> pid_t {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .processIdentifier ?? -1
    }

    private static let axCallback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }
        Unmanaged<EphemeralTargetGraph>.fromOpaque(refcon).takeUnretainedValue()
            .invalidate(processID: pid)
    }

    private func pruneLocked() {
        let current = now()
        resolutions = resolutions.filter { $0.value.expiresAt > current }
        consumed = consumed.filter { $0.value > current }
    }

    deinit { shutdown() }
}

public final class ExactActionIntentController: ExactActionIntentControlling {
    public static let route = "exact_background_accessibility_press"
    private let graph: EphemeralTargetGraph
    private let resolveApplicationTarget: (ApplicationTargetSelector) throws -> ApplicationInstanceInfo
    private let windowInspector: NativeWindowTargetInspecting
    private let displayProvider: NativeWindowDisplayProviding
    private let accessibility: ExactAccessibilityActionPerforming
    private let foregroundApplication: () -> AppInfo?
    private let now: () -> Date
    private let poll: (TimeInterval) -> Void
    private let resolutionLifetime: TimeInterval

    public init(
        graph: EphemeralTargetGraph = EphemeralTargetGraph(),
        resolveApplicationTarget: @escaping (ApplicationTargetSelector) throws -> ApplicationInstanceInfo,
        windowInspector: NativeWindowTargetInspecting,
        displayProvider: NativeWindowDisplayProviding,
        accessibility: ExactAccessibilityActionPerforming,
        foregroundApplication: @escaping () -> AppInfo?,
        now: @escaping () -> Date = Date.init,
        poll: @escaping (TimeInterval) -> Void = { interval in
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        },
        resolutionLifetime: TimeInterval = 30
    ) {
        self.graph = graph
        self.resolveApplicationTarget = resolveApplicationTarget
        self.windowInspector = windowInspector
        self.displayProvider = displayProvider
        self.accessibility = accessibility
        self.foregroundApplication = foregroundApplication
        self.now = now
        self.poll = poll
        self.resolutionLifetime = min(max(resolutionLifetime, 1), 30)
    }

    public func resolve(
        _ intent: ExactActionIntent,
        requestID: String
    ) throws -> ExactActionResolutionReport {
        try validate(intent)
        let foreground = try foregroundOrFail()
        let instance = try normalize {
            try resolveApplicationTarget(ApplicationTargetSelector(
                application: intent.target.application,
                processID: intent.target.processID,
                instanceRef: intent.target.instanceRef,
                windowRef: intent.target.windowRef
            ))
        }
        guard instance.processID == intent.target.processID,
              instance.instanceRef == intent.target.instanceRef else {
            throw ExactActionIntentError.targetChanged
        }
        guard foreground.processID != instance.processID else {
            throw ExactActionIntentError.unsupported("the zero-focus target must not own the foreground")
        }
        let window = try inspectWindow(intent, pid: instance.processID)
        guard window.unique, window.visible, !window.minimized else {
            throw ExactActionIntentError.targetChanged
        }
        let actionability = try normalize {
            try accessibility.inspectPressTarget(
                pid: instance.processID,
                windowRef: intent.target.windowRef,
                selector: intent.target.selector.selector
            )
        }
        let alreadySatisfied = try normalize {
            try accessibility.elementExists(
                pid: instance.processID,
                windowRef: intent.target.windowRef,
                selector: intent.desiredState.selector.selector,
                maxNodes: AccessibilityResolutionBounds.maximumNodes
            )
        }
        guard alreadySatisfied != intent.desiredState.exists else {
            throw ExactActionIntentError.invalid("desired_state is already satisfied")
        }
        let projection = ExactActionTargetProjection(
            application: instance.name,
            bundleID: instance.bundleID,
            processID: instance.processID,
            instanceRef: intent.target.instanceRef,
            windowRef: intent.target.windowRef,
            selectorFields: intent.target.selector.fields,
            locatorDigest: actionability.locatorDigest
        )
        let record = graph.register(
            intent: intent,
            requestID: requestID,
            instance: instance,
            projection: projection,
            foregroundProcessID: foreground.processID!,
            lifetime: resolutionLifetime
        )
        return ExactActionResolutionReport(
            resolutionID: record.resolutionID,
            resolveRequestID: requestID,
            route: Self.route,
            focusPolicy: .background,
            foregroundBudget: 0,
            oneShot: true,
            graphGeneration: record.targetGeneration,
            expiresAt: record.expiresAt,
            target: projection
        )
    }

    public func run(resolutionID: String) throws -> ExactActionExecutionReport {
        let record = try graph.consume(resolutionID)
        let executionForegroundGeneration = graph.currentForegroundGeneration()
        try assertForeground(record)
        let instance = try normalize {
            try resolveApplicationTarget(ApplicationTargetSelector(
                application: record.intent.target.application,
                processID: record.intent.target.processID,
                instanceRef: record.intent.target.instanceRef,
                windowRef: record.intent.target.windowRef
            ))
        }
        guard instance.processID == record.instance.processID,
              instance.instanceRef == record.instance.instanceRef else {
            throw ExactActionIntentError.targetChanged
        }
        _ = try inspectWindow(record.intent, pid: instance.processID)
        _ = try normalize {
            try accessibility.inspectPressTarget(
                pid: instance.processID,
                windowRef: record.intent.target.windowRef,
                selector: record.intent.target.selector.selector
            )
        }
        try assertForeground(record)
        let dispatchResult = try normalize {
            try accessibility.press(
                pid: instance.processID,
                windowRef: record.intent.target.windowRef,
                selector: record.intent.target.selector.selector
            )
        }

        let deadline = now().addingTimeInterval(record.intent.verificationTimeout)
        var observed = false
        repeat {
            try assertForeground(record)
            observed = try normalize {
                try accessibility.elementExists(
                    pid: instance.processID,
                    windowRef: record.intent.target.windowRef,
                    selector: record.intent.desiredState.selector.selector,
                    maxNodes: AccessibilityResolutionBounds.maximumNodes
                )
            }
            if observed == record.intent.desiredState.exists { break }
            poll(0.05)
        } while now() < deadline

        guard observed == record.intent.desiredState.exists else {
            if case .indeterminate(let code) = dispatchResult {
                throw ExactActionIntentError.dispatchIndeterminate(code)
            }
            throw ExactActionIntentError.noObservedChange
        }
        _ = try inspectWindow(record.intent, pid: instance.processID)
        try assertForeground(record)
        guard graph.currentForegroundGeneration() == executionForegroundGeneration else {
            throw ExactActionIntentError.foregroundRace
        }
        let dispatchStatus: String
        let nativeDispatchCode: Int32?
        let verification: String
        switch dispatchResult {
        case .accepted:
            dispatchStatus = "accepted"
            nativeDispatchCode = nil
            verification = "desired_state_observed"
        case .indeterminate(let code):
            dispatchStatus = "indeterminate_but_verified"
            nativeDispatchCode = code
            verification = "desired_state_observed_after_indeterminate_dispatch"
        }
        return ExactActionExecutionReport(
            resolutionID: record.resolutionID,
            resolveRequestID: record.resolveRequestID,
            route: Self.route,
            focusPolicy: .background,
            foregroundBudget: 0,
            dispatchStatus: dispatchStatus,
            nativeDispatchCode: nativeDispatchCode,
            verification: verification,
            foregroundPreserved: true,
            target: record.projection
        )
    }

    public func shutdown() { graph.shutdown() }

    private func validate(_ intent: ExactActionIntent) throws {
        guard intent.schemaVersion == 1 else { throw ExactActionIntentError.invalid("schema_version must be 1") }
        guard intent.action == .press else { throw ExactActionIntentError.unsupported("only press is available") }
        guard intent.focusPolicy == .background, intent.foregroundBudget == 0 else {
            throw ExactActionIntentError.unsupported("the vertical slice requires focus_policy=background and foreground_budget=0")
        }
        guard intent.risk == .safe else {
            throw ExactActionIntentError.unsupported("sensitive or destructive intents remain on the approved task surfaces")
        }
        guard intent.target.processID > 0,
              !intent.target.application.isEmpty,
              !intent.target.instanceRef.isEmpty,
              !intent.target.windowRef.isEmpty else {
            throw ExactActionIntentError.invalid("application, process_id, instance_ref, and window_ref are required")
        }
        guard intent.target.selector.hasStableIdentity else {
            throw ExactActionIntentError.invalid("the mutation selector requires identifier or locator_digest")
        }
        guard intent.desiredState.selector.selector.hasTarget else {
            throw ExactActionIntentError.invalid("desired_state.selector is required")
        }
        guard (0.05...3).contains(intent.verificationTimeout) else {
            throw ExactActionIntentError.invalid("verification_timeout must be between 0.05 and 3 seconds")
        }
    }

    private func inspectWindow(_ intent: ExactActionIntent, pid: pid_t) throws -> NativeWindowTargetSnapshot {
        try normalize {
            try windowInspector.inspectWindow(
                pid: pid,
                windowRef: intent.target.windowRef,
                displays: displayProvider.connectedDisplays()
            )
        }
    }

    private func foregroundOrFail() throws -> AppInfo {
        guard let foreground = foregroundApplication(), foreground.processID != nil else {
            throw ExactActionIntentError.verificationUnavailable
        }
        return foreground
    }

    private func assertForeground(_ record: ExactActionResolutionRecord) throws {
        guard foregroundApplication()?.processID == record.foregroundProcessID else {
            throw ExactActionIntentError.foregroundRace
        }
    }

    private func normalize<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as ExactActionIntentError { throw error }
        catch let error as ApplicationTargetResolutionError {
            switch error {
            case .targetMissing: throw ExactActionIntentError.targetMissing
            case .targetAmbiguous(let count): throw ExactActionIntentError.targetAmbiguous(count)
            case .targetChanged: throw ExactActionIntentError.targetChanged
            }
        }
        catch let error as NativeWindowControlError {
            switch error {
            case .targetMissing: throw ExactActionIntentError.targetMissing
            case .targetAmbiguous: throw ExactActionIntentError.targetAmbiguous(nil)
            case .permissionDenied: throw AccessibilityControllerError.permissionDenied
            case .verificationUnavailable: throw ExactActionIntentError.verificationUnavailable
            default: throw ExactActionIntentError.targetChanged
            }
        }
        catch let error as AccessibilityControllerError {
            switch error {
            case .elementNotFound, .windowNotFound, .applicationNotRunning:
                throw ExactActionIntentError.targetMissing
            case .ambiguousMatch(let count), .ambiguousWindowMatch(let count):
                throw ExactActionIntentError.targetAmbiguous(count)
            case .actionUnavailable, .semanticActivationUnavailable:
                throw ExactActionIntentError.actionUnavailable
            case .resolutionIncomplete, .unreadableFocus:
                throw ExactActionIntentError.verificationUnavailable
            default: throw error
            }
        }
        catch { throw error }
    }
}
