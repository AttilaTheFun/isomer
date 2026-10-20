// Image decode on Apple platforms: raw PNG/JPEG bytes -> tightly packed
// straight-alpha RGBA8, ready for GPUDevice.makeTexture. (Network bytes come
// from the injected TileFetcher; no GPU API appears here.)

import CoreGraphics
import Foundation
import ImageIO

public enum TileDecoder {
    public static func decodeRGBA(_ bytes: [UInt8]) -> (rgba: [UInt8], width: Int, height: Int)? {
        let data = Data(bytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }
}
