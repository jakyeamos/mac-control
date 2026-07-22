import CoreGraphics
import Foundation

public struct DoubleTapDetector {
    public let interval: TimeInterval
    private var lastTap: Date?

    public init(interval: TimeInterval = 0.35) {
        self.interval = interval
    }

    public mutating func register(at time: Date) -> Bool {
        guard let lastTap else {
            self.lastTap = time
            return false
        }
        let elapsed = time.timeIntervalSince(lastTap)
        if elapsed >= 0 && elapsed <= interval {
            self.lastTap = nil
            return true
        }
        self.lastTap = time
        return false
    }

    public mutating func reset() {
        lastTap = nil
    }
}

public final class CapsLockMonitor {
    public let interval: TimeInterval
    public let keyCode: Int64
    public private(set) var isAvailable = false
    public var onDoubleTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector: DoubleTapDetector

    public init(interval: TimeInterval = 0.35, keyCode: Int64 = 57) {
        self.interval = interval
        self.keyCode = keyCode
        self.detector = DoubleTapDetector(interval: interval)
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        guard PermissionDiagnostics.hasListenEventAccess() else {
            isAvailable = false
            return false
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: CapsLockMonitor.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isAvailable = false
            return false
        }
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            eventTap = nil
            isAvailable = false
            return false
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isAvailable = true
        return true
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isAvailable = false
    }

    private func handle(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
        let now = Date()
        if detector.register(at: now) {
            detector.reset()
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleTap?()
            }
        }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<CapsLockMonitor>.fromOpaque(refcon).takeUnretainedValue()
        if type == .keyDown {
            monitor.handle(event)
        }
        return Unmanaged.passUnretained(event)
    }
}
