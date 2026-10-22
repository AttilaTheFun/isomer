// The SwiftGPU renderer's host services on UIKit/CoreGraphics: text
// measurement and rasterization (text, gradients, shadows) — lifted from
// the compiled Metal benchmark cell.

import Foundation
import SwiftGPU
import UIKit
public import IsomerSwiftUI

private typealias CFSize = CoreFoundation.CGSize
private typealias CFRect = CoreFoundation.CGRect

// MARK: - Host services (measurement + rasterization on UIKit/CoreGraphics)

final class GPUTreeServicesHost: HostBridge {
    static let lineHeight: CGFloat = 1.3

    private func font(size: Double, weight: Int) -> UIFont {
        let uiWeight: UIFont.Weight
        switch weight {
        case ..<350: uiWeight = .light
        case ..<450: uiWeight = .regular
        case ..<550: uiWeight = .medium
        case ..<650: uiWeight = .semibold
        default: uiWeight = .bold
        }
        return .systemFont(ofSize: size, weight: uiWeight)
    }

    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size: fontSize, weight: weight)]
        let bounds = CFSize(
            width: wrapWidth ?? Double.greatestFiniteMagnitude,
            height: Double.greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        let lines = max(1.0, ((rect.height) / (fontSize * 1.2)).rounded())
        return CGSize(width: Double(ceil(rect.width)), height: lines * fontSize * Self.lineHeight)
    }

    // MARK: Images

    /// Decoded images by source: the app bundle's assets by name, remote
    /// ones loaded once (a frame is scheduled when one arrives).
    private var images: [String: UIImage] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus {
        if let image = images[source] { return .ready(CGSize(width: Double(image.size.width), height: Double(image.size.height))) }
        if failed.contains(source) { return .failed }
        if !isRemote {
            guard let image = UIImage(named: source) ?? UIImage(contentsOfFile: source) else {
                failed.insert(source)
                return .failed
            }
            images[source] = image
            return .ready(CGSize(width: Double(image.size.width), height: Double(image.size.height)))
        }
        guard !loading.contains(source), let url = URL(string: source) else { return .loading }
        loading.insert(source)
        Task { @MainActor [weak self] in
            let image = (try? await URLSession.shared.data(from: url)).flatMap { UIImage(data: $0.0) }
            guard let self else { return }
            self.loading.remove(source)
            if let image { self.images[source] = image } else { self.failed.insert(source) }
            self.onScheduleRender?()
        }
        return .loading
    }

    /// Rasterize SwiftGPURenderer specs ([w u32][h u32][premultiplied RGBA8…]).
    func rasterize(_ spec: String) -> [UInt8] {
        guard let data = spec.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = json["kind"] as? String
        else { return [] }
        let scale = CGFloat(UIScreen.main.scale)

        func pack(_ image: UIImage) -> [UInt8] {
            guard let cg = image.cgImage else { return [] }
            let width = cg.width
            let height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CFRect(x: 0, y: 0, width: Double(width), height: Double(height)))
            var out = [UInt8]()
            out.reserveCapacity(8 + pixels.count)
            for value in [UInt32(width), UInt32(height)] {
                out.append(UInt8(value & 0xFF))
                out.append(UInt8((value >> 8) & 0xFF))
                out.append(UInt8((value >> 16) & 0xFF))
                out.append(UInt8((value >> 24) & 0xFF))
            }
            out.append(contentsOf: pixels)
            return out
        }

        func color(_ r: Any?, _ g: Any?, _ b: Any?, _ a: Any?) -> UIColor {
            UIColor(
                red: CGFloat((r as? Double) ?? 0), green: CGFloat((g as? Double) ?? 0),
                blue: CGFloat((b as? Double) ?? 0), alpha: CGFloat((a as? Double) ?? 1))
        }

        switch kind {
        case "image":
            guard let source = json["source"] as? String, let image = images[source] else { return [] }
            return pack(image)
        case "text":
            let text = json["text"] as? String ?? ""
            let size = json["size"] as? Double ?? 17
            let weight = json["weight"] as? Int ?? 400
            let wrap = json["wrap"] as? Double ?? 0
            let textColor = color(json["r"], json["g"], json["b"], json["a"])
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, weight: weight), .foregroundColor: textColor,
            ]
            let bounds = CFSize(
                width: wrap > 0 ? wrap + 1 : Double.greatestFiniteMagnitude,
                height: Double.greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            let sizePts = CFSize(width: ceil(rect.width) + 1, height: ceil(rect.height))
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: sizePts, format: format)
            let image = renderer.image { _ in
                (text as NSString).draw(
                    with: CFRect(origin: .zero, size: sizePts),
                    options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            }
            return pack(image)
        case "gradient", "shadow":
            let w = json["w"] as? Double ?? 1
            let h = json["h"] as? Double ?? 1
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let sizePts = CFSize(width: max(w, 1), height: max(h, 1))
            let renderer = UIGraphicsImageRenderer(size: sizePts, format: format)
            let fill = color(json["r"], json["g"], json["b"], json["a"])
            let image = renderer.image { ctx in
                fill.setFill()
                ctx.fill(CFRect(origin: .zero, size: sizePts))
            }
            return pack(image)
        default:
            return []
        }
    }

    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}

    var onScheduleRender: (() -> Void)?

    func scheduleRender() {
        MainActor.assumeIsolated { onScheduleRender?() }
    }

    func now() -> Double { Foundation.Date().timeIntervalSince1970 }

    func log(_ message: String) { NSLog("%@", message) }
}

