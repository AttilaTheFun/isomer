// The Storybook as a feature compiled against Isomer's frameworks: this
// `import SwiftUI` is Isomer's (apple/compiled), and so is the Storybook
// library's in this configuration. The same StorybookView the Storybook app
// shows with Apple's SwiftUI.

import Storybook
import SwiftUI

@main
struct StorybookIsomerFeature: App {
    var body: some Scene {
        WindowGroup("Storybook") {
            StorybookView()
        }
    }
}
