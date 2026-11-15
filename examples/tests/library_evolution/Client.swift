// A library of an app's own built as a library meant for distribution is:
// with library evolution, internal imports by default (Swift 6's upcoming
// InternalImportsByDefault, so what its interface uses is imported
// `public`) and `-library-level api` (BUILD.bazel). Swift then reports a
// public import of a module built without library evolution as an error,
// "module 'SwiftUI' was not compiled with library evolution support; using
// it means binary compatibility for 'ResilientClient' can't be guaranteed"
// (lib/Sema/ImportResolution.cpp; a warning otherwise, which Swift 6.4's
// -warnings-as-errors leaves a warning, and no diagnostic group names).
// Against Isomer's modules as they are by default each import below fails;
// under `--@isomer//:library_evolution` they are resilient and it builds.
// The public declarations use a type of each, as such a library's would.

public import Combine
public import CoreGraphics
public import CoreTransferable
public import Foundation
public import Isomer
public import Observation
public import PhotosUI
public import SwiftUI
public import UniformTypeIdentifiers

public struct ResilientBadge: View {
    public let title: String
    public let inset: CGFloat

    public init(title: String, inset: CGFloat = 8) {
        self.title = title
        self.inset = inset
    }

    public var body: some View {
        Text(title)
            .padding(inset)
            .background(Color.dynamic(light: .white, dark: .black))
    }
}

@Observable
public final class ResilientModel {
    public var count = 0
    public var changes = PassthroughSubject<Int, Never>()

    public init() {}

    public func increment() {
        count += 1
        changes.send(count)
    }
}

public func resilientRequest(_ url: URL) -> URLRequest {
    URLRequest(url: url)
}

public let resilientType: UTType = .plainText

public func resilientPicker(_ isPresented: Binding<Bool>, _ selection: Binding<PhotosPickerItem?>) -> some View {
    ResilientBadge(title: "Pick").photosPicker(isPresented: isPresented, selection: selection)
}

public func resilientValue(_ text: String) -> JSONValue {
    .string(text)
}

public func resilientExport<Item: Transferable>(_ item: Item) -> Item {
    item
}
