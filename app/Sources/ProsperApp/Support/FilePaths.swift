import Foundation

/// Path helpers shared by modules that must not depend on each other (#921: the managed-config
/// resolver and the extension host's secret-path check). Pure functions, no isolation.
enum FilePaths {
    /// Resolves symlinks in the longest existing prefix of `url` and re-appends the rest.
    static func existingPrefixResolved(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.path != "/" {
            tail.insert(head.lastPathComponent, at: 0)
            head = head.deletingLastPathComponent()
        }
        var out = head.resolvingSymlinksInPath()
        for t in tail { out.appendPathComponent(t) }
        return out
    }
}
