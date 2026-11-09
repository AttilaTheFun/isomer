// A headful app's driver (built in with --@isomer//drive:headful): when the
// app is launched with ISO_DRIVER=<ws://… a hub or a test host>, it dials out
// and is driven over that connection (session_service.proto's Driver.Attach),
// its screen read through the runtime as the headless host's is
// (drive/driver). The hosts call `iso_drive_attach` once their runtime has
// started; without this library they reach drive/headful's no-op.
//
// Over a WebSocket, through Foundation's URLSession: the transport every host
// has (the web's and Android's through Isomer's Foundation); on Linux and
// Windows through SwiftNIO's (IsomerWebSocketTransport), as Foundation's
// URLSession there takes its WebSockets from a libcurl that may have none.
// (Not IsomerRemote: its gRPC brings swift-nio-ssl, which has no Windows.)
// ISO_DRIVER_TOKEN is the hub's token, if it wants one.

import Foundation
import OSLog
import IsomerDriver
import IsomerServing
#if os(Linux) || os(Windows)
import IsomerWebSocketTransport
#endif

@_silgen_name("iso_drive_attach")
func _isoDriveAttach(_ platform: String, _ renderer: String) {
    let environment = ProcessInfo.processInfo.environment
    guard let address = environment["ISO_DRIVER"], let url = URL(string: address) else { return }
    // Said where a device's log shows it (logcat on Android, where standard
    // output goes nowhere).
    let log = Logger(subsystem: "dev.isomer", category: "drive")
    log.info("[iso] driver: dialling \(address, privacy: .public) as \(environment["ISO_DRIVER_NAME"] ?? "", privacy: .public)")
    MainActor.assumeIsolated {
        let driver = IsomerAppDriver(info: IsomerAppDriver.bundleInfo(platform: platform, renderer: renderer))
        Task { @MainActor in
            do {
                let metadata = environment["ISO_DRIVER_NAME"].map { ["iso-target": $0] } ?? [:]
                #if os(Linux) || os(Windows)
                // Linux and Windows: SwiftNIO's WebSocket client.
                guard url.scheme == "ws", let host = url.host else {
                    log.error("[iso] driver at \(address, privacy: .public): a ws:// URL, here")
                    return
                }
                var base = url.path
                while base.hasSuffix("/") { base.removeLast() }
                try await driver.dialOut(
                    IsomerWebSocketConnection(host: host, port: url.port ?? 80, base: base),
                    context: .authorized(environment["ISO_DRIVER_TOKEN"], metadata: metadata)
                )
                #else
                try await driver.dialOut(
                    IsomerURLSessionConnection(url),
                    context: .authorized(environment["ISO_DRIVER_TOKEN"], metadata: metadata)
                )
                #endif
                log.info("[iso] driver at \(address, privacy: .public): the call ended")
            } catch {
                log.error("[iso] driver at \(address, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
