import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        windows = [
            makeWindow(
                title: "Mac Control Background Action Fixture",
                origin: NSPoint(x: 120, y: 180),
                decoy: false
            ),
            makeWindow(
                title: "Mac Control Background Action Decoy",
                origin: NSPoint(x: 580, y: 180),
                decoy: true
            )
        ]
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func makeWindow(title: String, origin: NSPoint, decoy: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 400, height: 240)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        let heading = NSTextField(labelWithString: decoy ? "Decoy window" : "Exact background action")
        heading.frame = NSRect(x: 28, y: 170, width: 330, height: 28)
        heading.font = .boldSystemFont(ofSize: 18)

        let status = NSTextField(labelWithString: decoy ? "Decoy Idle" : "Idle")
        status.frame = NSRect(x: 28, y: 125, width: 330, height: 28)
        status.setAccessibilityIdentifier("macctl-fixture-status")

        let button = NSButton(title: "Run Background Action", target: self, action: #selector(runAction(_:)))
        button.frame = NSRect(x: 28, y: 58, width: 220, height: 38)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("macctl-fixture-run")
        button.tag = decoy ? 2 : 1

        let secondaryButton = NSButton(
            title: "Fixture Secondary Control",
            target: self,
            action: #selector(ignoreSecondaryAction(_:))
        )
        secondaryButton.frame = NSRect(x: 260, y: 58, width: 115, height: 38)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.setAccessibilityIdentifier("macctl-fixture-secondary")

        content.addSubview(heading)
        content.addSubview(status)
        content.addSubview(button)
        content.addSubview(secondaryButton)
        window.contentView = content
        return window
    }

    @objc private func runAction(_ sender: NSButton) {
        guard let content = sender.window?.contentView else { return }
        let status = content.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "macctl-fixture-status" }
        status?.stringValue = sender.tag == 1 ? "Completed" : "Decoy Completed"
    }

    @objc private func ignoreSecondaryAction(_ sender: NSButton) {}
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.delegate = delegate
application.run()
