// Offscreen pixel checks for the Linux GL backend, mirroring
// tests/MetalBackendTests.swift and windows' directx_backend_check — a plain
// executable that exits non-zero on a mismatch. The GL context comes from an
// EGL pbuffer (no window system needed; Mesa provides EGL on desktop Linux
// and WSLg alike), 64x64 like the other backends' checks.

import SwiftGPU

// Minimal EGL bindings (this check owns the context; the backend itself
// assumes the HOST made one current — see the surface/context ownership
// section of the implementation guide).
@_extern(c) func eglGetDisplay(_ display: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
@_extern(c) func eglInitialize(
    _ display: UnsafeMutableRawPointer?,
    _ major: UnsafeMutablePointer<Int32>?,
    _ minor: UnsafeMutablePointer<Int32>?
) -> UInt32
@_extern(c) func eglBindAPI(_ api: UInt32) -> UInt32
@_extern(c) func eglChooseConfig(
    _ display: UnsafeMutableRawPointer?,
    _ attributes: UnsafePointer<Int32>,
    _ configs: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ configSize: Int32,
    _ numConfigs: UnsafeMutablePointer<Int32>
) -> UInt32
@_extern(c) func eglCreatePbufferSurface(
    _ display: UnsafeMutableRawPointer?,
    _ config: UnsafeMutableRawPointer?,
    _ attributes: UnsafePointer<Int32>
) -> UnsafeMutableRawPointer?
@_extern(c) func eglCreateContext(
    _ display: UnsafeMutableRawPointer?,
    _ config: UnsafeMutableRawPointer?,
    _ shareContext: UnsafeMutableRawPointer?,
    _ attributes: UnsafePointer<Int32>?
) -> UnsafeMutableRawPointer?
@_extern(c) func eglMakeCurrent(
    _ display: UnsafeMutableRawPointer?,
    _ draw: UnsafeMutableRawPointer?,
    _ read: UnsafeMutableRawPointer?,
    _ context: UnsafeMutableRawPointer?
) -> UInt32

let EGL_SURFACE_TYPE: Int32 = 0x3033
let EGL_PBUFFER_BIT: Int32 = 0x0001
let EGL_RENDERABLE_TYPE: Int32 = 0x3040
let EGL_OPENGL_BIT: Int32 = 0x0008
let EGL_RED_SIZE: Int32 = 0x3024
let EGL_GREEN_SIZE: Int32 = 0x3023
let EGL_BLUE_SIZE: Int32 = 0x3022
let EGL_ALPHA_SIZE: Int32 = 0x3021
let EGL_WIDTH: Int32 = 0x3057
let EGL_HEIGHT: Int32 = 0x3056
let EGL_NONE: Int32 = 0x3038
let EGL_OPENGL_API: UInt32 = 0x30A2
let EGL_CONTEXT_MAJOR_VERSION: Int32 = 0x3098
let EGL_CONTEXT_MINOR_VERSION: Int32 = 0x30FB
let EGL_CONTEXT_OPENGL_PROFILE_MASK: Int32 = 0x30FD
let EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: Int32 = 0x0001

@main
enum GLBackendCheck {
    static var failures = 0

    static func expect(
        _ pixels: [UInt8], _ x: Int, _ y: Int, _ expected: [UInt8],
        tolerance: Int = 2, _ label: String
    ) {
        let base = (y * 64 + x) * 4
        let actual = Array(pixels[base..<base + 4])
        for (a, e) in zip(actual, expected) where abs(Int(a) - Int(e)) > tolerance {
            print("FAIL \(label): pixel(\(x),\(y)) = \(actual), expected \(expected)")
            failures += 1
            return
        }
        print("ok   \(label)")
    }

    /// Pixel space -> clip space for the 64x64 target (top-left origin).
    static let pixelTransform: [Double] = [
        2.0 / 64, 0, 0, 0,
        0, -2.0 / 64, 0, 0,
        0, 0, 0, 0,
        -1, 1, 0, 1,
    ]

    static func makeContextCurrent() -> Bool {
        guard let display = eglGetDisplay(nil), eglInitialize(display, nil, nil) != 0,
              eglBindAPI(EGL_OPENGL_API) != 0 else {
            return false
        }
        let configAttributes: [Int32] = [
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_NONE,
        ]
        var config: UnsafeMutableRawPointer?
        var configCount: Int32 = 0
        guard eglChooseConfig(display, configAttributes, &config, 1, &configCount) != 0,
              configCount > 0 else {
            return false
        }
        let surfaceAttributes: [Int32] = [EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE]
        // Core 3.3, matching the SDL context isomer's Linux host
        // creates (the backend's shaders are GLSL 330 core).
        let contextAttributes: [Int32] = [
            EGL_CONTEXT_MAJOR_VERSION, 3,
            EGL_CONTEXT_MINOR_VERSION, 3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE,
        ]
        guard let surface = eglCreatePbufferSurface(display, config, surfaceAttributes),
              let context = eglCreateContext(display, config, nil, contextAttributes) else {
            return false
        }
        return eglMakeCurrent(display, surface, surface, context) != 0
    }

    static func main() {
        guard makeContextCurrent() else {
            print("FAIL: no EGL pbuffer GL context")
            fatalError()
        }
        let device = GLGPUDevice()

        // 1. Clear + opaque color triangle.
        device.renderFrame(widthPx: 64, heightPx: 64, clear: GPUColor(red: 0, green: 0, blue: 1)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawColor(vertices: [
                0, 0, 1, 0, 0, 1,
                64, 0, 1, 0, 0, 1,
                0, 64, 1, 0, 0, 1,
            ])
        }
        var pixels = device.readPixels(widthPx: 64, heightPx: 64)
        expect(pixels, 4, 4, [255, 0, 0, 255], "triangle interior")
        expect(pixels, 60, 60, [0, 0, 255, 255], "cleared background")

        // 2. 2x2 texture (green left column, white right) magnified over a
        //    32px quad: linear clamp-to-edge sampling.
        let texture = device.makeTexture(width: 2, height: 2, rgba: [
            0, 255, 0, 255, 255, 255, 255, 255,
            0, 255, 0, 255, 255, 255, 255, 255,
        ])
        device.renderFrame(widthPx: 64, heightPx: 64, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawTextured(vertices: [
                0, 0, 0, 0, 32, 0, 1, 0, 0, 32, 0, 1,
                32, 0, 1, 0, 32, 32, 1, 1, 0, 32, 0, 1,
            ], texture: texture)
        }
        pixels = device.readPixels(widthPx: 64, heightPx: 64)
        expect(pixels, 2, 16, [0, 255, 0, 255], "texture left = green")
        expect(pixels, 30, 16, [255, 255, 255, 255], "texture right = white")
        device.destroyTexture(texture)

        // 3. SDF rounded rect + scissor halves.
        device.renderFrame(widthPx: 64, heightPx: 64, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawRects(instances: [
                8, 8, 48, 48, 20, 0, 1, 1, 1, 1, 0,
            ])
            pass.setScissor(x: 0, y: 0, width: 32, height: 64)
            pass.drawRects(instances: [
                0, 56, 64, 8, 0, 0, 1, 0, 0, 1, 0,
            ])
            pass.clearScissor()
        }
        pixels = device.readPixels(widthPx: 64, heightPx: 64)
        expect(pixels, 32, 32, [255, 255, 255, 255], "rect center")
        expect(pixels, 9, 9, [0, 0, 0, 255], "rounded corner cut")
        expect(pixels, 10, 60, [255, 0, 0, 255], "inside scissor")
        expect(pixels, 50, 60, [0, 0, 0, 255], "outside scissor")

        // 4. Straight-alpha blend: 50% white over black -> mid gray.
        device.renderFrame(widthPx: 64, heightPx: 64, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawColor(vertices: [
                0, 0, 1, 1, 1, 0.5,
                8, 0, 1, 1, 1, 0.5,
                0, 8, 1, 1, 1, 0.5,
            ])
        }
        pixels = device.readPixels(widthPx: 64, heightPx: 64)
        expect(pixels, 2, 2, [127, 127, 127, 255], tolerance: 3, "straight-alpha blend")

        // 5. Premultiplied blend (the drawTextured contract): a premultiplied
        //    50%-white texel over black must also land mid gray.
        let translucent = device.makeTexture(width: 1, height: 1, rgba: [128, 128, 128, 128])
        device.renderFrame(widthPx: 64, heightPx: 64, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawTextured(vertices: [
                0, 0, 0, 0, 16, 0, 1, 0, 0, 16, 0, 1,
                16, 0, 1, 0, 16, 16, 1, 1, 0, 16, 0, 1,
            ], texture: translucent)
        }
        pixels = device.readPixels(widthPx: 64, heightPx: 64)
        expect(pixels, 4, 4, [128, 128, 128, 255], tolerance: 3, "premultiplied blend")
        device.destroyTexture(translucent)

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            fatalError()
        }
        print("OK: all GL backend checks passed")
    }
}
