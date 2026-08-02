import Foundation
import OslerEngine

/// User-saved templates: plain .oslerflow files in Application Support, so
/// they survive app updates and can be shared by copying the file.
enum UserTemplates {
    static let changed = Notification.Name("oslerUserTemplatesChanged")

    struct Entry: Identifiable {
        let name: String
        let url: URL
        var id: String { url.path }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Osler/Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func all() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "oslerflow" }
            .map { Entry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ graph: FlowGraph, named name: String) throws {
        var toSave = graph
        toSave.name = name
        let safe = name.replacingOccurrences(of: "/", with: "-")
        try toSave.write(to: directory.appendingPathComponent(safe + ".oslerflow"))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
