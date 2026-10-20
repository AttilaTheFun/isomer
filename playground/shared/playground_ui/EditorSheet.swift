// The project's main file in a modal editor: Cancel (confirming when there
// are unsaved edits) / Save, and any extra bar items the app adds (Share on
// iOS). The editor VIEW is injected — the iOS Playground's UITextView-backed
// CodeEditor, a TextEditor elsewhere — so the sheet is the same on both.

import SwiftUI

public struct ProjectEditorSheet<Editor: View, Extra: View>: View {
    let fileName: String
    let load: () -> String
    let save: (String) -> Void
    let editor: (Binding<String>) -> Editor
    let extraItems: () -> Extra
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var confirmDiscard = false

    public init(fileName: String, load: @escaping () -> String, save: @escaping (String) -> Void,
                @ViewBuilder editor: @escaping (Binding<String>) -> Editor,
                @ViewBuilder extraItems: @escaping () -> Extra) {
        self.fileName = fileName
        self.load = load
        self.save = save
        self.editor = editor
        self.extraItems = extraItems
    }

    private var dirty: Bool { text != original }

    public var body: some View {
        NavigationStack {
            editor($text)
                .navigationTitle(fileName)
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if dirty { confirmDiscard = true } else { dismiss() }
                        }
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        extraItems()
                        Button("Save") {
                            save(text)
                            original = text
                            dismiss()
                        }
                        .disabled(!dirty)
                        .accessibilityIdentifier("save-file")
                    }
                }
                .confirmationDialog("Discard your edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(dirty)
        .onAppear {
            let current = load()
            text = current
            original = current
        }
    }
}

extension ProjectEditorSheet where Extra == EmptyView {
    public init(fileName: String, load: @escaping () -> String, save: @escaping (String) -> Void,
                @ViewBuilder editor: @escaping (Binding<String>) -> Editor) {
        self.init(fileName: fileName, load: load, save: save, editor: editor, extraItems: { EmptyView() })
    }
}

/// A failed build's diagnostics, monospaced, with a Done button.
public struct BuildDiagnosticsSheet: View {
    let diagnostics: String
    @Environment(\.dismiss) private var dismiss

    public init(diagnostics: String) { self.diagnostics = diagnostics }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(diagnostics)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Build failed")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
