import Foundation

public struct ShortcutChord: Codable, Equatable, Hashable {
    public let canonical: String
    public let modifiers: [String]
    public let key: String

    public init(_ value: String, provider: ShortcutProvider? = nil) throws {
        let aliases = [
            "control": "ctrl", "⌃": "ctrl",
            "alt": "option", "opt": "option", "⌥": "option",
            "command": "cmd", "⌘": "cmd",
            "⇧": "shift"
        ]
        let parts = value
            .lowercased()
            .split(separator: "+")
            .map { aliases[String($0).trimmingCharacters(in: .whitespacesAndNewlines)]
                ?? String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, let rawKey = parts.last, !rawKey.isEmpty else {
            throw ShortcutError.invalidChord(value)
        }
        let allowedModifiers = Set(["ctrl", "option", "shift", "cmd", "fn"])
        let modifierSet = Set(parts.dropLast())
        guard modifierSet.count == parts.count - 1,
              modifierSet.isSubset(of: allowedModifiers),
              Self.allowedKey(rawKey) else {
            throw ShortcutError.invalidChord(value)
        }
        if provider == .chromeExtensionCommand, modifierSet.contains("fn") {
            throw ShortcutError.invalidChord(value)
        }
        let highModifierCount = modifierSet.intersection(["ctrl", "option", "cmd"]).count
        guard highModifierCount >= 1 else { throw ShortcutError.invalidChord(value) }
        let ordered = ["ctrl", "option", "shift", "cmd", "fn"].filter(modifierSet.contains)
        modifiers = ordered
        key = rawKey
        canonical = (ordered + [rawKey]).joined(separator: "+")
        do {
            _ = try KeyboardAccessController.validateRawSequence([canonical])
        } catch {
            throw ShortcutError.invalidChord(value)
        }
    }

    private static func allowedKey(_ value: String) -> Bool {
        if value.count == 1 {
            return value.allSatisfy { $0.isLetter || $0.isNumber || "-=[]\\;',./`".contains($0) }
        }
        if value == "space" || value == "return" || value == "tab" { return true }
        if value.hasPrefix("f"), let number = Int(value.dropFirst()) {
            return (1...20).contains(number)
        }
        return ["left", "right", "up", "down", "home", "end", "pageup", "pagedown"].contains(value)
    }
}

public struct ShortcutCollisionReport: Codable, Equatable {
    public let chord: String
    public let conflictingSources: [String]
    public var hasConflict: Bool { !conflictingSources.isEmpty }
}

public enum ShortcutCollisionValidator {
    private static let systemReserved: Set<String> = [
        "cmd+space", "option+cmd+space", "ctrl+space", "ctrl+option+space",
        "shift+cmd+3", "shift+cmd+4", "shift+cmd+5", "ctrl+cmd+q",
        "option+cmd+escape", "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right"
    ]

    public static func validate(
        chord: ShortcutChord,
        targetBindingID: String? = nil,
        appMenuChords: [String],
        bindings: [ShortcutBinding]
    ) -> ShortcutCollisionReport {
        validate(
            chord: chord,
            targetBindingID: targetBindingID,
            appMenuChords: appMenuChords,
            bindings: bindings,
            registeredSystemChords: SystemShortcutRegistrations().enabledChords()
        )
    }

    static func validate(
        chord: ShortcutChord,
        targetBindingID: String? = nil,
        appMenuChords: [String],
        bindings: [ShortcutBinding],
        registeredSystemChords: Set<String>
    ) -> ShortcutCollisionReport {
        var sources: [String] = []
        if systemReserved.contains(chord.canonical) || registeredSystemChords.contains(chord.canonical) {
            sources.append("system_reserved")
        }
        if appMenuChords.contains(where: { normalized($0) == chord.canonical }) {
            sources.append("target_app_menu")
        }
        if bindings.contains(where: { binding in
            guard binding.id != targetBindingID,
                  let raw = binding.chord,
                  let registered = try? ShortcutChord(raw, provider: binding.provider) else { return false }
            return registered.canonical == chord.canonical
        }) {
            sources.append("mac_control_registry")
        }
        return ShortcutCollisionReport(chord: chord.canonical, conflictingSources: sources)
    }

    public static func suggestion(
        provider: ShortcutProvider,
        appMenuChords: [String],
        bindings: [ShortcutBinding]
    ) -> String? {
        let registeredSystemChords = SystemShortcutRegistrations().enabledChords()
        let keys = (1...9).map(String.init) + Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
        for key in keys {
            let raw = "ctrl+option+cmd+\(key)"
            guard let chord = try? ShortcutChord(raw, provider: provider) else { continue }
            if !validate(
                chord: chord,
                appMenuChords: appMenuChords,
                bindings: bindings,
                registeredSystemChords: registeredSystemChords
            ).hasConflict {
                return chord.canonical
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String? {
        try? ShortcutChord(value).canonical
    }
}

struct SystemShortcutRegistrations {
    private let preferencesURL: URL

    init(preferencesURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")) {
        self.preferencesURL = preferencesURL
    }

    func enabledChords() -> Set<String> {
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any],
              let registrations = dictionary["AppleSymbolicHotKeys"] as? [String: Any] else {
            return []
        }
        return Set(registrations.values.compactMap(chord))
    }

    private func chord(_ raw: Any) -> String? {
        guard let registration = raw as? [String: Any],
              registration["enabled"] as? Bool == true,
              let value = registration["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let character = integer(parameters[0]),
              let keyCode = integer(parameters[1]),
              let modifierFlags = integer(parameters[2]),
              let key = keyName(character: character, keyCode: keyCode) else { return nil }
        var modifiers: [String] = []
        if modifierFlags & 0x40000 != 0 { modifiers.append("ctrl") }
        if modifierFlags & 0x80000 != 0 { modifiers.append("option") }
        if modifierFlags & 0x20000 != 0 { modifiers.append("shift") }
        if modifierFlags & 0x100000 != 0 { modifiers.append("cmd") }
        return try? ShortcutChord((modifiers + [key]).joined(separator: "+")).canonical
    }

    private func integer(_ value: Any) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func keyName(character: Int, keyCode: Int) -> String? {
        if (32...126).contains(character), let scalar = UnicodeScalar(character) {
            let key = String(Character(scalar)).lowercased()
            if key == " " { return "space" }
            if key == "\r" { return "return" }
            return key
        }
        return [
            36: "return", 48: "tab", 49: "space",
            115: "home", 116: "pageup", 119: "end", 121: "pagedown",
            123: "left", 124: "right", 125: "down", 126: "up"
        ][keyCode]
    }
}
