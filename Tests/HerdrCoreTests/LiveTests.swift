import Foundation
import HerdrCore

enum LiveTests {
    static func run(socket: String) async throws {
        // Never infer a live target: only accept an explicit disposable test socket.
        guard socket.hasPrefix("/tmp/"), socket.contains("native-client-test") else {
            throw HerdrError.message("Live tests require an explicit /tmp/ native-client-test socket")
        }
        let client = HerdrClient(socketPath: socket)
        let initial = try await client.request("session.snapshot")
        _ = try initial["snapshot"].decode(SessionSnapshot.self)
        let created = try await client.request("workspace.create", params: ["label": .string("Native integration test"), "cwd": .string("/tmp"), "focus": .bool(false)])
        let space = try created["workspace"].decode(Workspace.self)
        do {
            let tab = try created["tab"].decode(Tab.self)
            let pane = try created["root_pane"].decode(Pane.self)
            let right = try await client.request("pane.split", params: ["target_pane_id": .string(pane.id), "direction": .string("right"), "focus": .bool(false)])
            let rightPane = try right["pane"].decode(Pane.self)
            let down = try await client.request("pane.split", params: ["target_pane_id": .string(rightPane.id), "direction": .string("down"), "focus": .bool(false)])
            let bottomPane = try down["pane"].decode(Pane.self)
            let layoutResult = try await client.request("layout.export", params: ["tab_id": .string(tab.id)])
            let layout = try layoutResult["layout"].decode(TabLayout.self)
            XCTAssertEqual(layout.root.paneIDs, [pane.id, rightPane.id, bottomPane.id])
            let resized = try await client.request("layout.set_split_ratio", params: ["tab_id": .string(tab.id), "path": .array([.bool(true)]), "ratio": .number(0.65)])
            let updated = try resized["layout"].decode(TabLayout.self)
            guard case .split(_, _, _, let second) = updated.root, case .split(let direction, let ratio, _, _) = second else { throw HerdrError.message("Wrong nested layout") }
            XCTAssertEqual(direction, .down)
            XCTAssertTrue(abs(ratio - 0.65) < 0.001)
            _ = try await client.request("pane.send_input", params: ["pane_id": .string(bottomPane.id), "text": .string("printf 'native-client-%s\\n' verified"), "keys": .array([.string("enter")])])
            var matched = false
            for _ in 0..<30 {
                let output = try await client.request("pane.read", params: ["pane_id": .string(bottomPane.id), "source": .string("recent"), "lines": .number(80)])
                if output["read"]["text"].string?.contains("native-client-verified") == true { matched = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(matched)
            _ = try await client.request("pane.report_agent", params: ["pane_id": .string(bottomPane.id), "source": .string("custom:native-client-test"), "agent": .string("native-test-agent"), "state": .string("blocked"), "message": .string("Synthetic status fixture for integration verification")])
            let agentSnapshot = try await client.request("session.snapshot")
            let agentState = try agentSnapshot["snapshot"].decode(SessionSnapshot.self)
            XCTAssertEqual(agentState.agents.first { $0.paneID == bottomPane.id }?.agentStatus, .blocked)
            _ = try await client.request("pane.rename", params: ["pane_id": .string(bottomPane.id), "label": .string("Verified terminal")])
            let anotherTab = try await client.request("tab.create", params: ["workspace_id": .string(space.id), "label": .string("Second tab"), "focus": .bool(false)])
            let secondTab = try anotherTab["tab"].decode(Tab.self)
            _ = try await client.request("tab.rename", params: ["tab_id": .string(secondTab.id), "label": .string("Renamed tab")])
            let final = try await client.request("session.snapshot")
            let snapshot = try final["snapshot"].decode(SessionSnapshot.self)
            XCTAssertEqual(snapshot.tabs.filter { $0.workspaceID == space.id }.count, 2)
            XCTAssertEqual(snapshot.panes.first { $0.id == bottomPane.id }?.label, "Verified terminal")
            XCTAssertEqual(snapshot.tabs.first { $0.id == secondTab.id }?.label, "Renamed tab")
            _ = try await client.request("tab.close", params: ["tab_id": .string(secondTab.id)])
            _ = try await client.request("pane.close", params: ["pane_id": .string(bottomPane.id)])
            let collapsed = try await client.request("layout.export", params: ["tab_id": .string(tab.id)])
            XCTAssertEqual(try collapsed["layout"].decode(TabLayout.self).root.paneIDs, [pane.id, rightPane.id])
            _ = try await client.request("workspace.close", params: ["workspace_id": .string(space.id)])
            print("PASS: live snapshot, workspace/tab lifecycle, nested splits, resize, shell input/output, agent status, rename, and collapse")
        } catch {
            _ = try? await client.request("workspace.close", params: ["workspace_id": .string(space.id)])
            throw error
        }
    }
}
