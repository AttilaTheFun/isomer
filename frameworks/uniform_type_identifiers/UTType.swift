// UniformTypeIdentifiers' `UTType`, as far as SwiftUI's pickers take it: a
// kind of content (`allowedContentTypes: [.image, .pdf]`), and the MIME type
// a host filters by. Apple platforms use Apple's.

import Foundation

public struct UTType: Hashable, Sendable {
    public let identifier: String
    /// The MIME type hosts filter by ("image/*" for a family).
    public let preferredMIMEType: String?

    /// A type by its identifier (a known one's MIME type comes with it).
    public init?(_ identifier: String) {
        let known = UTType.known.first { $0.identifier == identifier }
        self.init(identifier: identifier, mimeType: known?.preferredMIMEType)
    }

    public init?(mimeType: String, conformingTo supertype: UTType = .data) {
        let known = UTType.known.first { $0.preferredMIMEType == mimeType }
        self.init(identifier: known?.identifier ?? "dyn." + mimeType, mimeType: mimeType)
    }

    public init?(filenameExtension: String, conformingTo supertype: UTType = .data) {
        guard let mime = UTType.extensions[filenameExtension.lowercased()] else { return nil }
        self.init(mimeType: mime, conformingTo: supertype)
    }

    init(identifier: String, mimeType: String?) {
        self.identifier = identifier
        self.preferredMIMEType = mimeType
    }

    /// Its usual file extension.
    public var preferredFilenameExtension: String? {
        UTType.extensions.first { $0.value == preferredMIMEType }?.key
    }

    public static let item = UTType(identifier: "public.item", mimeType: "*/*")
    public static let content = UTType(identifier: "public.content", mimeType: "*/*")
    public static let data = UTType(identifier: "public.data", mimeType: "*/*")
    public static let image = UTType(identifier: "public.image", mimeType: "image/*")
    public static let jpeg = UTType(identifier: "public.jpeg", mimeType: "image/jpeg")
    public static let png = UTType(identifier: "public.png", mimeType: "image/png")
    public static let gif = UTType(identifier: "com.compuserve.gif", mimeType: "image/gif")
    public static let webP = UTType(identifier: "org.webmproject.webp", mimeType: "image/webp")
    public static let heic = UTType(identifier: "public.heic", mimeType: "image/heic")
    public static let tiff = UTType(identifier: "public.tiff", mimeType: "image/tiff")
    public static let movie = UTType(identifier: "public.movie", mimeType: "video/*")
    public static let video = UTType(identifier: "public.video", mimeType: "video/*")
    public static let mpeg4Movie = UTType(identifier: "public.mpeg-4", mimeType: "video/mp4")
    public static let quickTimeMovie = UTType(identifier: "com.apple.quicktime-movie", mimeType: "video/quicktime")
    public static let audio = UTType(identifier: "public.audio", mimeType: "audio/*")
    public static let pdf = UTType(identifier: "com.adobe.pdf", mimeType: "application/pdf")
    public static let text = UTType(identifier: "public.text", mimeType: "text/*")
    public static let plainText = UTType(identifier: "public.plain-text", mimeType: "text/plain")
    public static let utf8PlainText = UTType(identifier: "public.utf8-plain-text", mimeType: "text/plain")
    public static let json = UTType(identifier: "public.json", mimeType: "application/json")
    public static let html = UTType(identifier: "public.html", mimeType: "text/html")
    public static let url = UTType(identifier: "public.url", mimeType: nil)
    public static let fileURL = UTType(identifier: "public.file-url", mimeType: nil)
    public static let zip = UTType(identifier: "public.zip-archive", mimeType: "application/zip")

    static let known: [UTType] = [
        .item, .content, .data, .image, .jpeg, .png, .gif, .webP, .heic, .tiff, .movie, .video,
        .mpeg4Movie, .quickTimeMovie, .audio, .pdf, .text, .plainText, .json, .html, .zip,
    ]

    static let extensions: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "tif": "image/tiff", "tiff": "image/tiff", "mp4": "video/mp4", "mov": "video/quicktime",
        "pdf": "application/pdf", "txt": "text/plain", "json": "application/json", "html": "text/html",
        "zip": "application/zip",
    ]
}
