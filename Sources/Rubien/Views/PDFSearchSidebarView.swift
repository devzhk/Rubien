import SwiftUI
import PDFKit
import RubienCore

struct PDFSearchSidebarView: View {
    @ObservedObject var viewModel: PDFReaderViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            content
        }
        .onAppear { fieldFocused = true }
        .onChange(of: viewModel.searchFocusRequest) { _, _ in
            fieldFocused = true
        }
    }

    // MARK: Header (field + counter + nav)

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                TextField(
                    String(localized: "Search PDF", bundle: .module),
                    text: Binding(
                        get: { viewModel.searchQuery },
                        set: { newValue in
                            viewModel.runSearch(query: newValue)
                        }
                    )
                )
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { viewModel.nextMatch() }
                .onExitCommand { viewModel.clearSearch() }

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear search", bundle: .module))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                statusLabel

                Spacer()

                Button {
                    viewModel.searchCaseSensitive.toggle()
                    viewModel.runSearch(query: viewModel.searchQuery)
                } label: {
                    Text("Aa")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(viewModel.searchCaseSensitive ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .help(String(localized: "Match case", bundle: .module))

                Button {
                    viewModel.previousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.searchMatches.isEmpty)
                .help(String(localized: "Previous match", bundle: .module))

                Button {
                    viewModel.nextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.searchMatches.isEmpty)
                .help(String(localized: "Next match", bundle: .module))
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if viewModel.isSearchInProgress {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Searching…", bundle: .module))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.searchMatches.isEmpty {
            Text(viewModel.searchQuery.isEmpty
                 ? ""
                 : String(localized: "No matches", bundle: .module))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            let active = (viewModel.activeMatchIndex ?? 0) + 1
            Text("\(active) / \(viewModel.searchMatches.count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Results list

    @ViewBuilder
    private var content: some View {
        if viewModel.searchMatches.isEmpty {
            Spacer(minLength: 0)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(viewModel.searchMatches.enumerated()), id: \.element.id) { index, match in
                        Button {
                            viewModel.gotoMatch(at: index)
                        } label: {
                            row(for: match, isActive: index == viewModel.activeMatchIndex)
                        }
                        .buttonStyle(.plain)
                        .id(match.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.activeMatchIndex) { _, newValue in
                    guard let newValue,
                          newValue >= 0,
                          newValue < viewModel.searchMatches.count else { return }
                    let id = viewModel.searchMatches[newValue].id
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(for match: PDFSearchMatch, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(match.pageLabel)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isActive ? Color.white : .secondary)
                .frame(minWidth: 22, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.15))
                )

            Text(match.snippet)
                .font(.system(size: 12))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
