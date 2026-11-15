// Route (b): the app imports the prebuilt modules (swift_import) and links
// their static archives into its one library.
import PrebuiltGreeter
import PrebuiltGreeterView
import SwiftUI

@main
struct PrebuiltArchiveApp: App {
    var body: some Scene {
        WindowGroup {
            GreetingView(greeting: Greeter(name: "Isomer").greet())
        }
    }
}
