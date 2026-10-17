import Foundation

/// One shared SSH connection per device (`ssh -M -N`), so the sidebar's many
/// short commands (listing, status, stamps, search) skip a new handshake
/// each. Commands use it through `RemoteShell(controlPath:)` and connect on
/// their own whenever it isn't up.
///
/// The master runs under a small `sh` that waits on a pipe from uHerdr and
/// stops the master when the pipe closes, so a crashed or killed app never
/// leaves the connection open.
public final class SSHMaster: @unchecked Sendable {
    public let profile: DeviceProfile
    /// A short socket path in a private folder: `$TMPDIR` plus ssh's own
    /// suffix could pass the 104-byte socket limit.
    public let controlPath: String
    private let folder: String
    private let ssh: String
    private let lock = NSLock()
    private var process: Process?
    private var keepAlive: Pipe?
    /// Set by `close()`: a start still in flight then gives up.
    private var closed = false

    public init(profile: DeviceProfile, ssh: String = "/usr/bin/ssh") {
        self.profile = profile
        self.ssh = ssh
        folder = "/tmp/uh-" + UUID().uuidString.prefix(8).lowercased()
        controlPath = folder + "/c"
    }

    deinit { stop() }

    /// Watches its stdin; when uHerdr goes away, so does the master.
    static let watchdog = #"""
    "$@" &
    m=$!
    trap 'kill "$m" 2>/dev/null' EXIT INT TERM
    while read -r _; do :; done
    kill "$m" 2>/dev/null
    """#

    public var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    /// Starts the master if it isn't running. Returns once ssh answers
    /// `-O check`, or false when it couldn't connect within the timeout.
    @discardableResult
    public func start(timeout: Duration = .seconds(10)) async -> Bool {
        if isRunning, await check() { return true }
        stop()
        guard !lock.withLock({ closed }) else { return false }
        do {
            guard Self.makePrivateFolder(folder) else { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.watchdog, "uherdr-ssh-master", ssh]
                + (try profile.sshArguments(control: .master(controlPath))) + ["-N", "--", profile.host]
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let open = lock.withLock { () -> Bool in
                guard !closed else { return false }
                self.process = process; keepAlive = pipe
                return true
            }
            guard open else {
                try? pipe.fileHandleForWriting.close()
                process.terminate()
                try? FileManager.default.removeItem(atPath: folder)
                return false
            }
        } catch {
            stop()
            return false
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, isRunning {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Not up in time: end it, so the next use starts a fresh one.
        stop()
        return false
    }

    /// Whether the master answers on its socket.
    public func check() async -> Bool {
        guard FileManager.default.fileExists(atPath: controlPath),
              let args = try? profile.sshArguments(control: .client(controlPath)) else { return false }
        let result = try? await StreamingProcess.run(executable: ssh, arguments: args + ["-O", "check", "--", profile.host],
                                                     maxBytes: 4096, timeout: .seconds(5))
        return result?.status == 0
    }

    /// Creates the socket folder, or accepts one already there only if it is a
    /// real folder (not a link) of this user that nobody else can enter: /tmp
    /// is shared, so another user could have made it first.
    public static func makePrivateFolder(_ path: String) -> Bool {
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    /// Removes socket folders a crashed or killed uHerdr left behind: only
    /// `uh-` plus eight hex digits, owned by this user, with no socket inside
    /// (a live master always has one), and older than a starting master needs
    /// to bind its socket, so another running uHerdr's new folder stays.
    /// Returns the folders removed.
    @discardableResult
    public static func removeStaleFolders(in directory: String = "/tmp", olderThan age: TimeInterval = 60) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var removed: [String] = []
        for name in names where name.count == 11 && name.hasPrefix("uh-") && name.dropFirst(3).allSatisfy(\.isHexDigit) {
            let folder = directory + "/" + name
            var info = stat()
            guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= age,
                  !fm.fileExists(atPath: folder + "/c") else { continue }
            if (try? fm.removeItem(atPath: folder)) != nil { removed.append(folder) }
        }
        return removed
    }

    /// Stops the master for good: a start in flight won't bring it back.
    public func close() {
        lock.withLock { closed = true }
        stop()
    }

    /// Ends the connection and removes its socket folder.
    public func stop() {
        let (process, pipe) = lock.withLock { () -> (Process?, Pipe?) in
            defer { self.process = nil; keepAlive = nil }
            return (self.process, keepAlive)
        }
        try? pipe?.fileHandleForWriting.close() // the watchdog stops ssh
        if let process, process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: folder)
    }
}
