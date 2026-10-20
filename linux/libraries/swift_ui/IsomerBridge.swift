// Native bridging API for the Linux platform. Swift calls the flat C
// renderer/host functions (`renderer.h`); the SDL2/OpenGL host implements them.
// This is the Linux counterpart of the wasm/Android/Windows bridges.


public enum Bridge {
    public static var platformName: String { "Linux" }
    public static var rendererName: String { "OpenGL" }

    public static func log(_ message: String) {
        var copy = message
        copy.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { rebound in
                iso_bridge_log(rebound.baseAddress, Int32(rebound.count))
            }
        }
    }

    public static func epochMilliseconds() -> Int64 {
        Int64(iso_bridge_epoch_millis())
    }

    public static func openURL(_ url: String) {
        var copy = url
        copy.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { rebound in
                iso_bridge_open_url(rebound.baseAddress, Int32(rebound.count))
            }
        }
    }
}
