import Foundation

/// `{{Node name}}` references — how a node reaches a value that isn't wired
/// straight into it.
///
/// Text flows along edges; a reference reaches sideways, to any node upstream
/// of this one. It's deliberately a syntax rather than a node type or a
/// variables panel: nothing new to learn, nothing new on the canvas.
///
///     Original: {{Text}}
///     Translation: {{Translate}}
///
/// Names match case-insensitively and ignore surrounding whitespace.
public enum FlowReference {
    static let opening = "{{"
    static let closing = "}}"

    /// Every name referenced in the text, in order, without duplicates removed.
    public static func names(in text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: opening) {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: closing) else { break }
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.append(name) }
            rest = afterOpen[close.upperBound...]
        }
        return names
    }

    /// Replaces every `{{name}}` with its value. A name with no value resolves
    /// to an empty string — an upstream node that was skipped genuinely
    /// produced nothing, and the prompt should read that way.
    public static func resolve(_ text: String, with values: [String: String]) -> String {
        guard text.contains(opening) else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: opening) {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: closing) else { break }
            result += rest[..<open.lowerBound]
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            result += values[key(name)] ?? ""
            rest = afterOpen[close.upperBound...]
        }
        return result + rest
    }

    /// The lookup key for a node name.
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The reference-carrying text of a node, if it has any.
    public static func referencingText(of node: Node) -> String? {
        switch node.config {
        case .agent(let config):
            return config.systemPrompt
        case .condition(.llmYesNo(let question, _, _)):
            return question
        default:
            return nil
        }
    }
}
