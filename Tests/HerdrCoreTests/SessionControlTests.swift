import Foundation
import HerdrCore

enum SessionControlTests {
    @MainActor static func run() async throws {
        let sessions = try SessionDiscovery.parse(SessionDiscoveryTests.listing)
        let exe = "/opt/homebrew/bin/herdr"
        func local(_ socket: String) -> DeviceProfile { DeviceProfile(name: "x", kind: .local, socketPath: socket, executable: exe) }
        // The session is found by socket, including a differently written path.
        XCTAssertEqual(SessionControl.session(for: local("/Users/alex/.config/herdr/sessions/../sessions/menqal/herdr.sock"), in: sessions)?.name, "menqal")
        XCTAssertEqual(SessionControl.session(for: local("/Users/alex/.config/herdr/herdr.sock"), in: sessions)?.name, "default")
        XCTAssertTrue(SessionControl.session(for: local("/tmp/custom.sock"), in: sessions) == nil)
        var remote = DeviceProfile(name: "mini", host: "mini.local", executable: exe)
        remote.socketPath = "/Users/alex/.config/herdr/sessions/menqal/herdr.sock"
        // SSH devices are never stopped or deleted locally.
        XCTAssertTrue(SessionControl.session(for: remote, in: sessions) == nil)

        var calls: [[String]] = []
        var failOn: String?
        let run: SessionControl.Runner = { args in
            calls.append(args)
            if let failOn, args.contains(failOn) { throw HerdrError.message("session \(failOn) failed") }
            return args.first == "session" && args.dropFirst().first == "list" ? SessionDiscoveryTests.listing : ""
        }
        XCTAssertEqual(try await SessionControl.list(run).map(\.name), sessions.map(\.name))
        calls = []
        try await SessionControl.stop("menqal", run)
        XCTAssertEqual(calls, [["session", "stop", "menqal"]])
        // A running session is stopped before it is deleted; a stopped one is only deleted.
        calls = []
        try await SessionControl.delete(sessions.first { $0.name == "menqal" }!, run)
        XCTAssertEqual(calls, [["session", "stop", "menqal"], ["session", "delete", "menqal"]])
        calls = []
        try await SessionControl.delete(sessions.first { $0.name == "test" }!, run)
        XCTAssertEqual(calls, [["session", "delete", "test"]])
        // The default session is never deleted, and a failed stop never deletes.
        calls = []
        var threw = false
        do { try await SessionControl.delete(sessions[0], run) } catch { threw = true }
        XCTAssertTrue(threw && calls.isEmpty && !SessionControl.canDelete(sessions[0]))
        calls = []; threw = false; failOn = "stop"
        do { try await SessionControl.delete(sessions.first { $0.name == "menqal" }!, run) } catch { threw = true }
        XCTAssertTrue(threw)
        XCTAssertEqual(calls, [["session", "stop", "menqal"]])
        print("PASS: session stop and delete use herdr's CLI, stop before delete, and never delete default")
    }
}
