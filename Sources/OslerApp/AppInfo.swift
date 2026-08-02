import AppKit

/// The app's identity, read from the bundle so there is ONE source of truth:
/// scripts/package-app.sh writes the version into Info.plist, and everything
/// on screen reads it back from here. `swift run` has no bundle, hence the
/// development fallback.
enum AppInfo {
    static let name = "Osler"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var displayVersion: String { "\(name) \(version)" }

    static let tagline = "Design AI agent workflows on your Mac."
    static let credo = "Local-first · Bring your own key · MIT"

    /// The standard macOS about panel, with our own credits.
    static func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: tagline + "\n" + credo,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style,
                             range: NSRange(location: 0, length: credits.length))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: version,
            .credits: credits,
        ])
    }
}
