// Text input: fields, secure fields, multi-line entry and focus.

import SwiftUI

extension StoryCatalog {
    static let textInput = StoryArea(id: "input", title: "Text Input", symbol: "character.cursor.ibeam", stories: [
        Story(
            "input.field", "TextField", apis: ["TextField(_:text:)", ".textFieldStyle(_:)", ".roundedBorder", ".onSubmit(_:)"],
            summary: "One line of text bound to a String. Return submits it."
        ) { TextFieldStory() },
        Story(
            "input.secure", "SecureField", apis: ["SecureField(_:text:)"],
            summary: "A field whose characters are hidden as they are typed: passwords and keys."
        ) { SecureFieldStory() },
        Story(
            "input.multiline", "Multi-line text", apis: ["TextField(_:text:axis:)", ".lineLimit(_:)", "TextEditor(text:)"],
            summary: "A field that grows with its text up to a number of lines, and an editor for longer text."
        ) { MultilineStory() },
        Story(
            "input.focus", "Focus", apis: ["@FocusState", ".focused(_:equals:)", ".submitLabel(_:)"],
            summary: "Which field has the keyboard, as state: read it, and move it from code."
        ) { FocusStory() },
    ])
}

// story: input.field
struct TextFieldStory: View {
    @State private var name = ""
    @State private var greeting = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { greeting = name.isEmpty ? "" : "Hello, \(name)!" }
            TextField("Plain style", text: $name)
                .textFieldStyle(.plain)
            Text(greeting.isEmpty ? "Type a name and press Return" : greeting)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: input.secure
struct SecureFieldStory: View {
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Text(password.count < 8 ? "At least 8 characters (\(password.count) so far)" : "Strong enough")
                .font(.footnote)
                .foregroundColor(password.count < 8 ? .orange : .green)
        }
    }
}
// end story

// story: input.multiline
struct MultilineStory: View {
    @State private var message = ""
    @State private var notes = "Notes run on for as many lines as they need. The editor scrolls once they fill it."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(1 ... 4)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $notes)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        }
    }
}
// end story

// story: input.focus
struct FocusStory: View {
    enum Field { case first, last }

    @State private var first = ""
    @State private var last = ""
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("First name", text: $first)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .first)
                .submitLabel(.next)
                .onSubmit { focus = .last }
            TextField("Last name", text: $last)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .last)
                .submitLabel(.done)
                .onSubmit { focus = nil }
            HStack {
                Button("Focus first") { focus = .first }
                Button("Focus last") { focus = .last }
                Button("Dismiss") { focus = nil }
            }
            .buttonStyle(.bordered)
            Text("Focused: \(focus.map { "\($0)" } ?? "none")")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story
