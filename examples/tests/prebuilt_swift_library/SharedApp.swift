// Route (a): the app imports the prebuilt module and links against its
// shared library, which links against Isomer's shared platform, as the
// app's own library does.
import PrebuiltGreeter
import SwiftUI

@main
struct PrebuiltSharedApp: App {
    var body: some Scene {
        WindowGroup {
            Text(Greeter(name: "Isomer").greet())
        }
    }
}
