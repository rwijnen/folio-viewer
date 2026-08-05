import SwiftUI

/// ⌘F bar: incremental search across both panels of the open file.
struct FindBar: View {

    @Environment(AppState.self) private var appState
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Find in this document", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit { appState.advanceMatch(by: 1) }
                .frame(minWidth: 120, maxWidth: 320)

            Text(countLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)

            Button {
                appState.advanceMatch(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!hasMatches)
            .help("Previous match (⇧⌘G)")

            Button {
                appState.advanceMatch(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!hasMatches)
            .help("Next match (⌘G)")

            Toggle(isOn: $state.searchCaseSensitive) {
                Text("Aa").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .help("Match case")

            Spacer(minLength: 0)

            Button {
                appState.searchQuery = ""
                appState.isFindPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close (esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { isFocused = true }
        .onChange(of: appState.searchQuery) { appState.recomputeMatches() }
        .onChange(of: appState.searchCaseSensitive) { appState.recomputeMatches() }
        .onExitCommand { appState.isFindPresented = false }
    }

    /// The rendered page counts its own matches in JavaScript; source views count rows.
    private var hasMatches: Bool {
        appState.searchesRenderedPage ? appState.renderedMatchCount > 0 : !appState.matches.isEmpty
    }

    private var countLabel: String {
        if appState.searchQuery.isEmpty { return "" }
        if appState.searchesRenderedPage {
            guard appState.renderedMatchCount > 0 else { return "no results" }
            return "\(max(appState.renderedMatchIndex, 0) + 1) of \(appState.renderedMatchCount)"
        }
        if appState.matches.isEmpty { return "no results" }
        return "\(appState.currentMatchIndex + 1) of \(appState.matches.count)"
    }
}
