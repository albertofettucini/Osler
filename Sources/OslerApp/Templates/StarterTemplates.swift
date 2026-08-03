import Foundation
import OslerEngine

/// What a template needs to know about THIS user when it's opened: which
/// provider/model to bake into agents (so templates run keyless via Ollama
/// when no key is set) and which MCP servers a tool template may wire in.
struct TemplateContext {
    var provider: ProviderID = .anthropic
    var model: String = AgentConfig.defaultAnthropicModel
    var toolServerIDs: [String] = []

    /// A pre-configured agent for this context.
    func agent(_ systemPrompt: String) -> AgentConfig {
        var config = AgentConfig(provider: provider, model: model)
        config.systemPrompt = systemPrompt
        return config
    }
}

/// A ready-made flow so a new user has recipes to run instead of an empty
/// canvas. `make` instantiates the graph for the current user context.
struct StarterTemplate: Identifiable {
    let id = UUID()
    let name: String
    let summary: String
    private let build: (TemplateContext) -> FlowGraph

    init(name: String, summary: String, build: @escaping (TemplateContext) -> FlowGraph) {
        self.name = name
        self.summary = summary
        self.build = build
    }

    func make(_ context: TemplateContext = TemplateContext()) -> FlowGraph {
        build(context)
    }
}

enum StarterTemplates {
    static let all: [StarterTemplate] = [
        summarize, router, translatePolish, writerCritic,
        brainstorm, research, emailDrafter, meetingNotes,
    ]

    /// Input → Agent → Output.
    static let summarize = StarterTemplate(
        name: "Summarize",
        summary: "One agent rewrites the input text into a short summary."
    ) { context in
        // Real sample content, not an instruction: the home screen promises
        // "press Run" works, and an instruction here would just make the model
        // reply "paste the text you'd like summarized".
        let input = Node(
            name: "Text",
            position: Point(x: 80, y: 180),
            config: .input(text: """
            The Mac arrived in 1984 with a graphical interface, a mouse, and the \
            claim that a computer could be personal. Its first years were rough: \
            expensive, underpowered, nearly cancelled. Decades on, the ideas it \
            argued for — direct manipulation, consistency between apps, software \
            that respects the person using it — are the baseline every desktop is \
            measured against.

            Replace this with your own text and press Run again.
            """)
        )
        let agent = context.agent("Summarize the user's text in a single clear sentence. Reply with the summary only.")
        let summarizer = Node(name: "Summarizer", position: Point(x: 380, y: 180), config: .agent(agent))
        let output = Node(name: "Summary", position: Point(x: 680, y: 180), config: .output)
        return FlowGraph(name: "Summarize", nodes: [input, summarizer, output], edges: [
            Edge(from: input.id, to: summarizer.id),
            Edge(from: summarizer.id, to: output.id),
        ])
    }

    /// Input → Condition (LLM yes/no) → one of two agents → Output.
    static let router = StarterTemplate(
        name: "Sentiment Router",
        summary: "A condition checks the mood, then routes to a matching reply."
    ) { context in
        let input = Node(
            name: "Message",
            position: Point(x: 60, y: 240),
            config: .input(text: "I've been waiting three days and still no reply. This is unacceptable.")
        )
        let router = Node(
            name: "Is it negative?",
            position: Point(x: 340, y: 240),
            config: .condition(.llmYesNo(
                question: "Does this message express frustration or a negative sentiment?",
                provider: context.provider,
                model: context.model
            ))
        )
        let apology = context.agent("The customer is upset. Write a short, warm, apologetic reply that acknowledges their frustration.")
        let apologyNode = Node(name: "De-escalate", position: Point(x: 640, y: 120), config: .agent(apology))

        let thanks = context.agent("The customer is content. Write a short, friendly thank-you reply.")
        let thanksNode = Node(name: "Thank", position: Point(x: 640, y: 360), config: .agent(thanks))

        let output = Node(name: "Reply", position: Point(x: 940, y: 240), config: .output)
        return FlowGraph(name: "Sentiment Router", nodes: [input, router, apologyNode, thanksNode, output], edges: [
            Edge(from: input.id, to: router.id),
            Edge(from: router.id, fromPort: .yes, to: apologyNode.id),
            Edge(from: router.id, fromPort: .no, to: thanksNode.id),
            Edge(from: apologyNode.id, to: output.id),
            Edge(from: thanksNode.id, to: output.id),
        ])
    }

    /// Input → translate → polish → Output.
    static let translatePolish = StarterTemplate(
        name: "Translate & Polish",
        summary: "Translate, then polish the translation."
    ) { context in
        let input = Node(
            name: "Text",
            position: Point(x: 60, y: 180),
            config: .input(text: "Turkish\n\nThe best interface is the one that gets out of your way.")
        )
        let translate = context.agent("""
        The first line of the input names the target language; the rest is the \
        text. Translate the text into that language. Reply with the translation only.
        """)
        let translator = Node(name: "Translate", position: Point(x: 360, y: 180), config: .agent(translate))

        let polish = context.agent("""
        You are a meticulous editor. Polish the translation: fix grammar, make \
        it sound natural, keep the meaning intact. Reply with the final text only.
        """)
        let polisher = Node(name: "Polish", position: Point(x: 660, y: 180), config: .agent(polish))

        let output = Node(name: "Result", position: Point(x: 960, y: 180), config: .output)
        return FlowGraph(name: "Translate & Polish", nodes: [input, translator, polisher, output], edges: [
            Edge(from: input.id, to: translator.id),
            Edge(from: translator.id, to: polisher.id),
            Edge(from: polisher.id, to: output.id),
        ])
    }

    /// Draft → critique → rewrite, with the rewrite reading BOTH (fan-in).
    static let writerCritic = StarterTemplate(
        name: "Writer & Critic",
        summary: "Draft, critique, rewrite — a self-improvement chain."
    ) { context in
        let input = Node(
            name: "Topic",
            position: Point(x: 40, y: 260),
            config: .input(text: "Why native Mac apps still matter in an Electron world.")
        )
        let draft = context.agent("Write a first draft of roughly 300 words on the user's topic.")
        let drafter = Node(name: "Draft", position: Point(x: 340, y: 140), config: .agent(draft))

        let critique = context.agent("""
        You are a harsh but fair critic. List the draft's weaknesses as bullet \
        points — argument, structure, clarity. Do not rewrite anything.
        """)
        let critic = Node(name: "Critic", position: Point(x: 640, y: 140), config: .agent(critique))

        let rewrite = context.agent("""
        You receive a draft and a critique of it. Rewrite the draft, fixing \
        every weakness the critique lists. Reply with the final text only.
        """)
        let rewriter = Node(name: "Rewrite", position: Point(x: 640, y: 400), config: .agent(rewrite))

        let output = Node(name: "Final", position: Point(x: 940, y: 400), config: .output)
        return FlowGraph(name: "Writer & Critic", nodes: [input, drafter, critic, rewriter, output], edges: [
            Edge(from: input.id, to: drafter.id),
            Edge(from: drafter.id, to: critic.id),
            Edge(from: drafter.id, to: rewriter.id),
            Edge(from: critic.id, to: rewriter.id),
            Edge(from: rewriter.id, to: output.id),
        ])
    }

    /// One question, three personas in parallel, one merger (fan-out/fan-in).
    static let brainstorm = StarterTemplate(
        name: "Parallel Brainstorm",
        summary: "Three personas answer at once; a fourth merges the best."
    ) { context in
        let input = Node(
            name: "Question",
            position: Point(x: 40, y: 300),
            config: .input(text: "How could a small Mac app earn its first 100 users?")
        )
        let optimist = context.agent("You are a bold optimist. Brainstorm the most ambitious opportunities as a short bullet list.")
        let optimistNode = Node(name: "Optimist", position: Point(x: 340, y: 120), config: .agent(optimist))

        let skeptic = context.agent("You are a sharp skeptic. List the biggest risks and likely failure modes as a short bullet list.")
        let skepticNode = Node(name: "Skeptic", position: Point(x: 340, y: 300), config: .agent(skeptic))

        let pragmatist = context.agent("You are a pragmatist. List the cheapest, fastest, most feasible moves as a short bullet list.")
        let pragmatistNode = Node(name: "Pragmatist", position: Point(x: 340, y: 480), config: .agent(pragmatist))

        let merge = context.agent("""
        You receive three brainstorm lists. Merge them, remove duplicates, and \
        rank the five best ideas with a one-line rationale each.
        """)
        let merger = Node(name: "Merge & Rank", position: Point(x: 640, y: 300), config: .agent(merge))

        let output = Node(name: "Shortlist", position: Point(x: 940, y: 300), config: .output)
        return FlowGraph(name: "Parallel Brainstorm",
                         nodes: [input, optimistNode, skepticNode, pragmatistNode, merger, output],
                         edges: [
            Edge(from: input.id, to: optimistNode.id),
            Edge(from: input.id, to: skepticNode.id),
            Edge(from: input.id, to: pragmatistNode.id),
            Edge(from: optimistNode.id, to: merger.id),
            Edge(from: skepticNode.id, to: merger.id),
            Edge(from: pragmatistNode.id, to: merger.id),
            Edge(from: merger.id, to: output.id),
        ])
    }

    /// Input → tool-enabled agent → Output. Wires in the user's enabled MCP
    /// servers at open time; runs tool-less if none are configured.
    static let research = StarterTemplate(
        name: "Research with Tools",
        summary: "An MCP-tooled agent gathers facts, then answers. Needs a server in Settings → MCP."
    ) { context in
        let input = Node(
            name: "Question",
            position: Point(x: 80, y: 180),
            config: .input(text: "What files are in my configured folder, and what do they seem to be about?")
        )
        var config = context.agent("""
        Use your available tools to gather facts before answering. Make several \
        tool calls if needed. Then answer with a short summary and say which \
        tool result supports each claim. If you have no tools, say so.
        """)
        config.toolServerIDs = context.toolServerIDs
        let researcher = Node(name: "Researcher", position: Point(x: 380, y: 180), config: .agent(config))
        let output = Node(name: "Answer", position: Point(x: 680, y: 180), config: .output)
        return FlowGraph(name: "Research with Tools", nodes: [input, researcher, output], edges: [
            Edge(from: input.id, to: researcher.id),
            Edge(from: researcher.id, to: output.id),
        ])
    }

    /// Rough bullets → draft → tighten → Output.
    static let emailDrafter = StarterTemplate(
        name: "Email Drafter",
        summary: "Rough bullets in, a clean polite email out."
    ) { context in
        let input = Node(
            name: "Bullets",
            position: Point(x: 60, y: 180),
            config: .input(text: "- meeting moved to thursday\n- need the report BEFORE the meeting\n- thank them for last week")
        )
        let draft = context.agent("Turn the user's rough bullet points into a clear, polite email with a subject line and a body.")
        let drafter = Node(name: "Draft Email", position: Point(x: 360, y: 180), config: .agent(draft))

        let tighten = context.agent("""
        Tighten this email: cut filler, keep the warmth, stay under 150 words. \
        Reply with the subject and body only.
        """)
        let tightener = Node(name: "Tighten", position: Point(x: 660, y: 180), config: .agent(tighten))

        let output = Node(name: "Email", position: Point(x: 960, y: 180), config: .output)
        return FlowGraph(name: "Email Drafter", nodes: [input, drafter, tightener, output], edges: [
            Edge(from: input.id, to: drafter.id),
            Edge(from: drafter.id, to: tightener.id),
            Edge(from: tightener.id, to: output.id),
        ])
    }

    /// Raw notes → structured decisions/actions → Output.
    static let meetingNotes = StarterTemplate(
        name: "Meeting Notes → Actions",
        summary: "Extract decisions and action items from raw notes."
    ) { context in
        let input = Node(
            name: "Raw Notes",
            position: Point(x: 80, y: 180),
            config: .input(text: "ali: ship friday? sara says QA needs 2 more days. decided: ship monday. sara owns QA list. ali writes release notes. open: pricing page copy")
        )
        let extract = context.agent("""
        Extract from the meeting notes, using exactly these three sections: \
        "Decisions", "Action items" (each as "- [Owner] task — deadline if \
        stated"), and "Open questions". Nothing else.
        """)
        let extractor = Node(name: "Extract", position: Point(x: 380, y: 180), config: .agent(extract))
        let output = Node(name: "Actions", position: Point(x: 680, y: 180), config: .output)
        return FlowGraph(name: "Meeting Notes → Actions", nodes: [input, extractor, output], edges: [
            Edge(from: input.id, to: extractor.id),
            Edge(from: extractor.id, to: output.id),
        ])
    }
}
