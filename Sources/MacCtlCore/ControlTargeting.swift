import AppKit
import CryptoKit
import Foundation

public struct AccessibilityWindowState: Codable, Equatable {
    public let visible: Bool
    public let modal: Bool
    public let identityFingerprint: String?

    public init(visible: Bool, modal: Bool, identityFingerprint: String? = nil) {
        self.visible = visible
        self.modal = modal
        self.identityFingerprint = identityFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case visible, modal, identityFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visible = try container.decode(Bool.self, forKey: .visible)
        modal = try container.decode(Bool.self, forKey: .modal)
        identityFingerprint = try container.decodeIfPresent(String.self, forKey: .identityFingerprint)
    }
}

public struct ControlTargetFingerprint: Codable, Equatable {
    public let application: String
    public let process: String
    public let window: String
    public let focusedElement: String

    public init(application: String, process: String, window: String, focusedElement: String) {
        self.application = application
        self.process = process
        self.window = window
        self.focusedElement = focusedElement
    }

    public var value: String {
        [application, process, window, focusedElement].joined(separator: ":")
    }
}

public struct ControlTargetSnapshot: Codable, Equatable {
    public let application: AppInfo
    public let focusedElement: FocusedElementSnapshot?
    public let fingerprint: ControlTargetFingerprint
    public let windowVisible: Bool
    public let modal: Bool
    public let focusReadable: Bool
    public let hung: Bool

    public init(
        application: AppInfo,
        focusedElement: FocusedElementSnapshot?,
        fingerprint: ControlTargetFingerprint,
        windowVisible: Bool,
        modal: Bool,
        focusReadable: Bool,
        hung: Bool
    ) {
        self.application = application
        self.focusedElement = focusedElement
        self.fingerprint = fingerprint
        self.windowVisible = windowVisible
        self.modal = modal
        self.focusReadable = focusReadable
        self.hung = hung
    }
}

public enum ControlTargetInspectionError: Error, LocalizedError, Equatable {
    case applicationUnavailable
    case unreadableFocus
    case modalDialog
    case hungApplication
    case ambiguousTarget
    case targetChanged

    public var errorDescription: String? {
        switch self {
        case .applicationUnavailable: return "The target application is unavailable"
        case .unreadableFocus: return "The target focused element could not be read"
        case .modalDialog: return "A modal or permission dialog requires explicit handling"
        case .hungApplication: return "The target application did not answer Accessibility queries"
        case .ambiguousTarget: return "The target Accessibility selector matched more than one element"
        case .targetChanged: return "The target application, process, window, or focus changed"
        }
    }
}

public protocol ControlTargetInspecting {
    func inspect(application: AppInfo) throws -> ControlTargetSnapshot
}

public final class AccessibilityTargetInspector: ControlTargetInspecting {
    private let accessibility: AccessibilityController

    public init(accessibility: AccessibilityController = AccessibilityController()) {
        self.accessibility = accessibility
    }

    public func inspect(application: AppInfo) throws -> ControlTargetSnapshot {
        guard let pid = application.processID else {
            throw ControlTargetInspectionError.applicationUnavailable
        }
        let focus: FocusedElementSnapshot?
        do {
            focus = try accessibility.focusedElementSnapshot(pid: pid, application: application)
        } catch AccessibilityControllerError.unreadableFocus {
            throw ControlTargetInspectionError.unreadableFocus
        } catch AccessibilityControllerError.permissionDenied {
            throw ControlTargetInspectionError.unreadableFocus
        } catch {
            focus = nil
        }
        let window: AccessibilityWindowState
        do {
            window = try accessibility.windowState(pid: pid)
        } catch AccessibilityControllerError.permissionDenied {
            throw ControlTargetInspectionError.unreadableFocus
        } catch {
            throw ControlTargetInspectionError.hungApplication
        }
        if window.modal {
            throw ControlTargetInspectionError.modalDialog
        }
        let fingerprint = ControlTargetFingerprints.make(application: application, focus: focus, window: window)
        return ControlTargetSnapshot(
            application: application,
            focusedElement: focus,
            fingerprint: fingerprint,
            windowVisible: window.visible,
            modal: window.modal,
            focusReadable: focus != nil,
            hung: false
        )
    }
}

public enum ControlTargetFingerprints {
    public static func make(
        application: AppInfo,
        focus: FocusedElementSnapshot?,
        window: AccessibilityWindowState
    ) -> ControlTargetFingerprint {
        let applicationValue = digest([
            application.name,
            application.bundleID ?? "",
            application.path
        ].joined(separator: "|"))
        let processValue = digest(String(application.processID ?? 0))
        let windowValue = window.identityFingerprint
            ?? digest("visible=\(window.visible)|modal=\(window.modal)")
        let focusValue = digest([
            focus?.role ?? "",
            focus?.subrole ?? "",
            focus?.identifier ?? "",
            focus?.title ?? ""
        ].joined(separator: "|"))
        return ControlTargetFingerprint(
            application: applicationValue,
            process: processValue,
            window: windowValue,
            focusedElement: focusValue
        )
    }

    public static func make(application: AppInfo, focus: FocusedElementSnapshot?) -> String {
        make(
            application: application,
            focus: focus,
            window: AccessibilityWindowState(visible: true, modal: false)
        ).value
    }

    public static func structuralDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ value: String) -> String {
        structuralDigest(value)
    }
}

public protocol ControlEventMonitoring: AnyObject {
    func start(handler: @escaping () -> Void)
    func stop()
}

/// Workspace notifications provide prompt invalidation after app switches;
/// callers retain bounded polling as the fallback for AX state changes.
public final class WorkspaceControlEventMonitor: ControlEventMonitoring {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var handler: (() -> Void)?

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public func start(handler: @escaping () -> Void) {
        stop()
        self.handler = handler
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handler?()
            }
        }
    }

    public func stop() {
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        handler = nil
    }

    deinit { stop() }
}

/// AX notifications cover focus and window changes that are not represented
/// by NSWorkspace activation events.  The verifier still polls with a bounded
/// interval because an AX observer may not be serviced while an app is hung or
/// a caller is not running a CFRunLoop.
public final class AccessibilityControlEventMonitor: ControlEventMonitoring {
    private let foregroundApplication: () -> AppInfo?
    private let notificationCenter: NotificationCenter
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var workspaceObserver: NSObjectProtocol?
    private var handler: (() -> Void)?

    public init(
        foregroundApplication: @escaping () -> AppInfo?,
        notificationCenter: NotificationCenter = .default
    ) {
        self.foregroundApplication = foregroundApplication
        self.notificationCenter = notificationCenter
    }

    public func start(handler: @escaping () -> Void) {
        stop()
        self.handler = handler
        workspaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachToForeground()
            self?.handler?()
        }
        attachToForeground()
    }

    public func stop() {
        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
        self.observer = nil
        observedPID = nil
        if let workspaceObserver {
            notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        handler = nil
    }

    private func attachToForeground() {
        guard let application = foregroundApplication(), let pid = application.processID else {
            return
        }
        guard observedPID != pid else { return }
        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
        observer = nil
        observedPID = pid
        var createdObserver: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &createdObserver) == .success,
              let createdObserver else {
            return
        }
        let applicationElement = AXUIElementCreateApplication(pid)
        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXTitleChangedNotification as CFString
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            _ = AXObserverAddNotification(createdObserver, applicationElement, notification, context)
        }
        let source = AXObserverGetRunLoopSource(createdObserver)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        observer = createdObserver
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<AccessibilityControlEventMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        monitor.handler?()
    }

    deinit { stop() }
}

public final class CompositeControlEventMonitor: ControlEventMonitoring {
    private let monitors: [ControlEventMonitoring]

    public init(monitors: [ControlEventMonitoring]) {
        self.monitors = monitors
    }

    public func start(handler: @escaping () -> Void) {
        monitors.forEach { $0.start(handler: handler) }
    }

    public func stop() {
        monitors.forEach { $0.stop() }
    }
}

public extension FocusedElementSnapshot {
    var fingerprint: String {
        ControlTargetFingerprints.make(application: targetApplication, focus: self)
    }
}
