import AppKit
import CoreGraphics
import Foundation

public enum InputControllerError: Error, LocalizedError {
    case permissionDenied
    case unsupportedKey(String)
    case invalidCoordinate

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "macOS denied synthetic input; grant Accessibility access to the host process"
        case .unsupportedKey(let key):
            return "Unsupported key: \(key)"
        case .invalidCoordinate:
            return "The requested coordinate is outside the available display"
        }
    }
}

public enum MouseButton: String {
    case left
    case right
    case middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

public struct NormalizedPoint: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum CoordinateMapper {
    public static func mainDisplayPoint(_ point: NormalizedPoint) throws -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw InputControllerError.invalidCoordinate
        }
        return CGPoint(
            x: bounds.minX + bounds.width * point.x,
            y: bounds.minY + bounds.height * point.y
        )
    }

    public static func windowPoint(
        normalized point: NormalizedPoint,
        in bounds: CGRect
    ) throws -> CGPoint {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw InputControllerError.invalidCoordinate
        }
        return CGPoint(
            x: bounds.minX + bounds.width * point.x,
            y: bounds.minY + bounds.height * point.y
        )
    }
}

public final class InputController {
    public init() {}

    public func click(at point: CGPoint, button: MouseButton = .left) throws {
        try requirePostEventAccess()
        let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        move?.post(tap: .cghidEventTap)
        let down = CGEvent(
            mouseEventSource: nil,
            mouseType: button.downType,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        )
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: button.upType,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        )
        guard down != nil, up != nil else { throw InputControllerError.permissionDenied }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    public func type(_ text: String) throws {
        try requirePostEventAccess()
        guard !text.isEmpty else { return }
        let utf16 = Array(text.utf16)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            throw InputControllerError.permissionDenied
        }
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        MacCtlKeyboardEventMetadata.markSynthetic(event)
        event.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        if let keyUp {
            MacCtlKeyboardEventMetadata.markSynthetic(keyUp)
        }
        keyUp?.post(tap: .cghidEventTap)
    }

    public func key(_ specification: String) throws {
        try requirePostEventAccess()
        let parsed = try KeySpecification.parse(specification)
        let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: parsed.keyCode,
            keyDown: true
        )
        let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: parsed.keyCode,
            keyDown: false
        )
        for modifier in parsed.modifiers {
            down?.flags.insert(modifier)
            up?.flags.insert(modifier)
        }
        guard let down, let up else { throw InputControllerError.permissionDenied }
        MacCtlKeyboardEventMetadata.markSynthetic(down)
        MacCtlKeyboardEventMetadata.markSynthetic(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    public func key(_ specification: String, toProcess processID: pid_t) throws {
        try requirePostEventAccess()
        let parsed = try KeySpecification.parse(specification)
        let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: parsed.keyCode,
            keyDown: true
        )
        let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: parsed.keyCode,
            keyDown: false
        )
        for modifier in parsed.modifiers {
            down?.flags.insert(modifier)
            up?.flags.insert(modifier)
        }
        guard let down, let up else { throw InputControllerError.permissionDenied }
        MacCtlKeyboardEventMetadata.markSynthetic(down)
        MacCtlKeyboardEventMetadata.markSynthetic(up)
        down.postToPid(processID)
        up.postToPid(processID)
    }

    @discardableResult
    public func scroll(amount: Int32, direction: String) throws -> InputScrollReport {
        try requirePostEventAccess()
        let normalizedDirection = direction.lowercased()
        let delta: Int32
        switch normalizedDirection {
        case "up", "left": delta = abs(amount)
        case "down", "right": delta = -abs(amount)
        default: throw InputControllerError.unsupportedKey(direction)
        }
        let horizontal = normalizedDirection == "left" || normalizedDirection == "right"
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: horizontal ? 0 : delta,
            wheel2: horizontal ? delta : 0,
            wheel3: 0
        ) else {
            throw InputControllerError.permissionDenied
        }
        event.post(tap: .cghidEventTap)
        return InputScrollReport(
            direction: normalizedDirection,
            amount: Int(abs(amount)),
            verification: .verificationUnavailable
        )
    }

    private func requirePostEventAccess() throws {
        guard PermissionDiagnostics.hasPostEventAccess() else {
            throw InputControllerError.permissionDenied
        }
    }
}

extension InputController: InputScrollPerforming {}

public struct KeySpecification: Equatable {
    public let keyCode: CGKeyCode
    public let modifiers: [CGEventFlags]

    public init(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func parse(_ specification: String) throws -> KeySpecification {
        let parts = specification.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else {
            throw InputControllerError.unsupportedKey(specification)
        }
        var modifiers: [CGEventFlags] = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘": modifiers.append(.maskCommand)
            case "ctrl", "control", "^": modifiers.append(.maskControl)
            case "alt", "option", "opt", "⌥": modifiers.append(.maskAlternate)
            case "shift", "⇧": modifiers.append(.maskShift)
            case "fn", "function": modifiers.append(.maskSecondaryFn)
            default: throw InputControllerError.unsupportedKey(specification)
            }
        }

        let keyCodes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "-return": 36,
            "return": 36, "enter": 36, "delete": 51, "escape": 53, "esc": 53,
            "command": 55, "shift": 56, "capslock": 57, "option": 58,
            "control": 59, "rightshift": 60, "rightoption": 61, "rightcontrol": 62,
            "function": 63, "f17": 64, "volumeup": 72, "volumedown": 73,
            "mute": 74, "f18": 79, "f19": 80, "f20": 90, "f5": 96, "f6": 97,
            "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105,
            "f14": 107, "f10": 109, "f12": 111, "home": 115, "pageup": 116,
            "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121,
            "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
        ]
        guard let code = keyCodes[keyName] else {
            throw InputControllerError.unsupportedKey(specification)
        }
        return KeySpecification(keyCode: code, modifiers: modifiers)
    }
}
