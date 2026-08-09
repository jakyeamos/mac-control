import Foundation
import ApplicationServices
import CoreGraphics

public enum PermissionDiagnostics {
    public static func report(automationRequired: Bool = false) -> [PermissionStatus] {
        let accessibility = AXIsProcessTrusted()
        let postEvents = CGPreflightPostEventAccess()
        let listenEvents = CGPreflightListenEventAccess()
        let screenCapture = CGPreflightScreenCaptureAccess()
        let instructions = "System Settings > Privacy & Security"
        let packagedDaemon = MacCtlPaths.daemonAppURL.path
        return [
            PermissionStatus(
                name: "Accessibility",
                state: accessibility ? "granted" : "missing",
                requiredFor: "Accessibility-tree discovery and semantic controls",
                instruction: "\(instructions) > Accessibility: enable \(packagedDaemon)"
            ),
            PermissionStatus(
                name: "Input Monitoring",
                state: listenEvents ? "granted" : "missing",
                requiredFor: "Caps Lock double-tap monitoring and explicit physical keyboard freeze",
                instruction: "\(instructions) > Input Monitoring: enable \(packagedDaemon)"
            ),
            PermissionStatus(
                name: "Post Events",
                state: postEvents ? "granted" : "missing",
                requiredFor: "Keyboard and mouse event injection",
                instruction: "\(instructions) > Accessibility: enable \(packagedDaemon)"
            ),
            PermissionStatus(
                name: "Screen Recording",
                state: screenCapture ? "granted" : "missing",
                requiredFor: "On-demand screenshots and Vision OCR",
                instruction: "\(instructions) > Screen Recording: enable \(packagedDaemon)"
            ),
            PermissionStatus(
                name: "Automation",
                state: automationRequired ? "unknown" : "not_required",
                requiredFor: "AppleScript and application-specific adapters",
                instruction: automationRequired
                    ? "Approve the target app the first time an AppleScript adapter asks"
                    : "Not required by the native control-plane backend"
            )
        ]
    }

    public static func unknownReport() -> [PermissionStatus] {
        [
            PermissionStatus(
                name: "Accessibility",
                state: "unknown",
                requiredFor: "Accessibility-tree discovery and semantic controls",
                instruction: "Start the packaged macctld daemon before evaluating permissions"
            ),
            PermissionStatus(
                name: "Input Monitoring",
                state: "unknown",
                requiredFor: "Caps Lock double-tap monitoring and explicit physical keyboard freeze",
                instruction: "Start the packaged macctld daemon before evaluating permissions"
            ),
            PermissionStatus(
                name: "Post Events",
                state: "unknown",
                requiredFor: "Keyboard and mouse event injection",
                instruction: "Start the packaged macctld daemon before evaluating permissions"
            ),
            PermissionStatus(
                name: "Screen Recording",
                state: "unknown",
                requiredFor: "On-demand screenshots and Vision OCR",
                instruction: "Start the packaged macctld daemon before evaluating permissions"
            ),
            PermissionStatus(
                name: "Automation",
                state: "not_required",
                requiredFor: "AppleScript and application-specific adapters",
                instruction: "Not required by the native control-plane backend"
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
