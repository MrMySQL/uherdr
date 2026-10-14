import Foundation
import HerdrCore

enum HerdrUpdateTests {
    @MainActor static func run() async throws {
        XCTAssertEqual(HerdrUpdate.installedVersion(from: "herdr 0.9.3\n"), "0.9.3")
        XCTAssertEqual(HerdrUpdate.installedVersion(from: "herdr v1.0.0-preview.2"), "1.0.0-preview.2")
        XCTAssertTrue(HerdrUpdate.installedVersion(from: "") == nil)
        XCTAssertTrue(HerdrUpdate.installedVersion(from: "herdr unknown") == nil)
        XCTAssertEqual(HerdrUpdate.latestVersion(fromManifest: Data(#"{"version":"0.9.4","protocol":22}"#.utf8)), "0.9.4")
        XCTAssertTrue(HerdrUpdate.latestVersion(fromManifest: Data("<html>".utf8)) == nil)
        XCTAssertEqual(HerdrUpdate.manifestURL(channel: "stable").absoluteString, "https://herdr.dev/latest.json")
        XCTAssertEqual(HerdrUpdate.manifestURL(channel: "preview").absoluteString, "https://herdr.dev/preview.json")
        XCTAssertEqual(HerdrUpdate.manifestURL(channel: "something").absoluteString, "https://herdr.dev/latest.json")

        // Numeric, not lexical: 0.10 follows 0.9. Equal and older releases are not newer.
        XCTAssertTrue(HerdrUpdate.isNewer("0.9.4", than: "0.9.3"))
        XCTAssertTrue(HerdrUpdate.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(HerdrUpdate.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(!HerdrUpdate.isNewer("0.9.3", than: "0.9.3"))
        XCTAssertTrue(!HerdrUpdate.isNewer("0.9.3", than: "0.9.3.0"))
        XCTAssertTrue(!HerdrUpdate.isNewer("0.9.2", than: "0.9.3"))
        // A release follows its prereleases; prereleases compare numerically.
        XCTAssertTrue(HerdrUpdate.isNewer("1.0.0", than: "1.0.0-preview.2"))
        XCTAssertTrue(!HerdrUpdate.isNewer("1.0.0-preview.2", than: "1.0.0"))
        XCTAssertTrue(HerdrUpdate.isNewer("1.0.0-preview.10", than: "1.0.0-preview.9"))
        // SemVer's prerelease order: alpha < alpha.1 < alpha.beta < beta < beta.2 < beta.11 < rc.1,
        // and an alphanumeric identifier follows a numeric one, so alpha.2a follows alpha.10.
        let order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (older, newer) in zip(order, order.dropFirst()) {
            XCTAssertTrue(HerdrUpdate.isNewer(newer, than: older))
            XCTAssertTrue(!HerdrUpdate.isNewer(older, than: newer))
        }
        XCTAssertTrue(HerdrUpdate.isNewer("1.0.0-alpha.2a", than: "1.0.0-alpha.10"))
        XCTAssertTrue(!HerdrUpdate.isNewer("1.0.0-alpha.10", than: "1.0.0-alpha.2a"))
        XCTAssertTrue(HerdrUpdate.isNewer("1.0.0-rc.100000000000000000000", than: "1.0.0-rc.99999999999999999999"))
        // Anything unreadable, such as a server that hasn't reported yet, is never older.
        XCTAssertTrue(!HerdrUpdate.isNewer("0.9.4", than: ""))
        XCTAssertTrue(!HerdrUpdate.isNewer("next", than: "0.9.3"))

        var calls: [[String]] = []
        var channel = "preview\n"
        let run: SessionControl.Runner = { args in
            calls.append(args)
            if args == ["channel", "show"] { if channel.isEmpty { throw HerdrError.message("unknown command") }; return channel }
            return args == ["--version"] ? "herdr 0.9.3\n" : ""
        }
        let fetched = LockedURLs()
        let fetch: HerdrUpdate.Fetch = { url in fetched.append(url); return Data(#"{"version":"0.9.5-preview.1"}"#.utf8) }
        let found = try await HerdrUpdate.check(run, fetch: fetch)
        XCTAssertEqual(found.installed, "0.9.3")
        XCTAssertEqual(found.latest, "0.9.5-preview.1")
        XCTAssertEqual(fetched.urls.map(\.absoluteString), ["https://herdr.dev/preview.json"])
        // A CLI without channels follows stable.
        channel = ""
        _ = try await HerdrUpdate.check(run, fetch: fetch)
        XCTAssertEqual(fetched.urls.last?.absoluteString, "https://herdr.dev/latest.json")
        calls = []
        try await HerdrUpdate.install(run)
        XCTAssertEqual(calls, [["update"]])
        print("PASS: herdr update versions, manifests and install")
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func append(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
}
