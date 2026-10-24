// Documents saved where the person chooses, as SwiftUI spells it: a
// `FileDocument` and `.fileExporter`. The host asks where (the browser's
// download on the web, the system's "save to" picker on Android, SwiftUI's
// own exporter in Apple's tree view) through a request presentation, as
// `.fileImporter` asks what to open (Pickers.swift); the document's bytes
// travel with the request. A regular file's: a directory document has no
// bytes to give, and fails.

import Foundation
import UniformTypeIdentifiers

/// A document a person saves: read from a file, written as one.
@preconcurrency public protocol FileDocument: Sendable {
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    init(configuration: Self.ReadConfiguration) throws
    typealias ReadConfiguration = FileDocumentReadConfiguration
    func fileWrapper(configuration: Self.WriteConfiguration) throws -> FileWrapper
    typealias WriteConfiguration = FileDocumentWriteConfiguration
}

extension FileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}

/// What a document is read from.
public struct FileDocumentReadConfiguration {
    public let contentType: UTType
    public let file: FileWrapper
}

/// What a document is written as.
public struct FileDocumentWriteConfiguration {
    public let contentType: UTType
    public let existingFile: FileWrapper?
}

/// The document could not give a file's bytes to save.
struct ExportFailed: Error {}

extension View {
    /// Saves `document` as `contentType` where the person chooses, while
    /// `isPresented`; `onCompletion` gets where it went.
    nonisolated public func fileExporter<D: FileDocument>(
        isPresented: Binding<Bool>, document: D?, contentType: UTType, defaultFilename: String? = nil,
        onCompletion: @escaping (_ result: Result<URL, any Error>) -> Void
    ) -> some View {
        fileExporter(isPresented: isPresented, document: document, contentTypes: [contentType],
                     defaultFilename: defaultFilename, onCompletion: onCompletion, onCancellation: {})
    }

    /// Saves `document` as the first of `contentTypes` (else its first
    /// writable type) where the person chooses, while `isPresented`.
    nonisolated public func fileExporter<D: FileDocument>(
        isPresented: Binding<Bool>, document: D?, contentTypes: [UTType] = [], defaultFilename: String? = nil,
        onCompletion: @escaping (Result<URL, any Error>) -> Void, onCancellation: @escaping () -> Void = {}
    ) -> some View {
        let contentType = contentTypes.first ?? D.writableContentTypes.first ?? .data
        var params: [(String, String)] = []
        var failure: (any Error)?
        if isPresented.wrappedValue, let document {
            do {
                let wrapper = try document.fileWrapper(configuration: FileDocumentWriteConfiguration(contentType: contentType, existingFile: nil))
                guard let bytes = wrapper.regularFileContents else { throw ExportFailed() }
                // The type's extension added, as the system's exporters add it.
                var name = defaultFilename ?? wrapper.preferredFilename ?? "Untitled"
                if let ext = contentType.preferredFilenameExtension, !name.lowercased().hasSuffix("." + ext) {
                    name += "." + ext
                }
                params = [("name", name), ("type", contentType.preferredMIMEType ?? "application/octet-stream"),
                          ("data", bytes.base64EncodedString())]
            } catch {
                failure = error
            }
        }
        // A document that can't be written fails at once, as SwiftUI's does.
        let presented = Binding<Bool>(
            get: { isPresented.wrappedValue && document != nil },
            set: { isPresented.wrappedValue = $0 })
        if let failure, isPresented.wrappedValue {
            Task { @MainActor in
                isPresented.wrappedValue = false
                onCompletion(.failure(failure))
            }
        }
        return _PickerRequest(
            child: self, isPresented: failure == nil ? presented : .constant(false), kind: "export", params: params,
            onResult: { saved in
                // The host answers where it went (a path, or a URL such as
                // Android's content://), or nothing when the person cancelled.
                guard let place = saved.first else { return onCancellation() }
                if place.hasPrefix("/") {
                    onCompletion(.success(URL(fileURLWithPath: place)))
                } else if let url = URL(string: place), url.scheme != nil {
                    onCompletion(.success(url))
                } else {
                    onCompletion(.success(URL(fileURLWithPath: place)))
                }
            })
    }
}
