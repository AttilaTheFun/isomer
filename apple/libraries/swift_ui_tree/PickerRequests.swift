// A picker the app asked for (`.fileImporter`, `.photosPicker`,
// `.cameraCapture` in the guest): a presentation layer flagged `request` on
// the wire, which the host answers with the system's own picker rather than
// a sheet — the document picker, the photo picker, the camera. A file's
// preview (`.quickLookPreview`) is asked for the same way, and answered
// when it closes. What the
// person picks is written where the app can read it (`IsomerPickedFiles`)
// and the paths go back on the layer's `result` handler, newline-separated
// ("" when cancelled), as the web's file input and Android's pickers answer.

import Foundation
import SwiftUI
#if os(iOS) || os(macOS)
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
#endif
#if os(iOS)
import UIKit
#endif

/// Where what a person picks is put for the app: the folder the host writes
/// in, and the same folder as the app reads it — its own path for an app
/// compiled for the device, `/tmp/…` in a wasm guest (the WAMR host maps a
/// folder of its temporary directory there; WasmView points this at it).
public enum IsomerPickedFiles {
    nonisolated(unsafe) public static var folder: (host: URL, app: String) = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isomer-picked", isDirectory: true)
        return (url, url.path)
    }()

    /// Writes `data` as `name`, in a folder of its own (two picks of the
    /// same name do not meet); the path the app reads it at.
    static func store(_ data: Data, name: String) -> String? {
        let id = UUID().uuidString
        let dir = folder.host.appendingPathComponent(id, isDirectory: true)
        let safe = name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "_")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(safe))
        } catch {
            return nil
        }
        return folder.app + "/" + id + "/" + safe
    }

    /// Where the host finds a file the app names: under the folder picks
    /// are put, the host's side of it; elsewhere the app's path as it is
    /// (an app compiled for the device shares the host's files).
    static func hostURL(_ path: String) -> URL {
        let (host, app) = folder
        if path.hasPrefix(app + "/"), app != host.path {
            return host.appendingPathComponent(String(path.dropFirst(app.count + 1)))
        }
        return URL(fileURLWithPath: path)
    }
}

#if os(iOS) || os(macOS)
/// Presents the system's picker for a request layer and answers it.
struct PickerRequests: ViewModifier {
    let request: PatchedNode?
    let send: (String, String) -> Void

    /// Each request the layer makes is a new one (a modifier's requests
    /// share their result id): its picker opens once, is answered once,
    /// and is a picker of its own (`.id`), not the last one closing.
    @State private var token = 0
    @State private var closedToken: Int?
    @State private var answeredToken: Int?
    @State private var pickingToken: Int?

    private func param(_ key: String) -> String? {
        request?.flat.params.first { $0.key == key }?.value
    }
    private var kind: String? { param("request") }
    private var resultID: String? { param("result") }

    private func answer(_ paths: [String], for asked: Int) {
        guard answeredToken != asked, asked == token, let id = resultID else { return }
        answeredToken = asked
        send(id, paths.joined(separator: "\n"))
    }

    /// Open while the layer asks for this kind of picker and this request's
    /// picker has not closed; closed without a pick, it is answered as
    /// cancelled (a moment later: a pick's answer comes after its picker
    /// closes).
    private func presented(_ which: String) -> Binding<Bool> {
        Binding(
            get: { kind == which && resultID != nil && closedToken != token },
            set: { shown in
                guard !shown, kind == which else { return }
                let asked = token
                closedToken = asked
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if pickingToken != asked { answer([], for: asked) }
                }
            })
    }

    /// The MIME types asked for, as content types ("image/*" a family).
    private var contentTypes: [UTType] {
        let types = (param("accept") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let mapped = types.compactMap { mime -> UTType? in
            switch mime {
            case "", "*/*": return .item
            case "image/*": return .image
            case "video/*": return .movie
            case "audio/*": return .audio
            case "text/*": return .text
            default: return UTType(mimeType: mime)
            }
        }
        return mapped.isEmpty ? [.item] : mapped
    }

    private var photoFilter: PHPickerFilter {
        let types = contentTypes
        let images = types.contains { $0.conforms(to: .image) }
        let videos = types.contains { $0.conforms(to: .movie) }
        if images && !videos { return .images }
        if videos && !images { return .videos }
        return .any(of: [.images, .videos])
    }

    func body(content: Content) -> some View {
        content
            .background(pickers.id(token))
            .onChange(of: resultID) { id in
                if id != nil { token += 1 }
            }
    }

    /// The pickers, on a view of their own made anew for each request.
    private var pickers: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fileImporter(isPresented: presented("files"), allowedContentTypes: contentTypes,
                          allowsMultipleSelection: param("multiple") == "1") { result in
                let asked = token
                closedToken = asked
                pickingToken = asked
                let urls: [URL]
                switch result {
                case .success(let picked): urls = picked
                case .failure: urls = []
                }
                let paths = urls.compactMap { url -> String? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return IsomerPickedFiles.store(data, name: url.lastPathComponent)
                }
                answer(paths, for: asked)
            }
            .modifier(PhotoRequest(
                open: presented("photos"), filter: photoFilter,
                max: Int(param("max") ?? "").flatMap { $0 > 0 ? $0 : nil } ?? (param("multiple") == "1" ? nil : 1),
                picking: { pickingToken = token },
                answer: { paths in
                    closedToken = token
                    answer(paths, for: token)
                }))
            .modifier(QuickLookRequest(open: presented("quickLook"), path: param("path")))
            .modifier(CameraRequest(open: presented("camera"), answer: { data in
                let asked = token
                closedToken = asked
                pickingToken = asked
                answer(data.flatMap { IsomerPickedFiles.store($0, name: "photo.jpg") }.map { [$0] } ?? [], for: asked)
            }))
    }
}

/// The photo picker (iOS 16, macOS 13); before those, answered as cancelled.
private struct PhotoRequest: ViewModifier {
    let open: Binding<Bool>
    let filter: PHPickerFilter
    let max: Int?
    let picking: () -> Void
    let answer: ([String]) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            content.modifier(PhotosPickerRequest(open: open, filter: filter, max: max, picking: picking, answer: answer))
        } else {
            content.onChange(of: open.wrappedValue) { opening in
                if opening { answer([]) }
            }
        }
    }
}

/// The photo picker: the items picked, read and written for the app.
@available(iOS 16.0, macOS 13.0, *)
private struct PhotosPickerRequest: ViewModifier {
    let open: Binding<Bool>
    let filter: PHPickerFilter
    let max: Int?
    let picking: () -> Void
    let answer: ([String]) -> Void
    @State private var items: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: open, selection: $items, maxSelectionCount: max, matching: filter)
            .onChange(of: items) { picked in
                guard !picked.isEmpty else { return }
                picking()
                Task { @MainActor in
                    var paths: [String] = []
                    for (index, item) in picked.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        if let path = IsomerPickedFiles.store(data, name: "photo-\(index + 1).\(ext)") { paths.append(path) }
                    }
                    items = []
                    answer(paths)
                }
            }
    }
}

/// The system's preview of the file the app named, open while the layer asks
/// for it; closed, the request is answered.
private struct QuickLookRequest: ViewModifier {
    let open: Binding<Bool>
    let path: String?

    func body(content: Content) -> some View {
        content.quickLookPreview(Binding(
            get: {
                guard open.wrappedValue, let path, !path.isEmpty else { return nil }
                return IsomerPickedFiles.hostURL(path)
            },
            set: { if $0 == nil { open.wrappedValue = false } }))
    }
}

/// The camera, where there is one (iOS); elsewhere the request is answered
/// as cancelled.
private struct CameraRequest: ViewModifier {
    let open: Binding<Bool>
    let answer: (Data?) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: Binding(
            get: { open.wrappedValue && UIImagePickerController.isSourceTypeAvailable(.camera) },
            set: { open.wrappedValue = $0 })) {
            CameraPicker(answer: answer).ignoresSafeArea()
        }
        .onChange(of: open.wrappedValue) { opening in
            if opening, !UIImagePickerController.isSourceTypeAvailable(.camera) { answer(nil) }
        }
        #else
        content.onChange(of: open.wrappedValue) { opening in
            if opening { answer(nil) }
        }
        #endif
    }
}

#if os(iOS)
/// The system camera, giving back a JPEG (nil when cancelled).
private struct CameraPicker: UIViewControllerRepresentable {
    let answer: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(answer: answer) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let answer: (Data?) -> Void
        init(answer: @escaping (Data?) -> Void) { self.answer = answer }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            answer((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            answer(nil)
        }
    }
}
#endif
#endif
