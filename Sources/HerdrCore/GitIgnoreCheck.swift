import Foundation

/// How uHerdr runs Git on this Mac.
public enum GitIgnoreCheck {
    /// The environment for every Git command the sidebar runs: the user's
    /// GIT_* variables (GIT_DIR, GIT_INDEX_FILE, …) could point Git at another
    /// repository, and a pager or fsmonitor must never start.
    public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // core.fsmonitor comes from config, so it is turned off as config too.
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
        env["GIT_CONFIG_VALUE_0"] = "false"
        return env
    }
}
