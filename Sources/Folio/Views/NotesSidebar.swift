import SwiftUI

/// Every note and change request left against the open document, and the button that
/// hands them over.
struct NotesSidebar: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.annotations.isEmpty {
                empty
            } else {
                List {
                    ForEach(sorted) { annotation in
                        AnnotationRow(annotation: annotation)
                            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Delete") { state.removeAnnotation(annotation, for: tab) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            footer
        }
    }

    /// In the order they appear in the document, which is the order they will be handed
    /// over in — so the list reads the same way the report does.
    private var sorted: [Annotation] {
        tab.annotations.sorted { ($0.startLine, $0.created) < ($1.startLine, $1.created) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 20, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Select a passage, right-click, and add a note or a change request.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                state.copyAnnotationReport(for: tab)
            } label: {
                Label("Copy for AI", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(tab.annotations.isEmpty)
            .help("Copy every note and change request, with the file and the lines, "
                  + "ready to paste")

            Spacer(minLength: 0)

            if !tab.annotations.isEmpty {
                Menu {
                    Button("Clear All") { state.removeAllAnnotations(for: tab) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// One note in the list.
///
/// Not private so it can be rendered on its own for checking — the `List` around it comes
/// out blank offscreen.
struct AnnotationRow: View {

    let annotation: Annotation

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: annotation.kind.symbol)
                .font(.system(size: 9))
                .foregroundStyle(annotation.kind == .changeRequest ? Color.orange : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.comment)
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                // The passage, so a note can be told from its neighbours without jumping
                // to it.
                Text("“\(annotation.quote)”")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("\(annotation.kind.label) · \(annotation.lineLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help("\(annotation.kind.label) on \(annotation.lineLabel)")
    }
}

/// Writing the note, with the passage it is against shown above it.
struct AnnotationSheet: View {

    @Environment(AppState.self) private var appState
    let tab: DocumentTab

    var body: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 12) {
            if let draft = appState.annotationDraft {
                Text("Add \(draft.kind.label.lowercased())")
                    .font(.system(size: 14, weight: .semibold))

                Text("“\(draft.quote)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.gutterBackground, in: RoundedRectangle(cornerRadius: 5))

                TextEditor(text: Binding(get: { appState.annotationDraft?.comment ?? "" },
                                         set: { appState.annotationDraft?.comment = $0 }))
                    .font(.system(size: 12))
                    .frame(minHeight: 90)
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.gutterBackground)
                    }

                Label(draft.kind == .changeRequest
                      ? "Say what should change. This is handed over as an instruction."
                      : "An observation. Handed over as context, not as a change.",
                      systemImage: draft.kind.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { appState.cancelAnnotationDraft() }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") { appState.commitAnnotationDraft(for: tab) }
                        .buttonStyle(.borderedProminent)
                        // ⌘↩, because Return belongs to the text field.
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(appState.annotationDraft?.comment
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
