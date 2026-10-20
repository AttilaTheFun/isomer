// Offscreen pixel checks for the D3D11 backend, mirroring
// tests/MetalBackendTests.swift — a plain executable (no XCTest) that exits
// non-zero on a mismatch, like isomer's snapshot checker. One global
// D3D context per process, so every check renders into one 64x64 target.

import SwiftGPU

@main
enum DirectXBackendCheck {
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

    static func main() {
        guard let device = DirectXGPUDevice(offscreenWidthPx: 64, heightPx: 64) else {
            print("FAIL: no D3D11 device (hardware or WARP)")
            fatalError()
        }

        // 1. Clear + opaque color triangle.
        var pixels = device.renderOffscreen(clear: GPUColor(red: 0, green: 0, blue: 1)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawColor(vertices: [
                0, 0, 1, 0, 0, 1,
                64, 0, 1, 0, 0, 1,
                0, 64, 1, 0, 0, 1,
            ])
        }
        expect(pixels, 4, 4, [255, 0, 0, 255], "triangle interior")
        expect(pixels, 60, 60, [0, 0, 255, 255], "cleared background")

        // 2. 2x2 texture (green left column, white right) magnified over a
        //    32px quad: linear clamp-to-edge sampling.
        let texture = device.makeTexture(width: 2, height: 2, rgba: [
            0, 255, 0, 255, 255, 255, 255, 255,
            0, 255, 0, 255, 255, 255, 255, 255,
        ])
        pixels = device.renderOffscreen(clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawTextured(vertices: [
                0, 0, 0, 0, 32, 0, 1, 0, 0, 32, 0, 1,
                32, 0, 1, 0, 32, 32, 1, 1, 0, 32, 0, 1,
            ], texture: texture)
        }
        expect(pixels, 2, 16, [0, 255, 0, 255], "texture left = green")
        expect(pixels, 30, 16, [255, 255, 255, 255], "texture right = white")
        device.destroyTexture(texture)

        // 3. SDF rounded rect + scissor halves.
        pixels = device.renderOffscreen(clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
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
        expect(pixels, 32, 32, [255, 255, 255, 255], "rect center")
        expect(pixels, 9, 9, [0, 0, 0, 255], "rounded corner cut")
        expect(pixels, 10, 60, [255, 0, 0, 255], "inside scissor")
        expect(pixels, 50, 60, [0, 0, 0, 255], "outside scissor")

        // 4. Straight-alpha blend: 50% white over black -> mid gray.
        pixels = device.renderOffscreen(clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawColor(vertices: [
                0, 0, 1, 1, 1, 0.5,
                8, 0, 1, 1, 1, 0.5,
                0, 8, 1, 1, 1, 0.5,
            ])
        }
        expect(pixels, 2, 2, [127, 127, 127, 255], tolerance: 3, "straight-alpha blend")

        // 5. Premultiplied blend (the drawTextured contract): a premultiplied
        //    50%-white texel over black must also land mid gray — without
        //    ONE/INV_SRC_ALPHA it lands at ~64 (double-multiplied).
        let translucent = device.makeTexture(width: 1, height: 1, rgba: [128, 128, 128, 128])
        pixels = device.renderOffscreen(clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform(pixelTransform)
            pass.drawTextured(vertices: [
                0, 0, 0, 0, 16, 0, 1, 0, 0, 16, 0, 1,
                16, 0, 1, 0, 16, 16, 1, 1, 0, 16, 0, 1,
            ], texture: translucent)
        }
        expect(pixels, 4, 4, [128, 128, 128, 255], tolerance: 3, "premultiplied blend")
        device.destroyTexture(translucent)

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            fatalError()
        }
        print("OK: all DirectX backend checks passed")
    }
}
