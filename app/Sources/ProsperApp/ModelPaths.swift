import Foundation

/// Canonical on-disk location for the local AI model cache.
///
/// All HuggingFace Hub downloads (weights + tokenizer/config snapshots) are
/// redirected to `~/.config/prosper/hf` by setting `HF_HOME` and
/// `HF_HUB_CACHE` **before** any model load.  `swift-huggingface` (`HubCache`)
/// honours these env vars with highest priority, so no code changes to the
/// load path are required.
///
/// On first launch after an upgrade a one-time migration moves any files
/// already present in the old `~/Documents/huggingface` location into the new
/// directory so the user's downloaded model is not re-fetched.
enum ModelPaths {

    /// `~/.config/prosper/hf` — HF_HOME root.
    static var baseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/prosper/hf")
    }

    /// `~/.config/prosper/hf/hub` — HF_HUB_CACHE root; snapshots live here.
    static var hubURL: URL {
        baseURL.appending(path: "hub")
    }

    /// Creates the cache directories, exports the env vars, and performs a
    /// one-time migration of any existing `~/Documents/huggingface` contents.
    /// All filesystem operations are best-effort (`try?`).
    static func bootstrap() {
        let fm = FileManager.default

        // 1. Ensure directories exist.
        try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: hubURL, withIntermediateDirectories: true)

        // 2. Point swift-huggingface's HubCache at the new location.
        setenv("HF_HOME", baseURL.path, 1)
        setenv("HF_HUB_CACHE", hubURL.path, 1)

        // 3. One-time migration from ~/Documents/huggingface.
        guard !Preferences.modelDirMigrated else { return }

        let oldDocsHF = fm.urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appending(component: "huggingface")

        if fm.fileExists(atPath: oldDocsHF.path) {
            // baseURL already exists, so move each child individually.
            let children = (try? fm.contentsOfDirectory(
                at: oldDocsHF,
                includingPropertiesForKeys: nil
            )) ?? []
            for child in children {
                let dest = baseURL.appending(component: child.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: child, to: dest)
                }
            }
        }

        Preferences.modelDirMigrated = true
    }
}
