import LibcxxProbe
import SwiftUI

@main
struct LibcxxSharedApp: App {
    var body: some Scene {
        WindowGroup {
            Text("libc++_shared.so: \(libcxx_probe(10))")
        }
    }
}
