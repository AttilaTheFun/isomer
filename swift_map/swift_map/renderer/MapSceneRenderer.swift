// The single cross-platform frame renderer: draws MapFrames through
// SwiftGPU on every platform (Metal / OpenGL ES / WebGPU behind one API).
// Owns the tile texture cache the engine's eviction policy drives. This
// file (plus each platform's device setup) is the only place in swift_map
// that imports SwiftGPU.

// canImport: the XCFramework distribution compiles SwiftGPU's sources into
// this module (apple_xcframework forbids transitive swift_library deps).
#if canImport(SwiftGPU)
import SwiftGPU
#endif

public final class MapSceneRenderer {
    /// The map background where no tile has loaded yet (OSM land tone).
    public static let clearColor = GPUColor(red: 0.949, green: 0.937, blue: 0.913)

    private let device: GPUDevice
    private var textures: [String: GPUTexture] = [:]

    public init(device: GPUDevice) {
        self.device = device
    }

    // MARK: - Texture cache (keys are TileKey.id strings)

    /// Upload a decoded tile (tightly packed straight-alpha RGBA8).
    public func setTexture(rgba: [UInt8], width: Int, height: Int, forKey key: String) {
        if let old = textures[key] {
            device.destroyTexture(old)
        }
        textures[key] = device.makeTexture(width: width, height: height, rgba: rgba)
    }

    public func removeTexture(forKey key: String) {
        if let texture = textures.removeValue(forKey: key) {
            device.destroyTexture(texture)
        }
    }

    public func hasTexture(forKey key: String) -> Bool {
        textures[key] != nil
    }

    /// Drop every handle without destroy calls — for GL-style context loss,
    /// where the native resources died with the old context.
    public func reset() {
        textures.removeAll()
    }

    // MARK: - Drawing

    /// Encode the frame in paint order: tiles, then map-plane overlay
    /// shapes (both under the frame matrix), then billboarded markers
    /// (under the plain screen matrix).
    public func draw(frame: MapFrame, into pass: GPURenderPass) {
        pass.setTransform(frame.matrix)

        for quad in frame.quads {
            guard let texture = textures[quad.textureKey] else { continue }
            let x0 = Float(quad.x)
            let y0 = Float(quad.y)
            let x1 = Float(quad.x + quad.size)
            let y1 = Float(quad.y + quad.size)
            let u0 = Float(quad.u)
            let v0 = Float(quad.v)
            let u1 = Float(quad.u + quad.uvSize)
            let v1 = Float(quad.v + quad.uvSize)
            pass.drawTextured(vertices: [
                x0, y0, u0, v0, x1, y0, u1, v0, x0, y1, u0, v1,
                x1, y0, u1, v0, x1, y1, u1, v1, x0, y1, u0, v1,
            ], texture: texture)
        }

        if !frame.shapeVertices.isEmpty {
            pass.drawColor(vertices: frame.shapeVertices.map { Float($0) })
        }
        if !frame.markVertices.isEmpty {
            pass.setTransform(frame.screenMatrix)
            pass.drawColor(vertices: frame.markVertices.map { Float($0) })
        }
    }
}
