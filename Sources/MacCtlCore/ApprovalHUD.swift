import AppKit
import Foundation

private final class MacCtlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ApprovalButton: NSButton {
    private var receivedMouseDown = false

    override func mouseDown(with event: NSEvent) {
        receivedMouseDown = true
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        false
    }

    func consumeMouseClick() -> Bool {
        defer { receivedMouseDown = false }
        return receivedMouseDown
    }
}

public final class ApprovalHUD: NSObject {
    public var approveHandler: ((String) -> ResponseEnvelope)?
    public var denyHandler: ((String) -> ResponseEnvelope)?

    private var panel: MacCtlPanel?
    private var statusItem: NSStatusItem?
    private var currentApproval: ApprovalRecord?
    private var statusLabel: NSTextField?
    private var expiryTimer: Timer?
    private let capsLockMonitor: CapsLockMonitor

    public init(capsLockMonitor: CapsLockMonitor = CapsLockMonitor()) {
        self.capsLockMonitor = capsLockMonitor
        super.init()
    }

    public func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "macctl"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show pending approval", action: #selector(showPending), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit daemon", action: #selector(quitDaemon), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        capsLockMonitor.onDoubleTap = { [weak self] in self?.bringToFront() }
        _ = capsLockMonitor.start()
    }

    public func present(_ approval: ApprovalRecord) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.present(approval) }
            return
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard approval.expiresAt > Date() else {
            dismissCurrentApproval()
            return
        }
        currentApproval = approval
        let window = makePanelIfNeeded()
        let content = makeContent(for: approval)
        window.contentView = content
        position(window)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(nil)
        scheduleExpiry(for: approval)
    }

    public func bringToFront() {
        guard let panel, currentApproval != nil else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.bringToFront() }
            return
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func showPending() {
        if currentApproval != nil { bringToFront() }
    }

    @objc private func quitDaemon() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func approve(_ sender: NSButton) {
        guard let token = currentApproval?.token else { return }
        guard (sender as? ApprovalButton)?.consumeMouseClick() == true else {
            SafeLog().record(event: "approval_hud_rejected", metadata: ["action": "approve", "reason": "non_mouse"])
            return
        }
        SafeLog().record(event: "approval_hud_action", metadata: ["action": "approve"])
        guard let response = approveHandler?(token) else { return }
        if response.status == .succeeded {
            dismissCurrentApproval()
        } else {
            statusLabel?.stringValue = response.error?.message ?? "Approval failed; operation was not completed"
        }
    }

    @objc private func deny(_ sender: NSButton) {
        guard let token = currentApproval?.token else { return }
        guard (sender as? ApprovalButton)?.consumeMouseClick() == true else {
            SafeLog().record(event: "approval_hud_rejected", metadata: ["action": "deny", "reason": "non_mouse"])
            return
        }
        SafeLog().record(event: "approval_hud_action", metadata: ["action": "deny"])
        guard let response = denyHandler?(token) else { return }
        if response.status == .succeeded {
            dismissCurrentApproval()
        } else {
            statusLabel?.stringValue = response.error?.message ?? "Deny failed"
        }
    }

    private func scheduleExpiry(for approval: ApprovalRecord) {
        let interval = approval.expiresAt.timeIntervalSinceNow
        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: max(interval, 0.01),
            repeats: false
        ) { [weak self] _ in
            guard let self, self.currentApproval?.token == approval.token else { return }
            if approval.expiresAt <= Date() {
                self.dismissCurrentApproval()
            } else {
                self.scheduleExpiry(for: approval)
            }
        }
    }

    private func dismissCurrentApproval() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        currentApproval = nil
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> MacCtlPanel {
        if let panel { return panel }
        let newPanel = MacCtlPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 190),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "macctl approval"
        newPanel.defaultButtonCell = nil
        newPanel.isReleasedWhenClosed = false
        newPanel.level = .statusBar
        newPanel.hidesOnDeactivate = false
        newPanel.isMovableByWindowBackground = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.backgroundColor = NSColor.windowBackgroundColor
        panel = newPanel
        return newPanel
    }

    private func makeContent(for approval: ApprovalRecord) -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 7
        root.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)

        let heading = NSTextField(labelWithString: "Approval required · \(approval.risk.rawValue.uppercased())")
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        let summary = NSTextField(wrappingLabelWithString: approval.summary)
        summary.maximumNumberOfLines = 2
        let focusLabel = NSTextField(labelWithString: "Focus policy: \(approval.focusPolicy.rawValue)")
        focusLabel.textColor = .secondaryLabelColor
        focusLabel.font = NSFont.systemFont(ofSize: 11)
        let expiry = DateFormatter()
        expiry.dateStyle = .none
        expiry.timeStyle = .short
        let expiryLabel = NSTextField(labelWithString: "Expires at \(expiry.string(from: approval.expiresAt)) · Caps Lock double-tap brings this panel forward")
        expiryLabel.textColor = .secondaryLabelColor
        expiryLabel.font = NSFont.systemFont(ofSize: 11)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let approveButton = ApprovalButton(title: "Approve exact plan", target: self, action: #selector(approve(_:)))
        approveButton.bezelStyle = .rounded
        let denyButton = ApprovalButton(title: "Deny", target: self, action: #selector(deny(_:)))
        denyButton.bezelStyle = .rounded
        buttons.addArrangedSubview(approveButton)
        buttons.addArrangedSubview(denyButton)
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 11)
        statusLabel = status

        root.addArrangedSubview(heading)
        root.addArrangedSubview(summary)
        root.addArrangedSubview(focusLabel)
        root.addArrangedSubview(expiryLabel)
        root.addArrangedSubview(buttons)
        root.addArrangedSubview(status)
        return root
    }

    private func position(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 10
        )
        window.setFrameOrigin(origin)
    }
}
