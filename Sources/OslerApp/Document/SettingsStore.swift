import AppKit
import Foundation
import OslerEngine

/// The app-wide appearance choice, persisted across launches.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Holds the user's BYOK API keys, backed by the Keychain. Keys persist as they
/// are typed — there is no Save step to forget. Nothing here touches the
/// network or disk beyond the Keychain — no telemetry, no account.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var anthropicKey: String {
        didSet { persist(anthropicKey, for: .anthropic) }
    }
    @Published var openAIKey: String {
        didSet { persist(openAIKey, for: .openai) }
    }
    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }
    /// Canvas behavior: double-clicking a node deletes it. Off = double-click
    /// just selects, for people who fat-finger it.
    @Published var doubleClickRemoves: Bool {
        didSet { UserDefaults.standard.set(doubleClickRemoves, forKey: "doubleClickRemoves") }
    }
    /// The one wash of personality (§6): a backdrop tint rendered under the
    /// glass. Empty string = none (pure glass).
    @Published var backdropTintID: String {
        didSet { UserDefaults.standard.set(backdropTintID, forKey: "backdropTint") }
    }
    /// Optional wash over the node cards on the canvas. Empty = neutral cards.
    @Published var nodeTintID: String {
        didSet { UserDefaults.standard.set(nodeTintID, forKey: "nodeTint") }
    }
    /// Root URL of the local Ollama server (no key — it's on this Mac).
    @Published var ollamaBaseURL: String {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: "ollamaBaseURL") }
    }
    /// Configured MCP servers (v1.1: local stdio commands only).
    @Published var mcpServers: [MCPServerConfig] {
        didSet {
            guard !isLoading else { return }
            if let data = try? JSONEncoder().encode(mcpServers) {
                UserDefaults.standard.set(data, forKey: "mcpServers")
            }
        }
    }

    private var isLoading = true

    init() {
        anthropicKey = Keychain.get(account: ProviderID.anthropic.rawValue) ?? ""
        openAIKey = Keychain.get(account: ProviderID.openai.rawValue) ?? ""
        appearance = AppAppearance(
            rawValue: UserDefaults.standard.string(forKey: "appearance") ?? ""
        ) ?? .system
        doubleClickRemoves = UserDefaults.standard.object(forKey: "doubleClickRemoves") as? Bool ?? true
        backdropTintID = UserDefaults.standard.string(forKey: "backdropTint") ?? ""
        nodeTintID = UserDefaults.standard.string(forKey: "nodeTint") ?? ""
        ollamaBaseURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? OllamaProvider.defaultBaseURL
        if let data = UserDefaults.standard.data(forKey: "mcpServers"),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            mcpServers = decoded
        } else {
            mcpServers = []
        }
        isLoading = false
    }

    /// Applies the chosen appearance to the whole app; every Theme colour is a
    /// dynamic pair, so the UI flips instantly.
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func persist(_ value: String, for provider: ProviderID) {
        guard !isLoading else { return }
        Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines),
                     account: provider.rawValue)
    }

    func key(for provider: ProviderID) -> String {
        switch provider {
        case .anthropic: return anthropicKey
        case .openai: return openAIKey
        case .ollama: return "" // local — keyless by design
        }
    }

    func hasKey(for provider: ProviderID) -> Bool {
        !key(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var configuredProviders: [ProviderID] {
        ProviderID.allCases.filter { hasKey(for: $0) }
    }

    /// Providers the given flow calls (agents + LLM conditions) that have no
    /// API key yet. Used to gate every Run entry point consistently.
    func missingProviders(for graph: FlowGraph) -> [ProviderID] {
        var needed = Set<ProviderID>()
        for node in graph.nodes {
            switch node.config {
            case .agent(let config):
                needed.insert(config.provider)
            case .condition(.llmYesNo(_, let provider, _)):
                needed.insert(provider)
            default:
                break
            }
        }
        return needed
            .filter { $0.requiresKey && !hasKey(for: $0) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// How templates instantiate for THIS user: the best available provider
    /// (keyless falls back to local Ollama) plus the enabled MCP servers.
    var templateContext: TemplateContext {
        let provider: ProviderID = hasKey(for: .anthropic) ? .anthropic
            : hasKey(for: .openai) ? .openai
            : .ollama
        return TemplateContext(
            provider: provider,
            model: AgentConfig.defaultModel(for: provider),
            toolServerIDs: mcpServers.filter(\.enabled).map(\.id)
        )
    }

    /// Builds a provider registry from whatever keys are present. Ollama is
    /// always registered — it's local and keyless.
    func makeRegistry() -> ProviderRegistry {
        var registry = ProviderRegistry()
        if hasKey(for: .anthropic) {
            registry.register(AnthropicProvider(apiKey: anthropicKey), for: .anthropic)
        }
        if hasKey(for: .openai) {
            registry.register(OpenAIProvider(apiKey: openAIKey), for: .openai)
        }
        registry.register(OllamaProvider(baseURL: ollamaBaseURL), for: .ollama)
        return registry
    }
}
