import AppKit
import CoreGraphics
import Foundation

public enum ControlActionRoute: String, Codable, Equatable, Hashable {
    case accessibility
    case keyboard
    case visual
    case normalizedCoordinate = "normalized_coordinate"
    case rawCoordinate = "raw_coordinate"
    case scroll
}

public enum ControlVerificationState: String, Codable, Equatable {
    case passed
    case foregroundOnly = "foreground_only"
}

public struct ControlObservation: Equatable {
    public let foregroundApplication: AppInfo?
    public let focusedElement: FocusedElementSnapshot?

    public init(
        foregroundApplication: AppInfo?,
        focusedElement: FocusedElementSnapshot?
    ) {
        self.foregroundApplication = foregroundApplication
        self.focusedElement = focusedElement
    }
}

public enum ControlStateVerifierError: Error, LocalizedError, Equatable {
    case invalidPolicy
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "Control verification timeout and polling interval are outside the supported range"
        case .timedOut:
            return "The expected macOS control state was not observed before the verification timeout"
        }
    }
}

/// A small, testable wait primitive for post-action state verification.
///
/// The control plane reads only foreground identity and redacted Accessibility metadata.
/// It never waits on or persists AX values, document text, screenshots, or child trees.
public final class ControlStateVerifier {
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let eventMonitor: ControlEventMonitoring?

    public init(
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        eventMonitor: ControlEventMonitoring? = nil
    ) {
        self.now = now
        self.sleep = sleep
        self.eventMonitor = eventMonitor
    }

    public func waitUntil(
        timeout: TimeInterval = 1.0,
        pollInterval: TimeInterval = 0.05,
        consecutiveMatches: Int = 1,
        read: () throws -> ControlObservation,
        predicate: (ControlObservation) -> Bool
    ) throws -> ControlObservation {
        guard (0...30).contains(timeout),
              (0.001...1).contains(pollInterval),
              (1...20).contains(consecutiveMatches) else {
            throw ControlStateVerifierError.invalidPolicy
        }

        let deadline = now().addingTimeInterval(timeout)
        let eventLock = NSLock()
        var eventSignaled = false
        eventMonitor?.start {
            eventLock.lock()
            eventSignaled = true
            eventLock.unlock()
        }
        defer { eventMonitor?.stop() }
        var matchingReads = 0
        while true {
            if let observation = try? read() {
                if predicate(observation) {
                    matchingReads += 1
                    if matchingReads >= consecutiveMatches {
                        return observation
                    }
                } else {
                    matchingReads = 0
                }
            }
            guard now() < deadline else { break }
            eventLock.lock()
            let shouldPollImmediately = eventSignaled
            eventSignaled = false
            eventLock.unlock()
            if !shouldPollImmediately {
                sleep(min(pollInterval, max(0, deadline.timeIntervalSince(now()))))
            }
        }
        throw ControlStateVerifierError.timedOut
    }
}

public struct ControlActionVerification: Codable, Equatable {
    public let state: ControlVerificationState
    public let foregroundBefore: AppInfo
    public let foregroundAfter: AppInfo
    public let foregroundChanged: Bool
    public let focusBefore: FocusedElementSnapshot?
    public let focusAfter: FocusedElementSnapshot?
    public let focusChanged: Bool

    public init(
        state: ControlVerificationState,
        foregroundBefore: AppInfo,
        foregroundAfter: AppInfo,
        foregroundChanged: Bool,
        focusBefore: FocusedElementSnapshot?,
        focusAfter: FocusedElementSnapshot?,
        focusChanged: Bool
    ) {
        self.state = state
        self.foregroundBefore = foregroundBefore
        self.foregroundAfter = foregroundAfter
        self.foregroundChanged = foregroundChanged
        self.focusBefore = focusBefore
        self.focusAfter = focusAfter
        self.focusChanged = focusChanged
    }
}

public struct ControlSessionSnapshot: Codable, Equatable {
    public let sessionID: String
    public let startedAt: Date
    public let foregroundApplication: AppInfo?
    public let focusedElement: FocusedElementSnapshot?
    public let keyboardLeaseActive: Bool
    public let keyboardLeaseExpiresAt: Date?
    public let lastAction: String?
    public let lastRoute: ControlActionRoute?
    public let lastVerification: ControlVerificationState?

    public init(
        sessionID: String,
        startedAt: Date,
        foregroundApplication: AppInfo?,
        focusedElement: FocusedElementSnapshot?,
        keyboardLeaseActive: Bool,
        keyboardLeaseExpiresAt: Date?,
        lastAction: String?,
        lastRoute: ControlActionRoute?,
        lastVerification: ControlVerificationState?
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.foregroundApplication = foregroundApplication
        self.focusedElement = focusedElement
        self.keyboardLeaseActive = keyboardLeaseActive
        self.keyboardLeaseExpiresAt = keyboardLeaseExpiresAt
        self.lastAction = lastAction
        self.lastRoute = lastRoute
        self.lastVerification = lastVerification
    }
}

public struct SemanticActionReport: Codable, Equatable {
    public let action: String
    public let route: ControlActionRoute
    public let fallbackUsed: Bool
    public let keyCount: Int
    public let targetApplication: AppInfo
    public let verification: ControlActionVerification
    public let fallbackChain: [ControlActionRoute]
    public let routeSelection: RouteSelectionReport?

    public init(
        action: String,
        route: ControlActionRoute,
        fallbackUsed: Bool,
        keyCount: Int,
        targetApplication: AppInfo,
        verification: ControlActionVerification,
        fallbackChain: [ControlActionRoute] = [],
        routeSelection: RouteSelectionReport? = nil
    ) {
        self.action = action
        self.route = route
        self.fallbackUsed = fallbackUsed
        self.keyCount = keyCount
        self.targetApplication = targetApplication
        self.verification = verification
        self.fallbackChain = fallbackChain
        self.routeSelection = routeSelection
    }
}

public struct ControlActionContext {
    public let lease: KeyboardDriveLease
    public let foregroundApplication: AppInfo
    public let focusedElement: FocusedElementSnapshot?

    fileprivate let requiresFullKeyboardAccess: Bool

    fileprivate init(
        lease: KeyboardDriveLease,
        foregroundApplication: AppInfo,
        focusedElement: FocusedElementSnapshot?,
        requiresFullKeyboardAccess: Bool
    ) {
        self.lease = lease
        self.foregroundApplication = foregroundApplication
        self.focusedElement = focusedElement
        self.requiresFullKeyboardAccess = requiresFullKeyboardAccess
    }
}

public final class ControlSession {
    private let keyboardDriveStore: KeyboardDriveStore
    private let focusedElementInspector: FocusedElementInspecting
    private let foregroundApplication: () -> AppInfo?
    private let hasPostEventAccess: () -> Bool
    private let fullKeyboardAccessEnabled: () -> Bool
    private let verifier: ControlStateVerifier
    private let postActionTimeout: TimeInterval
    private let sessionID: String
    private let startedAt: Date
    private let lock = NSLock()

    private var lastAction: String?
    private var lastRoute: ControlActionRoute?
    private var lastVerification: ControlVerificationState?

    public init(
        keyboardDriveStore: KeyboardDriveStore,
        focusedElementInspector: FocusedElementInspecting,
        foregroundApplication: @escaping () -> AppInfo?,
        hasPostEventAccess: @escaping () -> Bool,
        fullKeyboardAccessEnabled: @escaping () -> Bool,
        verifier: ControlStateVerifier? = nil,
        postActionTimeout: TimeInterval = 0.5,
        sessionID: String = UUID().uuidString,
        startedAt: Date = Date()
    ) {
        self.keyboardDriveStore = keyboardDriveStore
        self.focusedElementInspector = focusedElementInspector
        self.foregroundApplication = foregroundApplication
        self.hasPostEventAccess = hasPostEventAccess
        self.fullKeyboardAccessEnabled = fullKeyboardAccessEnabled
        self.verifier = verifier ?? ControlStateVerifier(
            eventMonitor: CompositeControlEventMonitor(monitors: [
                WorkspaceControlEventMonitor(),
                AccessibilityControlEventMonitor(foregroundApplication: foregroundApplication)
            ])
        )
        self.postActionTimeout = min(max(postActionTimeout, 0), 30)
        self.sessionID = sessionID
        self.startedAt = startedAt
    }

    public func snapshot() -> ControlSessionSnapshot {
        let foreground = foregroundApplication()
        let focus = focusedElement(for: foreground)
        let lease = keyboardDriveStore.activeLease()
        lock.lock()
        let action = lastAction
        let route = lastRoute
        let verification = lastVerification
        lock.unlock()
        return ControlSessionSnapshot(
            sessionID: sessionID,
            startedAt: startedAt,
            foregroundApplication: foreground,
            focusedElement: focus,
            keyboardLeaseActive: lease != nil,
            keyboardLeaseExpiresAt: lease?.expiresAt,
            lastAction: action,
            lastRoute: route,
            lastVerification: verification
        )
    }

    public func beginAction(
        leaseToken: String,
        requireFullKeyboardAccess: Bool
    ) throws -> ControlActionContext {
        guard !leaseToken.isEmpty else { throw KeyboardControlError.leaseRequired }
        let lease = try keyboardDriveStore.lease(for: leaseToken)
        guard hasPostEventAccess() else {
            throw KeyboardControlError.permissionDenied("Post Events")
        }
        guard let application = foregroundApplication(), application.processID != nil else {
            throw KeyboardControlError.foregroundUnavailable
        }
        try validateScope(lease, against: application)
        if requireFullKeyboardAccess, !fullKeyboardAccessEnabled() {
            throw KeyboardControlError.fullKeyboardAccessDisabled
        }
        return ControlActionContext(
            lease: lease,
            foregroundApplication: application,
            focusedElement: focusedElement(for: application),
            requiresFullKeyboardAccess: requireFullKeyboardAccess
        )
    }

    @discardableResult
    public func revalidate(_ context: ControlActionContext) throws -> AppInfo {
        let lease = try keyboardDriveStore.lease(for: context.lease.token)
        guard hasPostEventAccess() else {
            throw KeyboardControlError.permissionDenied("Post Events")
        }
        guard let application = foregroundApplication(), application.processID != nil else {
            throw KeyboardControlError.foregroundUnavailable
        }
        try validateScope(lease, against: application)
        if context.requiresFullKeyboardAccess, !fullKeyboardAccessEnabled() {
            throw KeyboardControlError.fullKeyboardAccessDisabled
        }
        return application
    }

    public func completeAction(
        _ context: ControlActionContext,
        action: String,
        route: ControlActionRoute,
        requireFocusChange: Bool = false
    ) throws -> ControlActionVerification {
        _ = try revalidate(context)
        let readObservation = { [self] in
            let foreground = foregroundApplication()
            return ControlObservation(
                foregroundApplication: foreground,
                focusedElement: focusedElement(for: foreground)
            )
        }
        let observation: ControlObservation
        do {
            observation = try verifier.waitUntil(
                timeout: postActionTimeout,
                read: readObservation,
                predicate: {
                    guard $0.foregroundApplication?.processID != nil else { return false }
                    return !requireFocusChange || context.focusedElement != $0.focusedElement
                }
            )
        } catch ControlStateVerifierError.timedOut {
            observation = readObservation()
        }
        guard let after = observation.foregroundApplication else {
            throw KeyboardControlError.foregroundUnavailable
        }
        try _ = revalidate(context)
        try validateScope(context.lease, against: after)
        let focusChanged = context.focusedElement != observation.focusedElement
        let verification = ControlActionVerification(
            state: focusChanged ? .passed : .foregroundOnly,
            foregroundBefore: context.foregroundApplication,
            foregroundAfter: after,
            foregroundChanged: !sameApplication(context.foregroundApplication, after),
            focusBefore: context.focusedElement,
            focusAfter: observation.focusedElement,
            focusChanged: focusChanged
        )
        lock.lock()
        lastAction = action
        lastRoute = route
        lastVerification = verification.state
        lock.unlock()
        return verification
    }

    private func focusedElement(for application: AppInfo?) -> FocusedElementSnapshot? {
        guard let application, let pid = application.processID else { return nil }
        return try? focusedElementInspector.focusedElementSnapshot(pid: pid, application: application)
    }

    private func validateScope(_ lease: KeyboardDriveLease, against application: AppInfo) throws {
        guard lease.scope == .app else { return }
        guard let expected = lease.application,
              sameApplication(expected, application, requireProcess: true) else {
            throw KeyboardControlError.appScopeMismatch(
                expected: applicationLabel(lease.application),
                actual: applicationLabel(application)
            )
        }
    }

    private func sameApplication(
        _ lhs: AppInfo,
        _ rhs: AppInfo,
        requireProcess: Bool
    ) -> Bool {
        if requireProcess, lhs.processID != rhs.processID { return false }
        if let lhsBundle = lhs.bundleID, let rhsBundle = rhs.bundleID {
            return lhsBundle == rhsBundle
        }
        return lhs.path == rhs.path
    }

    private func sameApplication(_ lhs: AppInfo, _ rhs: AppInfo) -> Bool {
        sameApplication(lhs, rhs, requireProcess: false)
    }

    private func applicationLabel(_ application: AppInfo?) -> String {
        application?.bundleID ?? application?.path ?? application?.name ?? "none"
    }
}

public protocol AccessibilityActionPerforming {
    @discardableResult
    func press(pid: pid_t, selector: Selector) throws -> CGRect
}

extension AccessibilityController: AccessibilityActionPerforming {}

public protocol VisualActionPerforming {
    @discardableResult
    func activate(selector: Selector, application: AppInfo) throws -> CGRect
}

public final class VisualControlFallback: VisualActionPerforming {
    private let captureController: CaptureController
    private let inputController: InputController

    public init(
        captureController: CaptureController = CaptureController(),
        inputController: InputController = InputController()
    ) {
        self.captureController = captureController
        self.inputController = inputController
    }

    @discardableResult
    public func activate(selector: Selector, application: AppInfo) throws -> CGRect {
        switch selector.addressability {
        case .visual:
            let frame = try captureController.capture(surface: .macApp, app: application.name)
            if let text = selector.containsText {
                let ocr = try captureController.ocr(frame)
                guard let match = ocr.matches.first(where: {
                    $0.text.localizedCaseInsensitiveContains(text)
                }) else {
                    throw CaptureControllerError.ocrFailed("visual text anchor was not found")
                }
                try inputController.click(at: CGPoint(x: match.bounds.midX, y: match.bounds.midY))
                return match.bounds
            }
            if let imageAnchor = selector.imageAnchor {
                let match = try captureController.findImageAnchor(in: frame, path: imageAnchor)
                try inputController.click(at: CGPoint(x: match.bounds.midX, y: match.bounds.midY))
                return match.bounds
            }
            throw CaptureControllerError.ocrFailed("visual selector has no supported anchor")
        case .normalizedCoordinate:
            guard let x = selector.normalizedX, let y = selector.normalizedY else {
                throw InputControllerError.invalidCoordinate
            }
            let frame = try captureController.capture(surface: .macApp, app: application.name)
            let point = try CoordinateMapper.windowPoint(
                normalized: NormalizedPoint(x: x, y: y),
                in: frame.bounds
            )
            try inputController.click(at: point)
            return CGRect(x: point.x, y: point.y, width: 0, height: 0)
        case .rawCoordinate:
            guard let x = selector.rawX, let y = selector.rawY else {
                throw InputControllerError.invalidCoordinate
            }
            let point = CGPoint(x: x, y: y)
            try inputController.click(at: point)
            return CGRect(x: point.x, y: point.y, width: 0, height: 0)
        case .accessibility:
            throw AccessibilityControllerError.elementNotFound
        }
    }
}

public enum SemanticActionRouterError: Error, LocalizedError, Equatable {
    case invalidSelector
    case selectorRequiresActivate
    case rawCoordinateRequiresExplicitOptIn

    public var errorDescription: String? {
        switch self {
        case .invalidSelector:
            return "The semantic action selector is empty or malformed"
        case .selectorRequiresActivate:
            return "Visual and coordinate selectors can only be used with the activate action"
        case .rawCoordinateRequiresExplicitOptIn:
            return "Raw coordinate fallback requires an explicit opt-in"
        }
    }
}

public final class SemanticActionRouter {
    private let session: ControlSession
    private let keyboardAccessController: KeyboardAccessController
    private let accessibilityActionController: AccessibilityActionPerforming
    private let visualActionController: VisualActionPerforming

    public init(
        session: ControlSession,
        keyboardAccessController: KeyboardAccessController,
        accessibilityActionController: AccessibilityActionPerforming,
        visualActionController: VisualActionPerforming
    ) {
        self.session = session
        self.keyboardAccessController = keyboardAccessController
        self.accessibilityActionController = accessibilityActionController
        self.visualActionController = visualActionController
    }

    public func perform(
        command: KeyboardCommand,
        selector: Selector?,
        leaseToken: String,
        count: Int,
        interKeyDelay: TimeInterval,
        allowRawCoordinate: Bool,
        requestedRoute: ControlActionRoute? = nil,
        fallbackChain: [ControlActionRoute] = [],
        routeSelection: RouteSelectionReport? = nil
    ) throws -> SemanticActionReport {
        if let selector, !selector.hasTarget {
            throw SemanticActionRouterError.invalidSelector
        }
        let initialRoute = requestedRoute ?? routeForSelector(selector)
        let routes = deduplicatedRoutes([initialRoute] + fallbackChain)
        var lastPreActionError: AccessibilityControllerError?
        for (index, route) in routes.enumerated() {
            do {
                return try perform(
                    route: route,
                    command: command,
                    selector: selector,
                    leaseToken: leaseToken,
                    count: count,
                    interKeyDelay: interKeyDelay,
                    allowRawCoordinate: allowRawCoordinate,
                    fallbackUsed: index > 0,
                    fallbackChain: Array(routes.dropFirst()),
                    routeSelection: routeSelection
                )
            } catch let error as AccessibilityControllerError {
                // A missing target is the only pre-action failure that can
                // advance through an explicitly declared chain. Ambiguity,
                // action failure, and verification failures stop immediately.
                if case .elementNotFound = error, index + 1 < routes.count {
                    lastPreActionError = error
                    continue
                }
                throw error
            }
        }
        if let lastPreActionError { throw lastPreActionError }
        throw SemanticActionRouterError.invalidSelector
    }

    private func perform(
        route: ControlActionRoute,
        command: KeyboardCommand,
        selector: Selector?,
        leaseToken: String,
        count: Int,
        interKeyDelay: TimeInterval,
        allowRawCoordinate: Bool,
        fallbackUsed: Bool,
        fallbackChain: [ControlActionRoute],
        routeSelection: RouteSelectionReport?
    ) throws -> SemanticActionReport {
        switch route {
        case .accessibility:
            guard command == .activate, let selector,
                  selector.addressability == .accessibility else {
                throw SemanticActionRouterError.invalidSelector
            }
            let context = try session.beginAction(
                leaseToken: leaseToken,
                requireFullKeyboardAccess: false
            )
            guard let pid = context.foregroundApplication.processID else {
                throw KeyboardControlError.foregroundUnavailable
            }
            _ = try session.revalidate(context)
            _ = try accessibilityActionController.press(pid: pid, selector: selector)
            let verification = try session.completeAction(
                context,
                action: command.rawValue,
                route: .accessibility
            )
            return SemanticActionReport(
                action: command.rawValue,
                route: .accessibility,
                fallbackUsed: fallbackUsed,
                keyCount: 0,
                targetApplication: verification.foregroundAfter,
                verification: verification,
                fallbackChain: fallbackChain,
                routeSelection: routeSelection
            )
        case .keyboard:
            return try keyboard(
                command: command,
                leaseToken: leaseToken,
                count: count,
                interKeyDelay: interKeyDelay,
                fallbackUsed: fallbackUsed,
                fallbackChain: fallbackChain,
                routeSelection: routeSelection
            )
        case .visual, .normalizedCoordinate, .rawCoordinate:
            guard command == .activate, let selector,
                  selector.hasTarget else {
                throw SemanticActionRouterError.selectorRequiresActivate
            }
            let selectorRoute: ControlActionRoute = switch selector.addressability {
            case .visual: .visual
            case .normalizedCoordinate: .normalizedCoordinate
            case .rawCoordinate: .rawCoordinate
            case .accessibility: .accessibility
            }
            guard selectorRoute == route || (route == .visual && selector.addressability == .visual) else {
                throw SemanticActionRouterError.invalidSelector
            }
            if route == .rawCoordinate, !allowRawCoordinate {
                throw SemanticActionRouterError.rawCoordinateRequiresExplicitOptIn
            }
            let context = try session.beginAction(
                leaseToken: leaseToken,
                requireFullKeyboardAccess: false
            )
            _ = try session.revalidate(context)
            _ = try visualActionController.activate(
                selector: selector,
                application: context.foregroundApplication
            )
            let verification = try session.completeAction(
                context,
                action: command.rawValue,
                route: route
            )
            return SemanticActionReport(
                action: command.rawValue,
                route: route,
                fallbackUsed: fallbackUsed,
                keyCount: 0,
                targetApplication: verification.foregroundAfter,
                verification: verification,
                fallbackChain: fallbackChain,
                routeSelection: routeSelection
            )
        case .scroll:
            throw SemanticActionRouterError.selectorRequiresActivate
        }
    }

    private func keyboard(
        command: KeyboardCommand,
        leaseToken: String,
        count: Int,
        interKeyDelay: TimeInterval,
        fallbackUsed: Bool,
        fallbackChain: [ControlActionRoute],
        routeSelection: RouteSelectionReport?
    ) throws -> SemanticActionReport {
        let context = try session.beginAction(
            leaseToken: leaseToken,
            requireFullKeyboardAccess: true
        )
        let report = try keyboardAccessController.send(
            command: command,
            count: count,
            targetApplication: context.foregroundApplication,
            leaseExpiresAt: context.lease.expiresAt,
            interKeyDelay: interKeyDelay,
            beforeEach: { [session] _ in
                _ = try session.revalidate(context)
            }
        )
        let verification = try session.completeAction(
            context,
            action: command.rawValue,
            route: .keyboard,
            requireFocusChange: command.expectsFocusChange
        )
        return SemanticActionReport(
            action: report.action,
            route: .keyboard,
            fallbackUsed: fallbackUsed,
            keyCount: report.keyCount,
            targetApplication: verification.foregroundAfter,
            verification: verification,
            fallbackChain: fallbackChain,
            routeSelection: routeSelection
        )
    }

    private func routeForSelector(_ selector: Selector?) -> ControlActionRoute {
        guard let selector else { return .keyboard }
        switch selector.addressability {
        case .accessibility: return .accessibility
        case .visual: return .visual
        case .normalizedCoordinate: return .normalizedCoordinate
        case .rawCoordinate: return .rawCoordinate
        }
    }

    private func deduplicatedRoutes(_ routes: [ControlActionRoute]) -> [ControlActionRoute] {
        var seen = Set<ControlActionRoute>()
        return routes.filter { seen.insert($0).inserted }
    }
}
