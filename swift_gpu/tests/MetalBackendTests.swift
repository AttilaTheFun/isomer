import SwiftGPU
import XCTest

final class MetalBackendTests: XCTestCase {
    func testOffscreenClearAndColorTriangle() throws {
        guard let device = MetalGPUDevice() else {
            throw XCTSkip("no Metal device")
        }
        // 64x64, cleared blue, with an opaque red triangle covering the
        // top-left corner. The transform maps pixel space to NDC.
        let pixels = device.renderOffscreen(width: 64, height: 64, clear: GPUColor(red: 0, green: 0, blue: 1)) { pass in
            pass.setTransform([
                2.0 / 64, 0, 0, 0,
                0, -2.0 / 64, 0, 0,
                0, 0, 0, 0,
                -1, 1, 0, 1,
            ])
            pass.drawColor(vertices: [
                0, 0, 1, 0, 0, 1,
                64, 0, 1, 0, 0, 1,
                0, 64, 1, 0, 0, 1,
            ])
        }
        XCTAssertEqual(pixels.count, 64 * 64 * 4)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let base = (y * 64 + x) * 4
            return Array(pixels[base..<base + 4])
        }
        XCTAssertEqual(pixel(4, 4), [255, 0, 0, 255])      // triangle interior
        XCTAssertEqual(pixel(60, 60), [0, 0, 255, 255])    // cleared background
    }

    func testTexturedQuadSamplesTexture() throws {
        guard let device = MetalGPUDevice() else {
            throw XCTSkip("no Metal device")
        }
        // A 2x2 texture: green left column, white right column, magnified
        // over a 32x32 quad.
        let texture = device.makeTexture(width: 2, height: 2, rgba: [
            0, 255, 0, 255, 255, 255, 255, 255,
            0, 255, 0, 255, 255, 255, 255, 255,
        ])
        let pixels = device.renderOffscreen(width: 32, height: 32, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform([
                2.0 / 32, 0, 0, 0,
                0, -2.0 / 32, 0, 0,
                0, 0, 0, 0,
                -1, 1, 0, 1,
            ])
            pass.drawTextured(vertices: [
                0, 0, 0, 0, 32, 0, 1, 0, 0, 32, 0, 1,
                32, 0, 1, 0, 32, 32, 1, 1, 0, 32, 0, 1,
            ], texture: texture)
        }

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let base = (y * 32 + x) * 4
            return Array(pixels[base..<base + 4])
        }
        XCTAssertEqual(pixel(2, 16), [0, 255, 0, 255])       // left = green
        XCTAssertEqual(pixel(30, 16), [255, 255, 255, 255])  // right = white
        device.destroyTexture(texture)
    }

    func testRoundedRectAndScissor() throws {
        guard let device = MetalGPUDevice() else {
            throw XCTSkip("no Metal device")
        }
        let pixels = device.renderOffscreen(width: 64, height: 64, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform([
                2.0 / 64, 0, 0, 0,
                0, -2.0 / 64, 0, 0,
                0, 0, 0, 0,
                -1, 1, 0, 1,
            ])
            // A heavily rounded white rect: corners cut, center filled.
            pass.drawRects(instances: [
                8, 8, 48, 48, 20, 0, 1, 1, 1, 1, 0,
            ])
            // Scissored red fill: only the left half survives.
            pass.setScissor(x: 0, y: 0, width: 32, height: 64)
            pass.drawRects(instances: [
                0, 56, 64, 8, 0, 0, 1, 0, 0, 1, 0,
            ])
            pass.clearScissor()
        }
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let base = (y * 64 + x) * 4
            return Array(pixels[base..<base + 4])
        }
        XCTAssertEqual(pixel(32, 32), [255, 255, 255, 255])  // rect center
        XCTAssertEqual(pixel(9, 9), [0, 0, 0, 255])          // rounded corner cut
        XCTAssertEqual(pixel(10, 60), [255, 0, 0, 255])      // inside scissor
        XCTAssertEqual(pixel(50, 60), [0, 0, 0, 255])        // outside scissor
    }

    func testBlendedColorOverClear() throws {
        guard let device = MetalGPUDevice() else {
            throw XCTSkip("no Metal device")
        }
        // 50%-alpha white over black must blend to mid gray.
        let pixels = device.renderOffscreen(width: 8, height: 8, clear: GPUColor(red: 0, green: 0, blue: 0)) { pass in
            pass.setTransform([
                2.0 / 8, 0, 0, 0,
                0, -2.0 / 8, 0, 0,
                0, 0, 0, 0,
                -1, 1, 0, 1,
            ])
            pass.drawColor(vertices: [
                0, 0, 1, 1, 1, 0.5,
                8, 0, 1, 1, 1, 0.5,
                0, 8, 1, 1, 1, 0.5,
            ])
        }
        let base = (2 * 8 + 2) * 4
        XCTAssertEqual(Double(pixels[base]), 127.5, accuracy: 2)
        XCTAssertEqual(Double(pixels[base + 1]), 127.5, accuracy: 2)
    }
}
