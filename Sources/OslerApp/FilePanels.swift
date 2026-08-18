import AppKit
import UniformTypeIdentifiers

/// Blocking alerts for the few moments that genuinely need one: destroying
/// unsaved work, and file errors the user must not miss.
enum Alerts {
    /// Plain informational alert (no warning icon).
    static func info(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Returns true when the user agrees to overwrite something that exists.
    static func confirmReplace(_ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace it?"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A one-field prompt; returns the trimmed text, or nil on cancel.
    static func prompt(_ title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Returns true when the user chooses to discard their unsaved changes.
    static func confirmDiscard(_ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func error(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Thin wrappers over the AppKit open/save panels so the menu and toolbar share
/// one code path. Flows are plain JSON with an `.oslerflow` extension.
enum FilePanels {
    static func open() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.oslerFlow, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.oslerFlow]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
