// New Project: a name and a template (Blank, or one of the bundled example
// apps). The template list comes from the app (the iOS bundle's samples,
// the site's assets); creating is the app's store.

import SwiftUI

public struct ProjectTemplateChoice: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var isBlank: Bool

    public init(id: String, name: String, subtitle: String, isBlank: Bool = false) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.isBlank = isBlank
    }
}

public struct NewProjectSheet: View {
    let templates: [ProjectTemplateChoice]
    let footer: String
    let onCreate: (String, ProjectTemplateChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection: String

    public init(templates: [ProjectTemplateChoice],
                footer: String = "The examples are the same apps the full example application ships; start from one and change it, or pick Blank for an empty App.",
                onCreate: @escaping (String, ProjectTemplateChoice) -> Void) {
        self.templates = templates
        self.footer = footer
        self.onCreate = onCreate
        _selection = State(initialValue: templates.first?.id ?? "")
    }

    private var template: ProjectTemplateChoice? { templates.first { $0.id == selection } }
    private var fallbackName: String { (template?.isBlank ?? true) ? "Untitled" : (template?.name ?? "Untitled") }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name, prompt: Text(fallbackName))
                        .accessibilityIdentifier("project-name")
                }
                Section {
                    ForEach(templates) { candidate in
                        Button { selection = candidate.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name).foregroundColor(.primary)
                                    Text(candidate.subtitle).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if candidate.id == selection { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                    }
                } header: {
                    Text("Template")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("New Project")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let template else { return }
                        let trimmed = String(String(name.drop(while: { $0 == " " }).reversed()).drop(while: { $0 == " " }).reversed())
                        onCreate(trimmed.isEmpty ? fallbackName : trimmed, template)
                        dismiss()
                    }
                    .accessibilityIdentifier("create-project")
                }
            }
        }
    }
}
