import Foundation
import SwiftUI
import OslerEngine

/// Which top-level screen the main window shows.
enum AppScreen {
    case home
    case builder
}

@MainActor
final class AppState: ObservableObject {
    @Published var screen: AppScreen = .home

    // Builder sidebars — persisted so the workspace reopens the way you left it.
    @Published var showLibrary: Bool {
        didSet { UserDefaults.standard.set(showLibrary, forKey: "showLibrary") }
    }
    @Published var showInspector: Bool {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    init() {
        showLibrary = UserDefaults.standard.object(forKey: "showLibrary") as? Bool ?? true
        showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true
    }
}

/// Recently opened/saved flow files, persisted in UserDefaults. Backs the
/// start screen's "Recent Workflows" grid with real files.
enum RecentFlows {
    private static let key = "recentFlowPaths"
    private static let capacity = 9

    struct Entry: Identifiable, Sendable {
        let url: URL
        let name: String
        let modified: Date
        let nodeCount: Int?

        var id: String { url.path }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(capacity)), forKey: key)
    }

    /// Existing files only; stale paths are pruned as a side effect.
    static func entries() -> [Entry] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        var kept: [String] = []
        var entries: [Entry] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }
            kept.append(path)
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let nodeCount = (try? OslerEngine.FlowGraph(contentsOf: url))?.nodes.count
            entries.append(Entry(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                modified: modified,
                nodeCount: nodeCount
            ))
        }
        if kept.count != paths.count {
            UserDefaults.standard.set(kept, forKey: key)
        }
        return entries
    }
}
