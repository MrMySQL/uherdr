import Foundation
import HerdrCore

struct DevicePowerTests {
    @MainActor static func run() async throws {
        let battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t42%; discharging; 4:00 remaining present: true\n"
        XCTAssertEqual(DevicePowerStatus.parse(battery), .battery(percentage: 42, externallyPowered: false))
        XCTAssertEqual(DevicePowerStatus.parse(battery.replacingOccurrences(of: "Battery Power", with: "AC Power")), .battery(percentage: 42, externallyPowered: true))
        for percent in [0, 100] {
            XCTAssertEqual(DevicePowerStatus.parse(battery.replacingOccurrences(of: "42%", with: "\(percent)%")), .battery(percentage: percent, externallyPowered: false))
        }
        XCTAssertEqual(DevicePowerStatus.parse("Now drawing from 'AC Power'\n"), .mains)
        for invalid in ["", "permission denied", "Now drawing from 'Battery Power'\n", battery.replacingOccurrences(of: "42%", with: "101%"), battery.replacingOccurrences(of: "42%", with: "unknown"), battery.replacingOccurrences(of: "present: true", with: "present: false")] {
            XCTAssertEqual(DevicePowerStatus.parse(invalid), nil)
        }
        let profile = DeviceProfile(name: "Power fixture", host: "power.test", user: "tester", port: "2222", executable: "/bin/herdr")
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-power-fixture.sh"
        let result = try await DevicePowerStatus.read(profile, sshExecutable: fixture)
        XCTAssertEqual(result, .battery(percentage: 73, externallyPowered: true))
        print("PASS: battery percentages, external power, desktops, invalid readings, and remote power query")
    }
}
