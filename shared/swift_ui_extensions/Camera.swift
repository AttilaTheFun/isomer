import SwiftUI

extension View {
    /// A photo taken with the camera, as a file (nil when cancelled). Not a
    /// SwiftUI API: SwiftUI has no camera; an Apple app pairs it with its
    /// own `UIImagePickerController` wrapper of the same shape. The host runs
    /// the camera (the system camera on Android, a capture-capable file
    /// input on the web) and puts the photo where Foundation can read it.
    nonisolated public func cameraCapture(isPresented: Binding<Bool>, onCapture: @escaping (URL?) -> Void) -> some View {
        _PickerRequest(
            child: self, isPresented: isPresented, kind: "camera",
            params: [("accept", "image/*")],
            onResult: { paths in onCapture(paths.first.map { URL(fileURLWithPath: $0) }) })
    }
}
