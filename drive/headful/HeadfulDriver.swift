// A headful app's driver (built in with --@isomer//drive:headful): when the
// app is launched with ISO_DRIVER=<ws://… a hub or a test host>, it dials out
// and is driven over that connection (session_service.proto's Driver.Attach),
// its screen read through the runtime as the headless host's is
// (drive/driver). The hosts call `iso_drive_attach` once their runtime has
// started; without this library they reach drive/headful's no-op.
//
// Over a WebSocket, through Foundation's URLSession: the transport every host
// has (the web's and Android's through Isomer's Foundation); on Linux and
// Windows through IsomerRemote (SwiftNIO), as a headless app dials out.
// ISO_DRIVER_TOKEN is the hub's token, if it wants one.

import Foundation
import IsomerDriver
import IsomerServing
#if canImport(IsomerRemote)
import IsomerRemote
#endif

@_silgen_name("iso_drive_attach")
func _isoDriveAttach(_ platform: String, _ renderer: String) {
    let environment = ProcessInfo.processInfo.environment
    guard let address = environment["ISO_DRIVER"], let url = URL(string: address) else { return }
    MainActor.assumeIsolated {
        let driver = IsomerAppDriver(info: IsomerAppDriver.bundleInfo(platform: platform, renderer: renderer))
        Task { @MainActor in
            do {
                let metadata = environment["ISO_DRIVER_NAME"].map { ["iso-target": $0] } ?? [:]
                #if canImport(IsomerRemote)
                // Linux and Windows: SwiftNIO's WebSocket client (or gRPC),
                // as a headless app dials out; Foundation's URLSession there
                // takes its WebSockets from a libcurl that may have none.
                let endpoint = try IsomerRemote.endpoint(address)
                try await driver.dialOut(endpoint.connection,
                                         context: endpoint.context(token: environment["ISO_DRIVER_TOKEN"], metadata: metadata))
                #else
                try await driver.dialOut(
                    IsomerURLSessionConnection(url),
                    context: .authorized(environment["ISO_DRIVER_TOKEN"], metadata: metadata)
                )
                #endif
            } catch {
                print("[iso] driver at \(address): \(error)")
            }
        }
    }
}
