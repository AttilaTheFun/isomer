// QuickLook's SwiftUI preview: a file shown by the system's previewer
// (pictures zoom, videos play, documents open) while the binding holds it.
// The host presents it, as it does the pickers: a request layer of kind
// "quickLook" naming the file, answered when the preview closes, which sets
// the binding back to nil.

import Foundation
import SwiftUI

@available(iOS 14.0, macOS 11.0, *)
extension View {
    nonisolated public func quickLookPreview(_ item: Binding<URL?>) -> some View {
        _PickerRequest(
            child: self,
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            kind: "quickLook",
            params: [("path", item.wrappedValue?.path ?? "")],
            onResult: { _ in })
    }

    /// The preview of `selection`, among `items` (shown one at a time here:
    /// the selected one).
    nonisolated public func quickLookPreview<Items>(_ selection: Binding<Items.Element?>, in items: Items) -> some View
    where Items: RandomAccessCollection, Items.Element == URL {
        quickLookPreview(selection)
    }
}
