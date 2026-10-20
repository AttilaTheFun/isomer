// The camera's view projection: bearing (rotation about the screen center)
// and tilt (the top of the map receding, MapKit-pitch style), expressed as
// one homogeneous matrix so the GPU interpolates tile UVs
// perspective-correctly. Quads stay in "flat screen points" — the
// untransformed space `buildFrame` lays tiles out in — and the matrix takes
// them all the way to clip space (Metal/WebGPU/GL agree for z = 0).

#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(CRT)
import CRT
#endif

struct Projection {
    let halfWidth: Double
    let halfHeight: Double
    /// Perspective distance from the camera to the map plane, in points.
    let distance: Double
    let sinTilt: Double
    let cosTilt: Double
    // Flat -> rotated screen-space rotation coefficients (row-major 2x2).
    let a: Double
    let b: Double
    let c: Double
    let e: Double

    init(viewportWidth: Double, viewportHeight: Double, bearing: Double, tilt: Double) {
        halfWidth = max(viewportWidth / 2, 1)
        halfHeight = max(viewportHeight / 2, 1)
        // MapLibre-style camera: 1.5 viewport-heights above the plane.
        distance = max(1.5 * viewportHeight, 1)
        let tiltRadians = tilt * Double.pi / 180
        sinTilt = sin(tiltRadians)
        cosTilt = cos(tiltRadians)
        // The content rotates opposite the camera heading.
        let rho = -bearing * Double.pi / 180
        a = cos(rho)
        b = -sin(rho)
        c = sin(rho)
        e = cos(rho)
    }

    /// Column-major 4x4 taking (x, y, 0, 1) in flat screen points to clip
    /// space: center, rotate by bearing, recede the far edge by tilt
    /// (perspective divide via w), and scale to NDC.
    func matrix() -> [Double] {
        let sx = distance / halfWidth
        let sy = -distance * cosTilt / halfHeight
        return [
            sx * a, sy * c, 0, -sinTilt * c,
            sx * b, sy * e, 0, -sinTilt * e,
            0, 0, 0, 0,
            -sx * (a * halfWidth + b * halfHeight),
            -sy * (c * halfWidth + e * halfHeight),
            0,
            distance + sinTilt * (c * halfWidth + e * halfHeight),
        ]
    }

    /// Inverse of `matrix()` for a screen point: the flat-space offset from
    /// the viewport center that projects there. Used for visible-tile
    /// footprints and anchor-fixed zooming under rotation/tilt.
    func unproject(screenX: Double, screenY: Double) -> (x: Double, y: Double) {
        let nx = screenX / halfWidth - 1
        let ny = 1 - screenY / halfHeight
        let yRot = ny * distance / (ny * sinTilt - distance * cosTilt / halfHeight)
        let xRot = nx * (distance - sinTilt * yRot) * halfWidth / distance
        // Inverse rotation = transpose.
        return (a * xRot + c * yRot, b * xRot + e * yRot)
    }
}
