import AppKit
import Foundation
import MacCtlCore

final class MacCtlApplicationDelegate: NSObject, NSApplicationDelegate {
    var server: UnixSocketServer?
    var shutdownHandler: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        shutdownHandler?()
        server?.stop()
    }
}

let application = NSApplication.shared
let delegate = MacCtlApplicationDelegate()
application.delegate = delegate
let hud = ApprovalHUD()
let service = MacCtlService()
do {
    try InstalledRuntimeParity.publishRunningProcess()
} catch {
    fputs("macctld: runtime parity identity unavailable: \(error.localizedDescription)\n", stderr)
}
hud.snapshotHandler = {
    service.controlCenterSnapshot()
}
hud.stopHandler = {
    service.handle(RequestEnvelope(method: "control.stop_active"))
}
service.controlCenterStateChanged = {
    hud.refresh()
}
delegate.shutdownHandler = {
    service.shutdown()
    InstalledRuntimeParity.removeRunningProcess()
}

let server = UnixSocketServer()
do {
    try server.startWithPeer { data, peerIdentity in
        do {
            let request = try JSONCodec.decode(RequestEnvelope.self, from: data)
                .withTransportPeerIdentity(peerIdentity)
            return try JSONCodec.encode(service.handle(request))
        } catch {
            let response = ResponseEnvelope(
                requestID: UUID().uuidString,
                status: .failed,
                error: MacCtlError(
                    code: MacCtlErrorCode.invalidRequest.rawValue,
                    message: "Invalid JSON request: \(error.localizedDescription)"
                )
            )
            return (try? JSONCodec.encode(response)) ?? Data()
        }
    }
    delegate.server = server
    hud.start()
    application.run()
} catch {
    fputs("macctld: \(error.localizedDescription)\n", stderr)
    exit(1)
}
