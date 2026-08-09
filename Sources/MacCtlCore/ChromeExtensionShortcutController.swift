import ApplicationServices
import Foundation

public struct ChromeExtensionCommandDescriptor: Equatable {
    public let extensionID: String
    public let extensionName: String
    public let commandID: String
    public let commandDescription: String
}

public protocol ChromeExtensionCommandDiscovering {
    func command(extensionID: String, commandID: String) throws -> ChromeExtensionCommandDescriptor
}

public final class ChromeExtensionManifestDiscovery: ChromeExtensionCommandDiscovering {
    private let chromeRoot: URL
    private let fileManager: FileManager

    public init(
        chromeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.chromeRoot = chromeRoot
        self.fileManager = fileManager
    }

    public func command(extensionID: String, commandID: String) throws -> ChromeExtensionCommandDescriptor {
        guard ShortcutValidation.isChromeExtensionID(extensionID) else {
            throw ShortcutError.invalidTarget("invalid Chrome extension ID")
        }
        let profileURLs = (try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for profileURL in profileURLs.sorted(by: { $0.path < $1.path }) {
            let extensionRoot = profileURL
                .appendingPathComponent("Extensions", isDirectory: true)
                .appendingPathComponent(extensionID, isDirectory: true)
            let versions = (try? fileManager.contentsOfDirectory(
                at: extensionRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for versionURL in versions.sorted(by: {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }) {
                let manifestURL = versionURL.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let commands = manifest["commands"] as? [String: Any],
                      let rawCommand = commands[commandID] as? [String: Any] else { continue }
                let locale = (manifest["default_locale"] as? String) ?? "en"
                let name = resolveMessage(
                    manifest["name"] as? String ?? extensionID,
                    extensionRoot: versionURL,
                    locale: locale
                )
                let description = resolveMessage(
                    rawCommand["description"] as? String ?? commandID,
                    extensionRoot: versionURL,
                    locale: locale
                )
                return ChromeExtensionCommandDescriptor(
                    extensionID: extensionID,
                    extensionName: name,
                    commandID: commandID,
                    commandDescription: description
                )
            }
        }
        throw ShortcutError.unsupported("blocked_no_installed_command")
    }

    private func resolveMessage(_ value: String, extensionRoot: URL, locale: String) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2))
        let candidates = [locale, "en", "en_US"]
        for candidate in candidates {
            let url = extensionRoot
                .appendingPathComponent("_locales", isDirectory: true)
                .appendingPathComponent(candidate, isDirectory: true)
                .appendingPathComponent("messages.json")
            guard let data = try? Data(contentsOf: url),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = messages[key] as? [String: Any],
                  let message = entry["message"] as? String else { continue }
            return message
        }
        return key
    }
}

public struct ChromeExtensionCommandSnapshot: Equatable {
    public let descriptor: ChromeExtensionCommandDescriptor
    public let chord: String?
}

public protocol ChromeExtensionShortcutControlling {
    func inspect(
        descriptor: ChromeExtensionCommandDescriptor,
        application: AppInfo
    ) throws -> ChromeExtensionCommandSnapshot
    func assign(
        descriptor: ChromeExtensionCommandDescriptor,
        chord: String,
        application: AppInfo
    ) throws -> ChromeExtensionCommandSnapshot
    func clear(
        descriptor: ChromeExtensionCommandDescriptor,
        application: AppInfo
    ) throws -> ChromeExtensionCommandSnapshot
}

public final class AccessibilityChromeExtensionShortcutController: ChromeExtensionShortcutControlling {
    private static let maximumNodes = 1_024
    private static let maximumDepth = 12
    private let keyboard: ShortcutKeyboardDispatching

    public init(keyboard: ShortcutKeyboardDispatching) {
        self.keyboard = keyboard
    }

    public func inspect(
        descriptor: ChromeExtensionCommandDescriptor,
        application: AppInfo
    ) throws -> ChromeExtensionCommandSnapshot {
        let field = try uniqueField(descriptor: descriptor, application: application)
        return ChromeExtensionCommandSnapshot(
            descriptor: descriptor,
            chord: chordValue(of: field)
        )
    }

    public func assign(
        descriptor: ChromeExtensionCommandDescriptor,
        chord: String,
        application: AppInfo
    ) throws -> ChromeExtensionCommandSnapshot {
        let field = try uniqueField(descriptor: descriptor, application: application)
        try focus(field)
        try keyboard.dispatch(chord: chord, application: application)
        return try waitForValue(descriptor: descriptor, application: application, expected: chord)
    }

    public func clear(
        descriptor: ChromeExtensionCommandDescriptor,
        application: AppInfo
    ) throws -> ChromeExtensionCommandSnapshot {
        let field = try uniqueField(descriptor: descriptor, application: application)
        if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFTypeRef) != .success {
            try focus(field)
            try keyboard.clear(application: application)
        }
        return try waitForValue(descriptor: descriptor, application: application, expected: nil)
    }

    private func waitForValue(
        descriptor: ChromeExtensionCommandDescriptor,
        application: AppInfo,
        expected: String?
    ) throws -> ChromeExtensionCommandSnapshot {
        let normalizedExpected = normalized(expected)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let observed = try? inspect(descriptor: descriptor, application: application),
               normalized(observed.chord) == normalizedExpected {
                return observed
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw ShortcutError.verificationUnavailable("Chrome command chord readback did not match")
    }

    private func uniqueField(
        descriptor: ChromeExtensionCommandDescriptor,
        application: AppInfo
    ) throws -> AXUIElement {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        guard application.isRunning, let pid = application.processID else {
            throw ShortcutError.appNotRunning(application.name)
        }
        let root = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let candidates = semanticFields(root: root, descriptor: descriptor)
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 {
                throw ShortcutError.handoffRequired(
                    "Chrome exposed \(candidates.count) semantic fields for the requested extension command"
                )
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw ShortcutError.handoffRequired(
            "Chrome exposed 0 semantic fields for the requested extension command"
        )
    }

    private func semanticFields(
        root: AXUIElement,
        descriptor: ChromeExtensionCommandDescriptor
    ) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<UInt64>()
        var candidates: [AXUIElement] = []
        while !queue.isEmpty, visited.count < Self.maximumNodes {
            let (element, depth) = queue.removeFirst()
            guard visited.insert(UInt64(CFHash(element))).inserted else { continue }
            let role = attribute(element, kAXRoleAttribute) as? String
            if ["AXButton", "AXTextField", "AXPopUpButton"].contains(role),
               context(of: element).contains(descriptor.extensionName.lowercased()),
               context(of: element).contains(descriptor.commandDescription.lowercased()) {
                candidates.append(element)
            }
            if depth < Self.maximumDepth {
                let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return candidates
    }

    private func context(of element: AXUIElement) -> String {
        var values: [String] = []
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let node = current else { break }
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute] {
                if let value = attribute(node, name) as? String, !value.isEmpty { values.append(value) }
            }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return values.joined(separator: " ").lowercased()
    }

    private func focus(_ element: AXUIElement) throws {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success else {
            throw ShortcutError.handoffRequired("Chrome command field could not be focused semantically")
        }
    }

    private func chordValue(of element: AXUIElement) -> String? {
        let values = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
            attribute(element, $0) as? String
        }
        for value in values {
            if let chord = normalized(value) { return chord }
        }
        return nil
    }

    private func normalized(_ raw: String?) -> String? {
        guard var raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("not set") || raw.contains("unassigned") || raw == "none" { return nil }
        let symbols: [(String, String)] = [("⌃", "ctrl+"), ("⌥", "option+"), ("⇧", "shift+"), ("⌘", "cmd+")]
        for (symbol, replacement) in symbols { raw = raw.replacingOccurrences(of: symbol, with: replacement) }
        raw = raw.replacingOccurrences(of: "++", with: "+").trimmingCharacters(in: CharacterSet(charactersIn: "+ "))
        return (try? ShortcutChord(raw, provider: .chromeExtensionCommand))?.canonical
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
