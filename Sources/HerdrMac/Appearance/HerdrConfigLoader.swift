import Darwin
import Foundation
import HerdrCore

enum HerdrConfigLoader {
    /// Only regular local files are accepted. A FIFO/device must never block a reload.
    static func load(url: URL) async throws -> HerdrAppearanceConfig {
        try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL else { throw HerdrError.message("Choose a local TOML file") }
            // Some devices can block even with O_NONBLOCK. Reject them before open;
            // fstat below still validates the descriptor if the path changes meanwhile.
            var pathInfo = stat()
            guard stat(url.path, &pathInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (pathInfo.st_mode & S_IFMT) == S_IFREG else {
                throw HerdrError.message("Expected a regular TOML file")
            }
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw HerdrError.message("Expected a regular TOML file")
            }
            guard info.st_size <= HerdrAppearanceConfig.maximumBytes else {
                throw HerdrError.message("Configuration exceeds the 1 MiB limit")
            }
            // Read at most limit + 1 even if a file grows after fstat.
            let data = try handle.read(upToCount: HerdrAppearanceConfig.maximumBytes + 1) ?? Data()
            guard data.count <= HerdrAppearanceConfig.maximumBytes else {
                throw HerdrError.message("Configuration exceeds the 1 MiB limit")
            }
            guard let text = String(data: data, encoding: .utf8) else { throw HerdrError.message("Expected UTF-8 TOML") }
            return try HerdrAppearanceConfig.parse(text)
        }.value
    }
}
