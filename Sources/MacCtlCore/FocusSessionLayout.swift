import AppKit
import Foundation

public enum FocusSessionLayoutName: String, Codable, CaseIterable, Equatable {
    case balanced = "balanced"
    case briefPrimary = "brief-primary"

    public var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .briefPrimary: return "Brief Primary"
        }
    }
}

/// A display identity and its current usable bounds. The Core Graphics display
/// ID is used as the plan-bound selector; array position and main-screen state
/// are deliberately excluded because either can change during a session.
public struct FocusSessionDisplay: Codable, Equatable {
    public let id: UInt32
    public let name: String
    public let visibleFrame: FocusSessionWindowFrame

    public init(id: UInt32, name: String, visibleFrame: FocusSessionWindowFrame) {
        self.id = id
        self.name = name
        self.visibleFrame = visibleFrame
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case visibleFrame = "visible_frame"
    }
}

public struct FocusSessionDisplayCatalogSnapshot: Codable, Equatable {
    public let schemaVersion: String
    public let displays: [FocusSessionDisplay]
    public let layouts: [String]

    public init(displays: [FocusSessionDisplay]) {
        self.schemaVersion = "macctl-focus-session-displays/v1"
        self.displays = displays
        self.layouts = FocusSessionLayoutName.allCases.map(\.rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case displays, layouts
    }
}

public protocol FocusSessionDisplayProviding {
    func connectedDisplays() -> [FocusSessionDisplay]
}

public struct SystemFocusSessionDisplayProvider: FocusSessionDisplayProviding {
    public init() {}

    public func connectedDisplays() -> [FocusSessionDisplay] {
        _ = NSApplication.shared
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let frame = screen.visibleFrame
            return FocusSessionDisplay(
                id: number.uint32Value,
                name: screen.localizedName,
                visibleFrame: FocusSessionWindowFrame(
                    x: frame.minX,
                    y: frame.minY,
                    width: frame.width,
                    height: frame.height
                )
            )
        }
    }
}

public enum FocusSessionDisplayError: Error, LocalizedError, Equatable {
    case displayUnavailable(UInt32)
    case displayAmbiguous(UInt32)

    public var errorDescription: String? {
        switch self {
        case .displayUnavailable(let id):
            return "Focus-session display is not connected: \(id)"
        case .displayAmbiguous(let id):
            return "Focus-session display identity is ambiguous: \(id)"
        }
    }
}

public enum FocusSessionDisplayResolver {
    public static func resolve(
        id: UInt32,
        from connectedDisplays: [FocusSessionDisplay]
    ) throws -> FocusSessionDisplay {
        let matches = connectedDisplays.filter { $0.id == id }
        guard !matches.isEmpty else {
            throw FocusSessionDisplayError.displayUnavailable(id)
        }
        guard matches.count == 1, let display = matches.first else {
            throw FocusSessionDisplayError.displayAmbiguous(id)
        }
        return display
    }
}

public enum FocusSessionLayoutResolver {
    public static func targetFrames(
        layout: FocusSessionLayoutName,
        visibleFrame: FocusSessionWindowFrame
    ) -> (brief: FocusSessionWindowFrame, scratchpad: FocusSessionWindowFrame) {
        let gutter = 12.0
        let availableWidth = max(0, visibleFrame.width - gutter)
        let briefWidth: Double
        switch layout {
        case .balanced:
            briefWidth = availableWidth / 2
        case .briefPrimary:
            briefWidth = availableWidth * 0.6
        }
        let scratchpadWidth = availableWidth - briefWidth
        return (
            FocusSessionWindowFrame(
                x: visibleFrame.x,
                y: visibleFrame.y,
                width: briefWidth,
                height: visibleFrame.height
            ),
            FocusSessionWindowFrame(
                x: visibleFrame.x + briefWidth + gutter,
                y: visibleFrame.y,
                width: scratchpadWidth,
                height: visibleFrame.height
            )
        )
    }
}
