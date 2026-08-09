import ApplicationServices
import Foundation

/// The narrow contract shared by checkpointed tasks and workflow actions.
/// Search is deliberately structural: the action may only address an
/// Accessibility search field and may never use text/visual/coordinate
/// matching to discover its target.
public struct SearchActionParameters: Equatable {
    public let inputKey: String
    public let replaceExisting: Bool

    public init(inputKey: String, replaceExisting: Bool = true) {
        self.inputKey = inputKey
        self.replaceExisting = replaceExisting
    }
}

public enum SearchActionContractError: Error, LocalizedError, Equatable {
    case invalidSurface
    case missingSelector
    case invalidSelector(String)
    case invalidTextSource
    case missingInputKey
    case invalidReplaceExisting

    public var errorDescription: String? {
        switch self {
        case .invalidSurface:
            return "Search actions must target a macOS application"
        case .missingSelector:
            return "Search actions require an Accessibility search-field selector"
        case .invalidSelector(let reason):
            return "Search field selector is invalid: \(reason)"
        case .invalidTextSource:
            return "Search input must use text_source=ephemeral"
        case .missingInputKey:
            return "Search input must name an ephemeral input_key"
        case .invalidReplaceExisting:
            return "replace_existing must be a boolean"
        }
    }
}

public enum SearchActionContract {
    public static func parameters(for action: ActionSpec) throws -> SearchActionParameters {
        guard action.kind == .search else {
            throw SearchActionContractError.invalidSelector("action kind is not search")
        }
        guard action.surface == .macApp else {
            throw SearchActionContractError.invalidSurface
        }
        guard let selector = action.selector else {
            throw SearchActionContractError.missingSelector
        }
        try validate(selector: selector)
        guard action.parameters["text_source"]?.stringValue == "ephemeral" else {
            throw SearchActionContractError.invalidTextSource
        }
        guard let inputKey = action.parameters["input_key"]?.stringValue,
              !inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SearchActionContractError.missingInputKey
        }
        if action.parameters["replace_existing"] != nil,
           action.parameters["replace_existing"]?.boolValue == nil {
            throw SearchActionContractError.invalidReplaceExisting
        }
        return SearchActionParameters(
            inputKey: inputKey,
            replaceExisting: action.parameters["replace_existing"]?.boolValue ?? true
        )
    }

    public static func validate(selector: Selector) throws {
        guard selector.addressability == .accessibility else {
            throw SearchActionContractError.invalidSelector(
                "only Accessibility selectors are addressable"
            )
        }
        guard selector.role == "AXTextField" else {
            throw SearchActionContractError.invalidSelector(
                "role must be AXTextField"
            )
        }
        guard selector.subrole == "AXSearchField" else {
            throw SearchActionContractError.invalidSelector(
                "subrole must be AXSearchField"
            )
        }
        guard selector.containsText == nil else {
            throw SearchActionContractError.invalidSelector(
                "containsText cannot identify a search field"
            )
        }
        guard selector.normalizedX == nil,
              selector.normalizedY == nil,
              selector.rawX == nil,
              selector.rawY == nil,
              selector.imageAnchor == nil else {
            throw SearchActionContractError.invalidSelector(
                "visual and coordinate targets are not allowed"
            )
        }
        if let identifier = selector.identifier,
           identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SearchActionContractError.invalidSelector(
                "identifier must not be empty"
            )
        }
        if let title = selector.title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SearchActionContractError.invalidSelector(
                "title must not be empty"
            )
        }
    }

    public static func matches(
        selector: Selector,
        focus: FocusedElementSnapshot
    ) -> Bool {
        let fields: [(String?, String?)] = [
            (selector.role, focus.role),
            (selector.subrole, focus.subrole),
            (selector.identifier, focus.identifier),
            (selector.title, focus.title)
        ]
        return fields.allSatisfy { expected, actual in
            guard let expected else { return true }
            return expected == actual
        }
    }
}

/// Search target resolution is a protocol so executor tests can model
/// missing and ambiguous AX fields without constructing a live AX tree.
public protocol SearchFieldResolving {
    func requireUniqueSearchField(pid: pid_t, selector: Selector) throws
}

/// The text sink for a search action is injectable so tests can prove that
/// ephemeral input is dispatched exactly once without posting real text.
public protocol SearchTextTyping {
    func type(_ text: String) throws
}

extension AccessibilityController: SearchFieldResolving {
    public func requireUniqueSearchField(pid: pid_t, selector: Selector) throws {
        _ = try findElement(pid: pid, selector: selector)
    }
}

extension InputController: SearchTextTyping {}
