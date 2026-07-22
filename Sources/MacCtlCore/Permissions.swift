import Foundation
import ApplicationServices
import CoreGraphics

public enum PermissionDiagnostics {
    public static func report() -> [PermissionStatus] {
        let accessibility = AXIsProcessTrusted()
        let postEvents = CGPreflightPostEventAccess()
        let listenEvents = CGPreflightListenEventAccess()
        let screenCapture = CGPreflightScreenCaptureAccess()
        let instructions = "System Settings > Privacy & Security"
        return [
            PermissionStatus(
                name: "Accessibility",
                state: accessibility ? "granted" : "missing",
                requiredFor: "Accessibility-tree discovery and semantic controls",
                instruction: "\(instructions) > Accessibility: enable the terminal or macctl/macctld host"
            ),
            PermissionStatus(
                name: "Input Monitoring",
                state: listenEvents ? "granted" : "missing",
                requiredFor: "Caps Lock double-tap event monitoring",
                instruction: "\(instructions) > Input Monitoring: enable the terminal or macctld host"
            ),
            PermissionStatus(
                name: "Post Events",
                state: postEvents ? "granted" : "missing",
                requiredFor: "Keyboard and mouse event injection",
                instruction: "\(instructions) > Accessibility: enable the terminal or macctl/macctld host"
            ),
            PermissionStatus(
                name: "Screen Recording",
                state: screenCapture ? "granted" : "missing",
                requiredFor: "On-demand screenshots and Vision OCR",
                instruction: "\(instructions) > Screen Recording: enable the terminal or macctld host"
            ),
            PermissionStatus(
                name: "Automation",
                state: "manual",
                requiredFor: "AppleScript and application-specific adapters",
                instruction: "Approve the target app the first time an AppleScript adapter asks"
            )
        ]
    }

    public static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    public static func hasPostEventAccess() -> Bool {
        CGPreflightPostEventAccess()
    }

    public static func hasListenEventAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    public static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}
