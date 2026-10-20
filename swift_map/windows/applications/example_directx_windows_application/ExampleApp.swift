// SwiftMap on Windows: a Win32 window (pure Swift via WinSDK) hosting
// swift_gpu's Direct3D 11 backend. The engine and MapSceneRenderer are the
// same code every platform runs; this file is only the host half — window +
// input, URLSession tile fetch, stb decode, and the attribution label the
// OSM tile policy requires.
//
// Drag pans, the scroll wheel zooms about the cursor; tiles arrive on
// URLSession threads and are drained on the main thread each loop turn.

import Foundation
import SwiftGPU
import SwiftMap
import WinSDK

@_extern(c) func sm_decode_rgba(
    _ bytes: UnsafePointer<UInt8>, _ len: Int32,
    _ outWidth: UnsafeMutablePointer<Int32>, _ outHeight: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<UInt8>?
@_extern(c) func sm_free_rgba(_ pixels: UnsafeMutablePointer<UInt8>)

// MARK: - Shared state (single-threaded main loop + locked tile inbox)

final class AppState {
    var engine = MapEngine()
    var device: DirectXGPUDevice?
    var scene: MapSceneRenderer?
    let fetcher = FoundationTileFetcher()
    var needsRender = true
    var dpiScale = 1.0

    let inboxLock = NSLock()
    var inbox: [(key: TileKey, rgba: [UInt8]?, width: Int, height: Int)] = []
}

nonisolated(unsafe) let state = AppState()

/// MapEngineHost: fetch+decode off-thread, deliver through the inbox.
final class Host: MapEngineHost {
    func requestTile(key: TileKey, url: String) {
        state.fetcher.fetch(url: url) { bytes in
            var decoded: (rgba: [UInt8]?, width: Int, height: Int) = (nil, 0, 0)
            if let bytes, !bytes.isEmpty {
                var width: Int32 = 0
                var height: Int32 = 0
                let pixels = bytes.withUnsafeBufferPointer { buffer in
                    sm_decode_rgba(buffer.baseAddress!, Int32(buffer.count), &width, &height)
                }
                if let pixels, width > 0, height > 0 {
                    decoded = (
                        Array(UnsafeBufferPointer(start: pixels, count: Int(width * height * 4))),
                        Int(width), Int(height)
                    )
                    sm_free_rgba(pixels)
                }
            }
            state.inboxLock.lock()
            state.inbox.append((key, decoded.rgba, decoded.width, decoded.height))
            state.inboxLock.unlock()
        }
    }

    func evictTile(key: TileKey) {
        state.scene?.removeTexture(forKey: key.id)
    }

    func setNeedsRender() {
        state.needsRender = true
    }
}

// MARK: - Win32 plumbing

func loWord(_ value: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: value)) }
func hiWord(_ value: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: value >> 16)) }

func windowProc(
    _ hwnd: HWND?, _ message: UInt32, _ wParam: WPARAM, _ lParam: LPARAM
) -> LRESULT {
    switch message {
    case UInt32(WM_LBUTTONDOWN):
        SetCapture(hwnd)
        state.engine.pointer(
            phase: 0, x: Double(loWord(lParam)) / state.dpiScale,
            y: Double(hiWord(lParam)) / state.dpiScale)
        return 0
    case UInt32(WM_MOUSEMOVE):
        if wParam & WPARAM(MK_LBUTTON) != 0 {
            state.engine.pointer(
                phase: 1, x: Double(loWord(lParam)) / state.dpiScale,
                y: Double(hiWord(lParam)) / state.dpiScale)
        }
        return 0
    case UInt32(WM_LBUTTONUP):
        ReleaseCapture()
        state.engine.pointer(
            phase: 2, x: Double(loWord(lParam)) / state.dpiScale,
            y: Double(hiWord(lParam)) / state.dpiScale)
        return 0
    case UInt32(WM_MOUSEWHEEL):
        // lParam is in screen coordinates for wheel messages.
        var point = POINT(x: loWord(lParam), y: hiWord(lParam))
        ScreenToClient(hwnd, &point)
        let delta = Double(Int16(truncatingIfNeeded: wParam >> 16)) / 120.0 * 0.4
        state.engine.zoom(
            by: delta, anchorX: Double(point.x) / state.dpiScale,
            anchorY: Double(point.y) / state.dpiScale)
        return 0
    case UInt32(WM_SIZE):
        var client = RECT()
        GetClientRect(hwnd, &client)
        let widthPx = Int(client.right - client.left)
        let heightPx = Int(client.bottom - client.top)
        state.dpiScale = Double(GetDpiForWindow(hwnd)) / 96.0
        state.device?.resize(widthPx: widthPx, heightPx: heightPx)
        state.engine.resize(
            width: Double(widthPx) / state.dpiScale, height: Double(heightPx) / state.dpiScale)
        return 0
    case UInt32(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

@main
enum ExampleApp {
    static func main() {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        let instance = GetModuleHandleW(nil)
        let className = "SwiftMapWindow".wide

        className.withUnsafeBufferPointer { classNameBuffer in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = windowProc
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))  // IDC_ARROW
            windowClass.lpszClassName = classNameBuffer.baseAddress
            RegisterClassW(&windowClass)
        }

        let systemScale = Double(GetDpiForSystem()) / 96.0
        let hwnd = "SwiftMap — © OpenStreetMap contributors".wide.withUnsafeBufferPointer { title in
            className.withUnsafeBufferPointer { name in
                // WS_CLIPCHILDREN keeps the attribution label out of the
                // swapchain's presented region (it would be painted over).
                CreateWindowExW(
                    0, name.baseAddress, title.baseAddress,
                    DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
                    CW_USEDEFAULT, CW_USEDEFAULT,
                    Int32(900 * systemScale), Int32(640 * systemScale),
                    nil, nil, instance, nil)
            }
        }
        guard let hwnd else {
            fatalError("CreateWindowExW failed")
        }
        ShowWindow(hwnd, SW_SHOW)

        var client = RECT()
        GetClientRect(hwnd, &client)
        let widthPx = Int(client.right - client.left)
        let heightPx = Int(client.bottom - client.top)
        state.dpiScale = Double(GetDpiForWindow(hwnd)) / 96.0

        guard let device = DirectXGPUDevice(
            hwnd: UnsafeMutableRawPointer(hwnd), widthPx: widthPx, heightPx: heightPx)
        else {
            fatalError("SwiftMap requires a D3D11 device")
        }
        state.device = device
        state.scene = MapSceneRenderer(device: device)
        state.engine.host = Host()
        state.engine.resize(
            width: Double(widthPx) / state.dpiScale, height: Double(heightPx) / state.dpiScale)
        state.engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 12)

        // The attribution overlay the OSM tile policy requires: a native
        // STATIC child label, bottom-left (repositioned is unnecessary for
        // the example; it sits at a fixed offset).
        _ = "© OpenStreetMap contributors".wide.withUnsafeBufferPointer { text in
            "STATIC".wide.withUnsafeBufferPointer { staticClass in
                CreateWindowExW(
                    0, staticClass.baseAddress, text.baseAddress,
                    DWORD(WS_CHILD) | DWORD(WS_VISIBLE),
                    8, Int32(heightPx) - 28, Int32(220 * state.dpiScale), 20,
                    hwnd, nil, instance, nil)
            }
        }

        var message = MSG()
        var running = true
        while running {
            while PeekMessageW(&message, nil, 0, 0, UInt32(PM_REMOVE)) {
                if message.message == UInt32(WM_QUIT) {
                    running = false
                }
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }

            // Drain decoded tiles (URLSession threads -> main).
            state.inboxLock.lock()
            let arrived = state.inbox
            state.inbox.removeAll()
            state.inboxLock.unlock()
            for tile in arrived {
                if let rgba = tile.rgba {
                    state.scene?.setTexture(
                        rgba: rgba, width: tile.width, height: tile.height, forKey: tile.key.id)
                    state.engine.tileLoaded(key: tile.key)
                } else {
                    state.engine.tileFailed(key: tile.key)
                }
                state.needsRender = true
            }

            if state.needsRender, let scene = state.scene {
                state.needsRender = false
                let frame = state.engine.buildFrame()
                device.renderFrame(clear: MapSceneRenderer.clearColor) { pass in
                    scene.draw(frame: frame, into: pass)
                }
            } else {
                Sleep(8)
            }
        }
    }
}

extension String {
    /// UTF-16 with a trailing NUL, for the wide Win32 API surface.
    var wide: [UInt16] { Array(utf16) + [0] }
}
