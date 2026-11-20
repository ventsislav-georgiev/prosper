import Foundation

/// #917 S7: the tool bins of the applied kits, appended to a spawned session's PATH. Pure: no file is read and
/// nothing runs; `kitBins` is the live owner's answer (#1423 supplies it, and leaves a kit that is off out).
enum KitSessionEnv {
    /// Each bin (first-installed kit first) is appended after what PATH already holds, never before it, so no kit
    /// tool shadows a person's own. A bin that is not an absolute path, holds ":" or is already on PATH (or
    /// came earlier in the list) is skipped. No bin to add, or no PATH in the env: the env comes back unchanged.
    static func contributor(kitBins: @escaping @Sendable () -> [String]) -> SessionEnvContributor {
        { _, env in
            guard let path = env["PATH"] else { return env }
            var seen = Set(path.split(separator: ":", omittingEmptySubsequences: true).map(String.init))
            var add: [String] = []
            for bin in kitBins() where bin.hasPrefix("/") && !bin.contains(":") && seen.insert(bin).inserted { add.append(bin) }
            if add.isEmpty { return env }
            var out = env
            out["PATH"] = path.isEmpty ? add.joined(separator: ":") : ([path] + add).joined(separator: ":")
            return out
        }
    }

    /// #1684: the same PATH change as `--env PATH=<path>` for a local --revive (dch 1.94.0, applied after its login-shell
    /// env, so an rc file cannot reorder the kit bins). `env` is the control env the spawn path starts from. Nothing to
    /// add, or no PATH: no flag.
    static func reviveFlags(kitBins: [String], env: [String: String]) -> [String] {
        guard let path = contributor(kitBins: { kitBins })([], env)["PATH"], path != env["PATH"] else { return [] }
        return ["--env", "PATH=\(path)"]
    }
}
