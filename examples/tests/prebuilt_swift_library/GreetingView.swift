// A prebuilt library's SwiftUI module (PrebuiltGreeterView): a View in its
// interface, so SwiftUI is imported `public`, and building it with library
// evolution warns "module 'SwiftUI' was not compiled with library evolution
// support" (a warning: this package doesn't turn warnings into errors). The
// warning is true: the archive is bound to the Isomer it was built against
// (docs/prebuilt_swift_libraries.md).
public import SwiftUI

public struct GreetingView: View {
    let greeting: String

    public init(greeting: String) {
        self.greeting = greeting
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(greeting)
            Text("from a prebuilt library").font(.footnote)
        }
        .padding()
    }
}
