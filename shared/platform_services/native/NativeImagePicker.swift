// The image picker for Swift hosts: PHPickerViewController on iOS (presented
// over the top-most view controller), NSOpenPanel on macOS; elsewhere the
// service reports itself unavailable. The chosen image is scaled to
// `maxDimension` on its long side, written as a JPEG into the app's caches,
// and returned as a `file://` URL the host's image loader displays.

import Foundation

#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import PhotosUI
import UIKit

public final class NativeImagePickerService: NSObject, PHPickerViewControllerDelegate {
    private var continuation: CheckedContinuation<String, Error>?
    private var maxDimension = 1280

    public override init() {}

    public func pickImage(maxDimension: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard self.continuation == nil else {
                    continuation.resume(throwing: NativeServiceError("the image picker is already open"))
                    return
                }
                guard let presenter = Self.topViewController() else {
                    continuation.resume(throwing: NativeServiceError("no view controller to present the image picker from"))
                    return
                }
                self.continuation = continuation
                self.maxDimension = maxDimension
                var configuration = PHPickerConfiguration()
                configuration.filter = .images
                configuration.selectionLimit = 1
                let picker = PHPickerViewController(configuration: configuration)
                picker.delegate = self
                presenter.present(picker, animated: true)
            }
        }
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let continuation = self.continuation
        self.continuation = nil
        guard let item = results.first?.itemProvider, item.canLoadObject(ofClass: UIImage.self) else {
            continuation?.resume(returning: "")
            return
        }
        let maxDimension = self.maxDimension
        item.loadObject(ofClass: UIImage.self) { object, _ in
            let url = (object as? UIImage).flatMap { Self.dataURL($0, maxDimension: maxDimension) } ?? ""
            continuation?.resume(returning: url)
        }
    }

    static func dataURL(_ image: UIImage, maxDimension: Int) -> String? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, CGFloat(maxDimension) / max(1, longest))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return pickedFileURL(jpeg)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

#elseif canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

public final class NativeImagePickerService {
    public init() {}

    public func pickImage(maxDimension: Int) async throws -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                let response = panel.runModal()
                guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: Self.dataURL(image, maxDimension: maxDimension) ?? "")
            }
        }
    }

    static func dataURL(_ image: NSImage, maxDimension: Int) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = max(cg.width, cg.height)
        let scale = min(1, Double(maxDimension) / Double(max(1, longest)))
        let width = Int(Double(cg.width) * scale), height = Int(Double(cg.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let _ = Optional(context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))),
            let scaled = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return pickedFileURL(jpeg)
    }
}

#else

/// No image chooser on this host.
public struct ImagePickerUnavailable: Error, CustomStringConvertible {
    public var description: String { "no image picker on this platform" }
}

public final class NativeImagePickerService {
    public init() {}
    public func pickImage(maxDimension: Int) async throws -> String {
        throw ImagePickerUnavailable()
    }
}

#endif

#if canImport(UIKit) || canImport(AppKit)
/// Writes a picked image into Caches/iso-picked/<uuid>.jpg; returns its URL.
func pickedFileURL(_ jpeg: Data) -> String? {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let folder = caches.appendingPathComponent("iso-picked", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(UUID().uuidString + ".jpg")
    guard (try? jpeg.write(to: file)) != nil else { return nil }
    return file.absoluteString
}
#endif
