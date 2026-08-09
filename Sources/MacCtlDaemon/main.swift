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
var service: MacCtlService!
service = MacCtlService(presentApproval: { approval in
    hud.present(approval)
})
hud.approvalPendingHandler = { token in
    service.isApprovalPending(token: token)
}
hud.approveHandler = { token in
    service.handle(RequestEnvelope(
        method: "approval.approve",
        params: ["token": .string(token), "source": .string("hud")]
    ))
}
hud.denyHandler = { token in
    service.handle(RequestEnvelope(
        method: "approval.deny",
        params: ["token": .string(token), "source": .string("hud")]
    ))
}
delegate.shutdownHandler = { service.shutdown() }

let server = UnixSocketServer()
do {
    try server.start { data in
        do {
            let request = try JSONCodec.decode(RequestEnvelope.self, from: data)
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
