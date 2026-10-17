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

        // Stopping a script stops what it started, too, even a command that ignores SIGTERM.
        let grandchildFile = NSTemporaryDirectory() + "uherdr-stream-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: grandchildFile) }
        do {
            _ = try await StreamingProcess.run(executable: "/bin/sh", arguments: ["-c", "(trap '' TERM; exec sleep 30) >/dev/null & echo $! > '\(grandchildFile)'; wait"],
                                               timeout: .milliseconds(300))
            XCTFail("Expected the deadline")
        } catch { XCTAssertEqual(error as? StreamingProcess.Failure, .timedOut) }
        let grandchild = pid_t((try? String(contentsOfFile: grandchildFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        XCTAssertTrue(grandchild > 0)
        var grandchildGone = false
        for _ in 0..<100 where !grandchildGone {
            try await Task.sleep(for: .milliseconds(20))
            grandchildGone = kill(grandchild, 0) != 0
        }
        XCTAssertTrue(grandchildGone)
        // Also once the script itself has exited, leaving a job that holds its output open.
        let leftFile = NSTemporaryDirectory() + "uherdr-stream-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: leftFile) }
        do {
            _ = try await StreamingProcess.run(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $! > '\(leftFile)'; exit 0"],
                                               timeout: .milliseconds(300))
            XCTFail("Expected the deadline")
        } catch { XCTAssertEqual(error as? StreamingProcess.Failure, .timedOut) }
        let left = pid_t((try? String(contentsOfFile: leftFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        var leftGone = false
        for _ in 0..<100 where left > 0 && !leftGone {
            try await Task.sleep(for: .milliseconds(20))
            leftGone = kill(left, 0) != 0
        }
        XCTAssertTrue(left > 0 && leftGone)
        // Input then a held stdin: the script gets the input, and end-of-file
        // only when the run ends.
        let held = StreamingProcess.events(executable: "/bin/sh", arguments: ["-c", "cat; echo eof"], input: Data("hi".utf8), keepInputOpen: true)
        let heldReader = Task { () -> (Data, Bool) in
            var output = Data(), exited = false
            do {
                for try await event in held {
                    switch event {
                    case let .output(data): output.append(data)
                    case .exit: exited = true
                    }
                }
            } catch {}
            return (output, exited)
        }
        try await Task.sleep(for: .milliseconds(400))
        heldReader.cancel()
        let (heldOutput, heldExited) = await heldReader.value
        XCTAssertTrue(heldOutput == Data("hi".utf8) && !heldExited)

        // ScriptRunner's stream: ending it early stops the script, which saw stdin stay open.
        let scriptFile = NSTemporaryDirectory() + "uherdr-runner-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: scriptFile) }
        var scriptPID: pid_t = 0
        for try await event in try ScriptRunner.local.events("echo $$ > \"$1\"; echo up; cat >/dev/null; echo never", [scriptFile]) {
            if case let .output(data) = event, String(decoding: data, as: UTF8.self).contains("up") {
                scriptPID = pid_t((try? String(contentsOfFile: scriptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                break
            }
        }
        XCTAssertTrue(scriptPID > 0)
        var scriptGone = false
        for _ in 0..<100 where !scriptGone {
            try await Task.sleep(for: .milliseconds(20))
            scriptGone = kill(scriptPID, 0) != 0
        }
        XCTAssertTrue(scriptGone)
        print("PASS: streaming process: exact bytes past 16 KiB, stdin, exit status with stderr, size cap, deadline, launch failure, cancel kills the child, stopping reaches what the child started, held stdin after input, and ScriptRunner streams")
    }
}
