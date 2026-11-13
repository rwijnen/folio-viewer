import SwiftUI

/// ⇧⌘F: every hit of the find bar's search, under the heading it falls in. Clicking one
/// goes to it in the document.
struct FindResultsPane: View {

    @Environment(AppState.self) private var state

    var body: some View {
        let results = state.findResults
        VStack(spacing: 0) {
            header
            Divider()
            if results.isEmpty {
                placeholder
            } else {
                list(FindResults.groups(results))
            }
            if state.findResultTotal > results.count, !results.isEmpty {
                Divider()
                Text("Showing the first \(results.count) of \(state.findResultTotal)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Results")
                .font(.system(size: 11, weight: .semibold))
            if state.findResultTotal > 0 {
                Text("\(state.findResultTotal)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                state.closeFindAll()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the results")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(state.searchQuery.isEmpty ? "Type in the find bar to list every match"
                                           : "No results")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ groups: [FindResultGroup]) -> some View {
        let current = state.currentFindResultID
        return ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.results) { result in
                            FindResultRow(result: result, isCurrent: result.id == current) {
                                state.focusFindResult(result.id)
                            }
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .id(result.id)
                        }
                    } header: {
                        if let title = group.title {
                            Text(title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // `anchor: nil` scrolls the least it can, so a click on a row that is already
            // showing leaves the list alone, while ⌘G keeps the current row in sight.
            .onChange(of: current) { _, id in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct FindResultRow: View {

    let result: FindResult
    let isCurrent: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snippet)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let location = result.location {
                    Text(location)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isCurrent ? Theme.foldBackground : .clear)
        }
    }

    private var snippet: AttributedString {
        var match = AttributedString(result.match)
        match.backgroundColor = isCurrent ? Theme.currentSearchMatch : Theme.searchMatch
        return AttributedString(result.before) + match + AttributedString(result.after)
    }
}
