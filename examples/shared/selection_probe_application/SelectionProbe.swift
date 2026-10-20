// A text field's selection between the app and its host
// (`TextField(_:text:selection:)`): the field reports where its caret is,
// and a selection the app sets (a completion's insertion point after what
// it inserted, a range) shows in it. The probe's text says what the app
// sees; tools drive it on the web (headless Chrome) and on Android (the
// emulator) and read both sides. Below it, Return in the other fields: a
// field of one line submits (and takes no newline), a TextEditor takes
// newlines, and Shift-Return in the vertical field is a newline too.

import SwiftUI

@main
struct SelectionProbeApp: App {
    var body: some Scene {
        WindowGroup { SelectionProbe() }
    }
}

struct SelectionProbe: View {
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var title = ""
    @State private var submitted = 0
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Message", text: $text, selection: $selection, axis: .vertical)
                .padding(8)
                .background(Color.gray.opacity(0.15))
            Text("text=\(text)")
            Text("selection=\(offsets)")
            // A slash command completed: the command, a space, the
            // insertion point after them.
            Button("Complete") {
                text = "/goal "
                selection = TextSelection(insertionPoint: text.endIndex)
            }
            // A range: the second and third characters.
            Button("Select") {
                guard text.count >= 3 else { return }
                let start = text.index(after: text.startIndex)
                selection = TextSelection(range: start ..< text.index(start, offsetBy: 2))
            }
            TextField("Title", text: $title)
                .onSubmit { submitted += 1 }
                .padding(8)
                .background(Color.gray.opacity(0.15))
            Text("title=\(title) submitted=\(submitted)")
            TextEditor(text: $notes)
                .frame(height: 96)
                .background(Color.gray.opacity(0.15))
            Text("notes=\(notes.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "|"))")
            Spacer()
        }
        .padding()
    }

    /// The selection as UTF-16 offsets ("none" when there is none).
    private var offsets: String {
        guard let selection, case .selection(let range) = selection.indices else { return "none" }
        return "\(range.lowerBound.utf16Offset(in: text)),\(range.upperBound.utf16Offset(in: text))"
    }
}
