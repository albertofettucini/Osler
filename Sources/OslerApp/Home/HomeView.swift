import SwiftUI
import OslerEngine

/// The start screen, shaped like a document template chooser (Pages/Keynote):
/// what you can make is the content, not a dashboard of empty panels. Recents
/// come first when they exist; a new user sees a full shelf of runnable flows.
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var run: RunController
    @EnvironmentObject var settings: SettingsStore

    @State private var recents: [RecentFlows.Entry] = []
    @State private var userTemplates: [UserTemplates.Entry] = []

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        ZStack {
            Theme.surfaceContainer
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 30)

                    if !recents.isEmpty {
                        sectionLabel("RECENT")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                                  spacing: 10) {
                            ForEach(recents) { entry in
                                RecentCard(entry: entry) { open(entry) }
                            }
                        }
                        .padding(.bottom, 30)
                    }

                    sectionLabel("TEMPLATES")
                    LazyVGrid(columns: columns, spacing: 14) {
                        BlankCard { newFlow() }
                        ForEach(StarterTemplates.all) { template in
                            let graph = template.make(settings.templateContext)
                            TemplateCard(name: template.name,
                                         summary: template.summary,
                                         graph: graph) {
                                open(graph)
                            }
                        }
                    }

                    if !userTemplates.isEmpty {
                        sectionLabel("MY TEMPLATES")
                            .padding(.top, 30)
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(userTemplates) { entry in
                                SavedTemplateCard(entry: entry) { open(saved: entry) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 38)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserTemplates.changed)) { _ in
            userTemplates = UserTemplates.all()
        }
    }

    // MARK: Header

    private var greetingWord: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greetingWord)
                    .font(.oslerDisplay)
                    .foregroundStyle(Theme.textPrimary)
                Text(recents.isEmpty
                     ? "Pick a template and press Run — everything here is a working flow."
                     : "Pick a template, or open something you were working on.")
                    .font(.oslerBody(15))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 16)
            Button(action: newFlow) {
                Label("New", systemImage: "plus")
                    .font(.oslerBody(12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.cardFill))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .contentShape(Capsule())
            }
            .buttonStyle(HoverPillStyle())
            .help("Start a blank flow (⌘N)")
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.oslerLabel(10, weight: .semibold))
            .kerning(1)
            .foregroundStyle(Theme.textFaint)
            .padding(.bottom, 10)
    }

    // MARK: Actions

    private func reload() async {
        // File stats + tiny JSON decodes stay off the main thread.
        let entries = await Task.detached(priority: .userInitiated) {
            RecentFlows.entries()
        }.value
        recents = entries
        userTemplates = UserTemplates.all()
    }

    private func confirmDiscardIfNeeded() -> Bool {
        !editor.isDirty || Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.")
    }

    private func newFlow() {
        guard confirmDiscardIfNeeded() else { return }
        run.cancel()
        run.reset()
        editor.newFlow()
        appState.screen = .builder
    }

    private func open(_ graph: FlowGraph) {
        guard confirmDiscardIfNeeded() else { return }
        run.cancel()
        run.reset()
        editor.loadGraph(graph, url: nil)
        appState.screen = .builder
    }

    private func open(_ entry: RecentFlows.Entry) {
        guard confirmDiscardIfNeeded() else { return }
        // Only a successful load may reset the run and switch screens.
        if editor.load(entry.url) {
            run.cancel()
            run.reset()
            appState.screen = .builder
        } else {
            recents = RecentFlows.entries() // prune the stale card
        }
    }

    private func open(saved entry: UserTemplates.Entry) {
        do {
            // url: nil — saving must never overwrite the template itself.
            open(try FlowGraph(contentsOf: entry.url))
        } catch {
            Alerts.error("Couldn't open \"\(entry.name)\"", error.localizedDescription)
        }
    }
}

// MARK: - Cards

/// Quiet glass at rest, bright on hover — the "selected" look is the cursor's
/// to earn, never the default.
private struct CardChrome: ViewModifier {
    let hovering: Bool
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.cardFill)
                .opacity(hovering ? 0 : 0.5))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.cardFillHover)
                .opacity(hovering ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline))
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: Theme.textPrimary.opacity(hovering ? 0.12 : 0),
                    radius: hovering ? 11 : 0)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct TemplateCard: View {
    let name: String
    let summary: String
    let graph: FlowGraph
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                FlowThumbnail(graph: graph)
                    .frame(height: 46)
                    .padding(.bottom, 12)
                Text(name)
                    .font(.oslerBody(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(summary)
                    .font(.oslerBody(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .frame(minHeight: 128, alignment: .top)
            .modifier(CardChrome(hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.75)) { hovering = inside }
        }
    }
}

private struct BlankCard: View {
    let create: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: create) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Blank")
                    .font(.oslerBody(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Start from scratch")
                    .font(.oslerBody(10.5))
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .frame(minHeight: 128)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.hoverFill)
                .opacity(hovering ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.outlineVariant,
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.75)) { hovering = inside }
        }
    }
}

private struct SavedTemplateCard: View {
    let entry: UserTemplates.Entry
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text(entry.name)
                    .font(.oslerBody(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .frame(minHeight: 92, alignment: .top)
            .modifier(CardChrome(hovering: hovering, cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { UserTemplates.delete(entry) } label: {
                Label("Delete Template", systemImage: "trash")
            }
        }
        .onHover { inside in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.75)) { hovering = inside }
        }
    }
}

private struct RecentCard: View {
    let entry: RecentFlows.Entry
    let open: () -> Void

    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceContainerHigh)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.oslerBody(12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.oslerLabel(9.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .modifier(CardChrome(hovering: hovering, cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.75)) { hovering = inside }
        }
    }

    private var subtitle: String {
        let when = Self.relative.localizedString(for: entry.modified, relativeTo: Date())
        guard let count = entry.nodeCount else { return when }
        return "\(when) · \(count) node\(count == 1 ? "" : "s")"
    }
}
