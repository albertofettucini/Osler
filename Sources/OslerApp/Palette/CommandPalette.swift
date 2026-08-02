import SwiftUI
import OslerEngine

/// One action the palette can run.
struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: String
    let perform: () -> Void
}

/// ⌘K: a floating glass search over everything the app can do — add nodes,
/// load templates, run, toggle panels, open settings.
struct CommandPalette: View {
    let items: [PaletteItem]
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var matches: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(trimmed) || $0.keywords.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — click anywhere outside to dismiss.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textFaint)
                    TextField("Type a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.oslerBody(15))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($searchFocused)
                        .onSubmit(runHighlighted)
                    Text("esc")
                        .font(.oslerLabel(9))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceContainer))
                }
                .padding(.horizontal, 16)
                .frame(height: 48)

                Divider().overlay(Theme.hairline)

                if matches.isEmpty {
                    Text("No matching command")
                        .font(.oslerBody(12))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.vertical, 18)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                    paletteRow(item, isHighlighted: index == highlighted)
                                        .id(index)
                                        .onTapGesture { run(item) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 280)
                        .onChange(of: highlighted) { _, index in
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(index)
                            }
                        }
                    }
                }
            }
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panelRaised))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.30), radius: 28, y: 10)
            .padding(.top, 110)
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand { dismiss() }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, matches.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
    }

    private func paletteRow(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.oslerBody(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(item.subtitle)
                    .font(.oslerBody(10.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
            if isHighlighted {
                Image(systemName: "return")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.hoverFill)
            .opacity(isHighlighted ? 1 : 0))
        .contentShape(Rectangle())
    }

    private func runHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        run(matches[highlighted])
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.perform()
    }
}
