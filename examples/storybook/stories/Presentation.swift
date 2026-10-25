// Presentation: sheets, alerts, confirmation dialogs, popovers and the
// file exporter.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension StoryCatalog {
    static let presentation = StoryArea(id: "presentation", title: "Presentation", symbol: "rectangle.stack", stories: [
        Story(
            "presentation.sheet", "Sheet",
            summary: "A screen that slides up over this one, at half or full height, dismissed by itself or by a swipe."
        ) { SheetStory() },
        Story(
            "presentation.alert", "Alert",
            summary: "A message that needs an answer, in the platform's own dialog."
        ) { AlertStory() },
        Story(
            "presentation.dialog", "Confirmation dialog",
            summary: "A choice among actions, one of them destructive: an action sheet on iOS, a dialog elsewhere."
        ) { ConfirmationStory() },
        Story(
            "presentation.popover", "Popover",
            summary: "Content in a bubble beside the button that showed it; a sheet on a phone."
        ) { PopoverStory() },
        Story(
            "presentation.exporter", "File exporter",
            summary: "A document saved where the person chooses (fileExporter with a FileDocument): the system's save panel, Android's \"save to\" picker, a download on the web."
        ) { ExporterStory() },
    ])
}

// story: presentation.sheet
struct SheetStory: View {
    @State private var showing = false

    var body: some View {
        Button("Show sheet") { showing = true }
            .buttonStyle(.borderedProminent)
            .sheet(isPresented: $showing) {
                SheetContent()
                    .presentationDetents([.medium, .large])
            }
    }

    struct SheetContent: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 16) {
                Text("A sheet").font(.title2).bold()
                Text("Drag it up to full height, or down to dismiss.")
                    .foregroundColor(.secondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}
// end story

// story: presentation.alert
struct AlertStory: View {
    @State private var showing = false
    @State private var answer = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Delete draft…") { showing = true }
                .buttonStyle(.bordered)
            Text("Answer: \(answer)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .alert("Delete the draft?", isPresented: $showing) {
            Button("Delete", role: .destructive) { answer = "deleted" }
            Button("Cancel", role: .cancel) { answer = "kept" }
        } message: {
            Text("This can't be undone.")
        }
    }
}
// end story

// story: presentation.dialog
struct ConfirmationStory: View {
    @State private var showing = false
    @State private var choice = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Share photo…") { showing = true }
                .buttonStyle(.bordered)
            Text("Chose: \(choice)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .confirmationDialog("Share photo", isPresented: $showing, titleVisibility: .visible) {
            Button("Messages") { choice = "Messages" }
            Button("Mail") { choice = "Mail" }
            Button("Remove", role: .destructive) { choice = "Remove" }
        }
    }
}
// end story

// story: presentation.popover
struct PopoverStory: View {
    @State private var showing = false

    var body: some View {
        Button("Show popover") { showing = true }
            .buttonStyle(.bordered)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Popover").font(.headline)
                    Text("Tap outside to close.").foregroundColor(.secondary)
                }
                .padding()
            }
    }
}
// end story

// story: presentation.exporter
struct ExporterStory: View {
    @State private var exporting = false
    @State private var outcome = "Nothing saved yet."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Save a note") { exporting = true }
                .buttonStyle(.bordered)
            Text(outcome)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .fileExporter(isPresented: $exporting, document: NoteDocument(text: "A note from the Storybook."),
                      contentType: .plainText, defaultFilename: "Note") { result in
            switch result {
            case .success(let url): outcome = "Saved as \(url.lastPathComponent)."
            case .failure(let error): outcome = "Not saved: \(error.localizedDescription)"
            }
        }
    }
}

/// A plain-text document: what the exporter saves.
struct NoteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
// end story
