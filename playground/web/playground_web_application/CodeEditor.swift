// The web code editor: a host view the React renderer draws as a textarea
// over a syntax-highlighted underlay (`codeeditor` in react_renderer.js) —
// the same `CodeEditor(text:fileName:)` shape as the iOS Playground's
// UITextView-backed editor, so the shared editor sheet injects either.

import Isomer
import SwiftUI

struct CodeEditor: PlatformViewRepresentable {
    let text: Binding<String>
    let fileName: String

    init(text: Binding<String>, fileName: String) {
        self.text = text
        self.fileName = fileName
    }

    var kind: String { "codeeditor" }
    var value: String { text.wrappedValue }
    var parameters: [String: String] { ["lang": fileName.hasSuffix(".swift") ? "swift" : "plain"] }
    func onValueChanged(_ value: String) { text.wrappedValue = value }
}
