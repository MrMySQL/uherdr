import Foundation

public enum DevicePowerStatus: Equatable, Sendable {
    case battery(percentage: Int, externallyPowered: Bool)
    case mains

    /// Only a recognized power-source report may imply that a device has no battery.
    public static func parse(_ output: String) -> Self? {
        let lines = output.components(separatedBy: .newlines)
        guard let source = lines.last(where: { $0.hasPrefix("Now drawing from '") }),
              source == "Now drawing from 'AC Power'" || source == "Now drawing from 'Battery Power'" else { return nil }
        let external = source == "Now drawing from 'AC Power'"
        guard let battery = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-InternalBattery-") }) else {
            return external ? .mains : nil
        }
        guard !battery.contains("present: false"),
              let range = battery.range(of: #"\b[0-9]+(?=%;)"#, options: .regularExpression),
              let percentage = Int(battery[range]), (0...100).contains(percentage) else { return nil }
        return .battery(percentage: percentage, externallyPowered: external)
    }

    @MainActor public static func read(_ profile: DeviceProfile, sshExecutable: String = "/usr/bin/ssh") async throws -> Self? {
        try Task.checkCancellation()
        let process: ManagedProcess
        if profile.kind == .ssh {
            process = try ManagedProcess(executable: sshExecutable, arguments: profile.sshArguments() + [
                "--", profile.host, "LC_ALL=C /usr/bin/pmset -g batt"
            ])
        } else {
            process = try ManagedProcess(executable: "/usr/bin/pmset", arguments: ["-g", "batt"])
        }
        let output = try await process.result(timeout: 12)
        try Task.checkCancellation()
        return parse(output)
    }
}
