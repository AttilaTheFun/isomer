// PhotosUI's SwiftUI picker, where Apple's isn't: `.photosPicker` hands the
// host's photo picker a request (a file input on the web, the system photo
// picker on Android), and the picked photos and videos come back as items
// whose bytes are in files Foundation can read. Apple platforms use Apple's.

import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Which photos a `.photosPicker` offers.
public struct PHPickerFilter: Hashable, Sendable {
    let mimeTypes: [String]

    public static let images = PHPickerFilter(mimeTypes: ["image/*"])
    public static let videos = PHPickerFilter(mimeTypes: ["video/*"])
    public static let livePhotos = PHPickerFilter(mimeTypes: ["image/*"])
    public static let screenshots = PHPickerFilter(mimeTypes: ["image/*"])

    public static func any(of subfilters: [PHPickerFilter]) -> PHPickerFilter {
        PHPickerFilter(mimeTypes: subfilters.flatMap(\.mimeTypes))
    }
}

/// How several picked photos are ordered and chosen (the host's own way).
public struct PhotosPickerSelectionBehavior: Hashable, Sendable {
    let name: String
    public static let `default` = PhotosPickerSelectionBehavior(name: "default")
    public static let ordered = PhotosPickerSelectionBehavior(name: "ordered")
    public static let continuous = PhotosPickerSelectionBehavior(name: "continuous")
    public static let continuousAndOrdered = PhotosPickerSelectionBehavior(name: "continuousAndOrdered")
}

/// A photo or video the person picked.
public struct PhotosPickerItem: Hashable, Sendable {
    /// Where the item's encoding may be changed to one the app reads (the
    /// host hands over the file as picked).
    public struct EncodingDisambiguationPolicy: Hashable, Sendable {
        let name: String
        public static let automatic = EncodingDisambiguationPolicy(name: "automatic")
        public static let current = EncodingDisambiguationPolicy(name: "current")
        public static let compatible = EncodingDisambiguationPolicy(name: "compatible")
    }

    let path: String

    /// An item by its identifier: the picked file's path.
    public init(itemIdentifier: String) {
        path = itemIdentifier
    }

    /// The picked file's name.
    public var itemIdentifier: String? { String(path.split(separator: "/").last ?? "") }

    public var supportedContentTypes: [UTType] {
        let name = (itemIdentifier ?? "").lowercased()
        for (suffix, type) in [(".png", UTType.png), (".jpg", UTType.jpeg), (".jpeg", UTType.jpeg), (".gif", UTType.gif),
                               (".webp", UTType.webP), (".heic", UTType.heic), (".mp4", UTType.movie), (".mov", UTType.movie),
                               (".webm", UTType.movie), (".3gp", UTType.movie)] where name.hasSuffix(suffix) {
            return [type]
        }
        return [.image]
    }

    /// The item's bytes (`Data`) or its file (`URL`).
    public func loadTransferable<T: Transferable>(type: T.Type) async throws -> T? {
        let url = URL(fileURLWithPath: path)
        if T.self == URL.self { return url as? T }
        if T.self == Data.self { return try Data(contentsOf: url) as? T }
        return nil
    }
}

extension View {
    /// Photos and videos from the platform's photo picker.
    nonisolated public func photosPicker(
        isPresented: Binding<Bool>,
        selection: Binding<[PhotosPickerItem]>,
        maxSelectionCount: Int? = nil,
        selectionBehavior: PhotosPickerSelectionBehavior = .default,
        matching filter: PHPickerFilter? = nil,
        preferredItemEncoding: PhotosPickerItem.EncodingDisambiguationPolicy = .automatic
    ) -> some View {
        let types = (filter ?? .any(of: [.images, .videos])).mimeTypes.joined(separator: ",")
        return _PickerRequest(
            child: self, isPresented: isPresented, kind: "photos",
            params: [("accept", types), ("multiple", maxSelectionCount == 1 ? "0" : "1"), ("max", String(maxSelectionCount ?? 0))],
            onResult: { paths in
                guard !paths.isEmpty else { return }
                selection.wrappedValue = paths.map { PhotosPickerItem(itemIdentifier: $0) }
            })
    }

    /// One photo or video from the platform's photo picker.
    nonisolated public func photosPicker(
        isPresented: Binding<Bool>,
        selection: Binding<PhotosPickerItem?>,
        matching filter: PHPickerFilter? = nil,
        preferredItemEncoding: PhotosPickerItem.EncodingDisambiguationPolicy = .automatic
    ) -> some View {
        let types = (filter ?? .any(of: [.images, .videos])).mimeTypes.joined(separator: ",")
        return _PickerRequest(
            child: self, isPresented: isPresented, kind: "photos",
            params: [("accept", types), ("multiple", "0"), ("max", "1")],
            onResult: { paths in
                if let path = paths.first { selection.wrappedValue = PhotosPickerItem(itemIdentifier: path) }
            })
    }
}
