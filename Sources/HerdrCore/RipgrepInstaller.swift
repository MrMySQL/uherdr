import CryptoKit
import Foundation

/// "Install for uHerdr" (frame 07): copies uHerdr's own pinned ripgrep to
/// `~/.local/share/uherdr/bin/rg` on an SSH device that has none. Nothing else
/// is installed, and nothing outside that folder changes.
public enum RipgrepInstaller {
    public static let version = "15.2.0"

    /// Which bundled build fits a device.
    public enum Platform: String, Equatable, Sendable {
        case linuxX86_64 = "Linux, x86-64"
        case linuxAArch64 = "Linux, ARM64"
        case macOS = "macOS"

        /// The file in the app's `ripgrep` resources folder.
        public var resource: String {
            switch self {
            case .linuxX86_64: return "rg-linux-x86_64.gz"
            case .linuxAArch64: return "rg-linux-aarch64.gz"
            case .macOS: return "rg"
            }
        }

        /// From `uname -sm`.
        public init?(uname: String) {
            let parts = uname.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            switch (parts[0], parts[1]) {
            case ("Linux", "x86_64"), ("Linux", "amd64"): self = .linuxX86_64
            case ("Linux", "aarch64"), ("Linux", "arm64"): self = .linuxAArch64
            case ("Darwin", "arm64"), ("Darwin", "x86_64"): self = .macOS
            default: return nil
            }
        }
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        case unsupported(String)
        case notBundled
        case hashMismatch
        case noHashTool
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case let .unsupported(system): return "uHerdr has no ripgrep build for \(system)."
            case .notBundled: return "This copy of uHerdr doesn't include ripgrep builds for other devices."
            case .hashMismatch: return "The copied file didn't match uHerdr's ripgrep, so it was removed."
            case .noHashTool: return "The device has neither sha256sum nor shasum to check the copy."
            case let .failed(reason): return reason
            }
        }
    }

    public static func platform(of shell: RemoteShell) async throws -> Platform {
        let result = try await shell.run("uname -sm", [], maxBytes: 4096, timeout: .seconds(15))
        let uname = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, let platform = Platform(uname: uname) else { throw InstallError.unsupported(uname.isEmpty ? "this device" : uname) }
        return platform
    }

    /// The build's bytes, unpacked when stored gzipped.
    public static func binary(for platform: Platform, in folder: URL) throws -> Data {
        let file = folder.appendingPathComponent(platform.resource)
        guard FileManager.default.fileExists(atPath: file.path) else { throw InstallError.notBundled }
        guard file.pathExtension == "gz" else { return try Data(contentsOf: file) }
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", file.path]
        let out = Pipe()
        gunzip.standardOutput = out
        gunzip.standardError = FileHandle.nullDevice
        try gunzip.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0, !data.isEmpty else { throw InstallError.failed("Couldn't unpack uHerdr's ripgrep for that device.") }
        return data
    }

    /// Args: expected SHA-256, and optionally another folder (tests). The
    /// binary arrives on stdin. Written to a temp
    /// file beside the target, checked, made executable, then renamed into
    /// place; a failed check removes the temp file and leaves any old copy.
    static let script = #"""
    d=${2:-"$HOME/.local/share/uherdr/bin"}
    mkdir -p "$d" || exit 41
    t=$(mktemp "$d/.rg-XXXXXX") || exit 41
    trap 'rm -f "$t"' EXIT
    cat > "$t" || exit 41
    if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum "$t" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 "$t" | cut -d' ' -f1)
    else exit 43; fi
    [ "$h" = "$1" ] || exit 42
    chmod 755 "$t" || exit 41
    mv -f "$t" "$d/rg" || exit 41
    trap - EXIT
    "$d/rg" --version | head -n 1
    """#

    /// Installs and returns ripgrep's version line as the device reports it.
    public static func install(_ binary: Data, on shell: RemoteShell, folder: String? = nil) async throws -> String {
        let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let result = try await shell.run(script, [hash] + (folder.map { [$0] } ?? []), input: binary, maxBytes: 1 << 16, timeout: .seconds(120))
        switch result.status {
        case 0: return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        case 42: throw InstallError.hashMismatch
        case 43: throw InstallError.noHashTool
        default:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.failed(reason.isEmpty ? "Copying ripgrep failed (status \(result.status))." : reason)
        }
    }
}
