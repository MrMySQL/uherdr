import Foundation

/// Finds new herdr releases in the manifests herdr itself reads
/// (`latest.json` for stable, `preview.json` for preview) and installs
/// them with `herdr update`, which owns the download and replacement.
public enum HerdrUpdate {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static func manifestURL(channel: String) -> URL {
        URL(string: channel == "preview" ? "https://herdr.dev/preview.json" : "https://herdr.dev/latest.json")!
    }

    /// The version in `herdr --version` output, such as "herdr 0.9.3".
    public static func installedVersion(from output: String) -> String? {
        guard let token = output.split(whereSeparator: \.isWhitespace).last else { return nil }
        let version = token.hasPrefix("v") ? String(token.dropFirst()) : String(token)
        return version.first?.isNumber == true ? version : nil
    }

    public static func latestVersion(fromManifest data: Data) -> String? {
        struct Manifest: Decodable { let version: String }
        guard let version = try? JSONDecoder().decode(Manifest.self, from: data).version,
              version.first?.isNumber == true else { return nil }
        return version
    }

    /// Whether `candidate` is a later release than `current`. Dot-separated
    /// numbers compare in order; a prerelease (`-…`) sorts before its release.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> (numbers: [Int], prerelease: String?)? {
            let split = version.split(separator: "-", maxSplits: 1)
            guard let core = split.first else { return nil }
            let numbers = core.split(separator: ".").map { Int($0) }
            guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
            return (numbers.compactMap { $0 }, split.count > 1 ? String(split[1]) : nil)
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x > y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, .some): return true
        case let (.some(x), .some(y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }

    /// The installed herdr's version and the newest release on its channel.
    @MainActor public static func check(_ run: SessionControl.Runner, fetch: Fetch = download) async throws -> (installed: String, latest: String) {
        guard let installed = installedVersion(from: try await run(["--version"])) else {
            throw HerdrError.message("Couldn’t read herdr’s version.")
        }
        // Older herdr CLIs have no channels; they follow stable.
        let channel = (try? await run(["channel", "show"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "stable"
        guard let latest = latestVersion(fromManifest: try await fetch(manifestURL(channel: channel))) else {
            throw HerdrError.message("herdr’s release manifest has no version.")
        }
        return (installed, latest)
    }

    /// Replaces the herdr binary. Running servers keep their old version until restarted.
    @MainActor public static func install(_ run: SessionControl.Runner) async throws {
        _ = try await run(["update"])
    }

    @Sendable public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HerdrError.message("herdr’s release manifest is unavailable.")
        }
        return data
    }
}
