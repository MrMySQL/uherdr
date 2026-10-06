import Foundation
import HerdrCore

enum StreamingProcessTests {
    static func run() async throws {
        let echo = try await StreamingProcess.run(executable: "/bin/echo", arguments: ["hello"])
        XCTAssertEqual(echo, StreamingProcess.Result(stdout: Data("hello\n".utf8), status: 0, stderr: ""))

        // Every byte arrives, far past ManagedProcess's 16 KiB tail.
        let big = try await StreamingProcess.run(executable: "/bin/sh", arguments: ["-c", "head -c 5000000 /dev/zero"])
        XCTAssertEqual(big.stdout.count, 5_000_000)
        // NUL and invalid UTF-8 come through untouched.
        let raw = try await StreamingProcess.run(executable: "/usr/bin/printf", arguments: ["a\\000b\\377c"])
        XCTAssertEqual(raw.stdout, Data([0x61, 0x00, 0x62, 0xFF, 0x63]))
        // Input reaches stdin unchanged.
        let input = Data("line one\0two\n".utf8) + Data([0xFE])
        let cat = try await StreamingProcess.run(executable: "/bin/cat", arguments: [], input: input)
        XCTAssertEqual(cat.stdout, input)

        // A non-zero exit is an answer, not an error; stderr comes with it.
        let failed = try await StreamingProcess.run(executable: "/bin/sh", arguments: ["-c", "echo partial; echo oops >&2; exit 3"])
        XCTAssertEqual(failed, StreamingProcess.Result(stdout: Data("partial\n".utf8), status: 3, stderr: "oops\n"))

        // The size cap and the deadline stop the command.
        do {
            _ = try await StreamingProcess.run(executable: "/bin/sh", arguments: ["-c", "head -c 5000000 /dev/zero"], maxBytes: 1000)
            XCTFail("Expected the size cap")
        } catch { XCTAssertEqual(error as? StreamingProcess.Failure, .tooMuchOutput(limit: 1000)) }
        let started = Date()
        do {
            _ = try await StreamingProcess.run(executable: "/bin/sleep", arguments: ["5"], timeout: .milliseconds(200))
            XCTFail("Expected the deadline")
        } catch { XCTAssertEqual(error as? StreamingProcess.Failure, .timedOut) }
        XCTAssertTrue(Date().timeIntervalSince(started) < 2)
        do {
            _ = try await StreamingProcess.run(executable: "/no/such/tool", arguments: [])
            XCTFail("Expected a launch failure")
        } catch {
            guard case .launch? = error as? StreamingProcess.Failure else { XCTFail("Expected .launch, got \(error)"); return }
        }

        // Cancelling the reader kills the child process.
        let pidFile = NSTemporaryDirectory() + "uherdr-stream-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let reader = Task {
            for try await _ in StreamingProcess.events(executable: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile)'; exec sleep 30"]) {}
        }
        var pid: pid_t = 0
        for _ in 0..<100 where pid == 0 {
            try await Task.sleep(for: .milliseconds(20))
            pid = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        XCTAssertTrue(pid > 0 && kill(pid, 0) == 0)
        reader.cancel()
        // Check the child first: a reader that never returns must fail here, not hang.
        var gone = false
        for _ in 0..<100 where !gone {
            try await Task.sleep(for: .milliseconds(20))
            gone = kill(pid, 0) != 0
        }
        XCTAssertTrue(gone)
        _ = try? await reader.value
        print("PASS: streaming process: exact bytes past 16 KiB, stdin, exit status with stderr, size cap, deadline, launch failure, cancel kills the child")
    }
}
