// Files and drops, as SwiftUI spells them: `.fileImporter` and
// `.dropDestination(for:)`. PhotosUI's `.photosPicker` and the Isomer
// module's `.cameraCapture` (SwiftUI has no camera) ask the host the same
// way. The host runs its own picker (a file input on the web; the system
// document picker, photo picker and camera on Android) and puts what was
// picked where Foundation can read it — the app's cache directory on
// Android, an in-memory file store on the web — so an app reads the bytes
// with `Data(contentsOf: url)` everywhere, and `url.lastPathComponent` is
// the file's name. Real SwiftUI is used on Apple.

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The host's picker, while `isPresented`: a request presentation.
package struct _PickerRequest<Child: View> {
    let child: Child
    let isPresented: Binding<Bool>
    let kind: String
    let params: [(String, String)]
    let onResult: ([String]) -> Void

    /// A picker of `kind` the host runs while `isPresented` (its result:
    /// the picked files' paths). PhotosUI's `.photosPicker` is one.
    package init(
        child: Child, isPresented: Binding<Bool>, kind: String,
        params: [(String, String)], onResult: @escaping ([String]) -> Void
    ) {
        self.child = child
        self.isPresented = isPresented
        self.kind = kind
        self.params = params
        self.onResult = onResult
    }

    public typealias Body = Never
}

extension _PickerRequest: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("picked")
        let childNode = buildNode(view: child, ctx: &sub)
        if isPresented.wrappedValue {
            let binding = isPresented
            let onResult = onResult
            Runtime.shared.pendingPresentations.append(PendingPresentation(
                id: ctx.path + "#" + kind,
                style: .request(kind: kind, params: params, onResult: { value in
                    binding.wrappedValue = false
                    onResult(value.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
                }),
                content: RenderNode(kind: .box),
                dismiss: { binding.wrappedValue = false }
            ))
        }
        return childNode
    }
}

/// The picker was dismissed without a choice.
struct PickerCancelled: Error {}

extension View {
    /// Files from the platform's file chooser.
    nonisolated public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
        let accept = allowedContentTypes.compactMap(\.preferredMIMEType).joined(separator: ",")
        return _PickerRequest(
            child: self, isPresented: isPresented, kind: "files",
            params: [("accept", accept), ("multiple", allowsMultipleSelection ? "1" : "0")],
            onResult: { paths in
                // A cancelled chooser completes with no files, as SwiftUI's does.
                onCompletion(.success(paths.map { URL(fileURLWithPath: $0) }))
            })
    }

    /// One file from the platform's file chooser.
    nonisolated public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let first = urls.first { onCompletion(.success(first)) } else { onCompletion(.failure(PickerCancelled())) }
            case .failure(let error):
                onCompletion(.failure(error))
            }
        }
    }

    /// Files dropped on the view (a drag from the desktop, or from another
    /// app), as their `URL`s or their bytes.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    #endif
    nonisolated public func dropDestination<T: Transferable>(
        for payloadType: T.Type = T.self,
        action: @escaping ([T], CGPoint) -> Bool,
        isTargeted: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        _ModifiedView(child: self, descend: "drop", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.dropAction = { paths in
                let urls = paths.map { URL(fileURLWithPath: $0) }
                if T.self == URL.self {
                    _ = action(urls as! [T], .zero)
                } else if T.self == Data.self {
                    _ = action(urls.compactMap { try? Data(contentsOf: $0) } as! [T], .zero)
                }
            }
            box.dropTargeted = isTargeted
            return box
        }
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _PickerRequest: View {}
