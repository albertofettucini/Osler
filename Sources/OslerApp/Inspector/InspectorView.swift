import SwiftUI
import OslerEngine

/// The right-hand panel: edits the selected node's configuration. When nothing
/// is selected it shows the flow at a glance.
struct InspectorView: View {
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var run: RunController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(editor.selectedNode == nil ? "Flow Overview" : "Node Settings")
                        .font(.oslerHeadline(17))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if editor.selection != nil {
                        Button { editor.selection = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowStyle())
                        .help("Deselect")
                    }
                }
                if let node = editor.selectedNode {
                    // .id ties view identity (draft text, focus, onChange
                    // baselines) to the node — switching selection can never
                    // leak one node's editor state into another.
                    Group {
                        IdentityHeader(node: node)
                        editors(for: node)
                        outputSection(node)
                    }
                    .id(node.id)
                } else {
                    emptyState
                }
            }
            .padding(18)
        }
        .background(Theme.panel)
        .background(.ultraThinMaterial)
    }

    // MARK: Per-kind editors

    @ViewBuilder
    private func editors(for node: Node) -> some View {
        switch node.config {
        case .input:
            inputEditor(node)
        case .agent:
            agentEditor(node)
        case .condition:
            ConditionEditorView(node: node)
        case .output:
            Text("This node displays the final text of the branch that reaches it.")
                .font(.oslerBody(12))
                .foregroundStyle(Theme.textFaint)
        case .unknown(let rawType, _):
            Label("Unsupported node type “\(rawType)”. It was saved by a newer version and is preserved, but can't be edited or run here.",
                  systemImage: "exclamationmark.triangle")
                .font(.oslerBody(12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func inputEditor(_ node: Node) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorLabel("Starting text")
            inspectorMultiline(Binding(
                get: { if case .input(let text) = node.config { return text }; return "" },
                set: { newValue in editor.updateNode(node.id) { $0.config = .input(text: newValue) } }
            ), minHeight: 140)
        }
    }

    private func agentEditor(_ node: Node) -> some View {
        let config = Binding<AgentConfig>(
            get: { if case .agent(let c) = node.config { return c }; return AgentConfig() },
            set: { newValue in editor.updateNode(node.id) { $0.config = .agent(newValue) } }
        )
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                inspectorLabel("Provider")
                Picker("", selection: config.provider) {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        HStack {
                            Text(provider.displayName)
                            if provider == .ollama {
                                Text("· local").foregroundStyle(Theme.textFaint)
                            } else if !settings.hasKey(for: provider) {
                                Text("· no key").foregroundStyle(Theme.textFaint)
                            }
                        }.tag(provider)
                    }
                }
                .labelsHidden()
                .onChange(of: config.wrappedValue.provider) { old, new in
                    // Swap in the new provider's default model — but only when
                    // the model was still the old provider's default, so a
                    // custom model the user typed is never overwritten.
                    let model = config.wrappedValue.model
                    if model.isEmpty || model == AgentConfig.defaultModel(for: old) {
                        config.wrappedValue.model = AgentConfig.defaultModel(for: new)
                    }
                }
            }
            inspectorField("Model", text: config.model)
            VStack(alignment: .leading, spacing: 6) {
                inspectorLabel("System prompt")
                inspectorMultiline(config.systemPrompt, minHeight: 120)
                referenceHint
            }
            if !settings.mcpServers.isEmpty {
                toolsControl(config)
            }
            temperatureControl(config)
            HStack {
                inspectorLabel("Max tokens")
                Spacer()
                TextField("", value: config.maxTokens, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
            }
        }
    }

    /// Names the upstream nodes this one can pull values from, so the syntax
    /// is discoverable without a manual.
    @ViewBuilder private var referenceHint: some View {
        let upstream = editor.upstreamNames(of: editor.selection)
        if upstream.isEmpty {
            Text("Write {{Node name}} to drop another node's output in here.")
                .font(.oslerBody(10))
                .foregroundStyle(Theme.textFaint)
        } else {
            Text("Available here: " + upstream.map { "{{\($0)}}" }.joined(separator: "  "))
                .font(.oslerLabel(9.5))
                .foregroundStyle(Theme.textFaint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which configured MCP servers this agent may use tools from.
    private func toolsControl(_ config: Binding<AgentConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorLabel("MCP tools")
            ForEach(settings.mcpServers) { server in
                Toggle(isOn: Binding(
                    get: { config.wrappedValue.toolServerIDs.contains(server.id) },
                    set: { enabled in
                        var ids = config.wrappedValue.toolServerIDs
                        if enabled {
                            if !ids.contains(server.id) { ids.append(server.id) }
                        } else {
                            ids.removeAll { $0 == server.id }
                        }
                        config.wrappedValue.toolServerIDs = ids
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.oslerBody(12))
                            .foregroundStyle(Theme.textSecondary)
                        if !server.enabled {
                            Text("· off in Settings")
                                .font(.oslerBody(10))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
            }
            Text("Tool-enabled agents answer turn by turn instead of streaming live.")
                .font(.oslerBody(10))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func temperatureControl(_ config: Binding<AgentConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { config.wrappedValue.temperature != nil },
                set: { on in config.wrappedValue.temperature = on ? 0.7 : nil }
            )) {
                Text("Set temperature").font(.oslerBody(12)).foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.switch).controlSize(.small)
            if let temp = config.wrappedValue.temperature {
                HStack {
                    Slider(value: Binding(
                        get: { temp },
                        set: { config.wrappedValue.temperature = $0 }
                    ), in: 0...1)
                    Text(String(format: "%.2f", temp))
                        .font(.oslerLabel(11))
                        .foregroundStyle(Theme.textSecondary).frame(width: 34)
                }
                Text("Newer Anthropic models reject a custom temperature — leave this off for them.")
                    .font(.oslerBody(10)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    // MARK: Output (full text + copy)

    @ViewBuilder private func outputSection(_ node: Node) -> some View {
        if let output = run.outputs[node.id], !output.isEmpty {
            let failed = run.state(for: node.id) == .failed
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(Theme.surfaceVariant)
                HStack {
                    Text(failed ? "ERROR" : "OUTPUT")
                        .font(.oslerLabel(10, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(failed ? Theme.error : Theme.textFaint)
                    if run.streaming.contains(node.id) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    .help("Copy the full output")
                }
                ScrollView {
                    Text(output)
                        .font(.oslerBody(11.5))
                        .foregroundStyle(failed ? Theme.error : Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceLowest))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outlineVariant.opacity(0.4)))
            }
        }
    }

    // MARK: Run history

    @ViewBuilder private var historySection: some View {
        if !run.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(Theme.surfaceVariant)
                Text("RUN HISTORY")
                    .font(.oslerLabel(10, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Theme.textFaint)
                ForEach(run.history) { record in
                    HistoryRow(record: record)
                }
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.graph.name)
                .font(.oslerHeadline(16))
                .foregroundStyle(Theme.textPrimary)
            statRow("Nodes", "\(editor.graph.nodes.count)")
            statRow("Connections", "\(editor.graph.edges.count)")
            Divider().overlay(Theme.surfaceVariant)
            if editor.validationIssues.isEmpty {
                Label("Ready to run", systemImage: "checkmark.seal.fill")
                    .font(.oslerBody(12)).foregroundStyle(Theme.stateColor(.done))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(editor.validationIssues.prefix(6).enumerated()), id: \.offset) { _, issue in
                        Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                            .font(.oslerBody(11)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            historySection
            Spacer(minLength: 20)
            Text("Select a node to edit it — shift-click or shift-drag a box to select several. Drag from either port onto another node to connect; click a wire or port dot to cut it. Double-click a node — or right-click it — to remove it. ⌘Z undoes anything.")
                .font(.oslerBody(11)).foregroundStyle(Theme.textFaint)
        }
    }

    private func statRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.oslerBody(12)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.oslerLabel(11)).foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Identity header (icon, rename field, type chip, delete)

/// Renames live while typing, but tolerates an empty field mid-edit — the
/// default-name substitution only happens when editing ends, so clearing the
/// field to retype doesn't snap back to "Agent".
private struct IdentityHeader: View {
    let node: Node
    @EnvironmentObject var editor: FlowEditor

    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.nodeTint(node.kind).opacity(0.10))
                .frame(width: 46, height: 46)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.nodeTint(node.kind).opacity(0.2)))
                .overlay(Image(systemName: Theme.nodeGlyph(node.kind))
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.nodeTint(node.kind)))
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.oslerBody(14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { commit() }
                Text(node.kind.rawValue.capitalized)
                    .font(.oslerLabel(10))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceContainer))
            }
            Spacer()
            Button(role: .destructive) { editor.delete(node.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())
            .help("Delete node")
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.surfaceVariant)
        }
        .onAppear { draftName = node.name }
        .onChange(of: draftName) { _, newValue in
            // Live rename while non-empty; an empty draft stays local.
            if !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                editor.rename(node.id, to: newValue)
            }
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commit() }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        // Switching selection tears this view down and used to fire a rename
        // even when nothing was typed — one dirty document and two wasted
        // undo steps for the crime of clicking a different node.
        let resolved = draftName.isEmpty ? Node.defaultName(for: node.kind) : draftName
        guard resolved != node.name else { return }
        editor.rename(node.id, to: draftName)
        // Reflect the substitution (empty → default name) back into the field.
        if let current = editor.node(node.id)?.name {
            draftName = current
        }
    }
}

// MARK: - Condition editor

/// Remembers the LLM branch's provider/model while the user flips between rule
/// kinds, so toggling to "Contains keyword" and back doesn't reset a chosen
/// model. (@State scoped per node via the parent's .id(node.id).)
private struct ConditionEditorView: View {
    let node: Node
    @EnvironmentObject var editor: FlowEditor

    @State private var lastProvider: ProviderID = .anthropic
    @State private var lastModel = AgentConfig.defaultAnthropicModel

    private var rule: Binding<ConditionRule> {
        Binding(
            get: { if case .condition(let r) = node.config { return r }; return .containsKeyword("") },
            set: { newValue in editor.updateNode(node.id) { $0.config = .condition(newValue) } }
        )
    }

    var body: some View {
        let isKeyword: Bool = { if case .containsKeyword = rule.wrappedValue { return true }; return false }()
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                inspectorLabel("Rule")
                Picker("", selection: Binding(
                    get: { isKeyword ? 0 : 1 },
                    set: { newValue in
                        // Carry the text and the remembered LLM settings across
                        // so an (accidental) toggle never destroys config.
                        let carried: String
                        switch rule.wrappedValue {
                        case .containsKeyword(let keyword): carried = keyword
                        case .llmYesNo(let question, _, _): carried = question
                        }
                        rule.wrappedValue = newValue == 0
                            ? .containsKeyword(carried)
                            : .llmYesNo(question: carried, provider: lastProvider, model: lastModel)
                    }
                )) {
                    Text("Contains keyword").tag(0)
                    Text("Ask an LLM (yes/no)").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            switch rule.wrappedValue {
            case .containsKeyword(let keyword):
                inspectorField("Keyword", text: Binding(
                    get: { keyword },
                    set: { rule.wrappedValue = .containsKeyword($0) }
                ))
                Text("Routes to YES when the incoming text contains this word (case-insensitive), otherwise NO.")
                    .font(.oslerBody(11)).foregroundStyle(Theme.textFaint)
            case .llmYesNo(let question, let provider, let model):
                VStack(alignment: .leading, spacing: 6) {
                    inspectorLabel("Question")
                    inspectorMultiline(Binding(
                        get: { question },
                        set: { rule.wrappedValue = .llmYesNo(question: $0, provider: provider, model: model) }
                    ), minHeight: 80)
                }
                VStack(alignment: .leading, spacing: 6) {
                    inspectorLabel("Provider")
                    Picker("", selection: Binding(
                        get: { provider },
                        set: { newProvider in
                            // Same default-model swap the agent editor does.
                            var newModel = model
                            if newModel.isEmpty || newModel == AgentConfig.defaultModel(for: provider) {
                                newModel = AgentConfig.defaultModel(for: newProvider)
                            }
                            rule.wrappedValue = .llmYesNo(question: question, provider: newProvider, model: newModel)
                        }
                    )) {
                        ForEach(ProviderID.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden()
                }
                inspectorField("Model", text: Binding(
                    get: { model },
                    set: { rule.wrappedValue = .llmYesNo(question: question, provider: provider, model: $0) }
                ))
                Text("Asks the model to answer YES or NO about the incoming text, then routes accordingly.")
                    .font(.oslerBody(11)).foregroundStyle(Theme.textFaint)
                let upstream = editor.upstreamNames(of: node.id)
                if !upstream.isEmpty {
                    Text("Available here: " + upstream.map { "{{\($0)}}" }.joined(separator: "  "))
                        .font(.oslerLabel(9.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { rememberLLMSettings() }
        .onChange(of: node.config) { _, _ in rememberLLMSettings() }
    }

    private func rememberLLMSettings() {
        if case .condition(.llmYesNo(_, let provider, let model)) = node.config {
            lastProvider = provider
            lastModel = model
        }
    }
}

// MARK: - Shared field styles

fileprivate func inspectorLabel(_ text: String) -> some View {
    Text(text).font(.oslerLabel(10)).foregroundStyle(Theme.textSecondary)
}

fileprivate func inspectorField(_ name: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        inspectorLabel(name)
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.oslerBody(12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceLowest))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outlineVariant.opacity(0.6)))
    }
}

fileprivate func inspectorMultiline(_ text: Binding<String>, minHeight: CGFloat) -> some View {
    TextEditor(text: text)
        .font(.oslerBody(12))
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceLowest))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outlineVariant.opacity(0.6)))
}

// MARK: - Run history row

/// One past run: header line with time/status, expandable per-node outputs.
private struct HistoryRow: View {
    let record: RunRecord

    @State private var expanded = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: record.hadFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(record.hadFailure ? Theme.error : Theme.stateColor(.done))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.relative.localizedString(for: record.date, relativeTo: Date()))
                            .font(.oslerBody(11.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(record.results.count) output\(record.results.count == 1 ? "" : "s") · \(String(format: "%.1fs", record.duration))")
                            .font(.oslerLabel(9.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.results) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(line.name)
                                    .font(.oslerLabel(10, weight: .semibold))
                                    .foregroundStyle(line.failed ? Theme.error : Theme.textSecondary)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(line.output, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textFaint)
                                        .frame(width: 20, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(HoverRowStyle())
                                .help("Copy this output")
                            }
                            Text(line.output)
                                .font(.oslerBody(10.5))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceLowest))
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}
