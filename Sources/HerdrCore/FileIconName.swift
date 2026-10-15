import Foundation

/// Which bundled Material icon (Resources/FileIcons/<name>.svg) a tree row shows.
public enum FileIconName {
    public static func name(for fileName: String, isDirectory: Bool) -> String {
        let lower = fileName.lowercased()
        if isDirectory { return folders[lower] ?? "folder" }
        if let exact = files[lower] { return exact }
        if lower.hasPrefix("readme") { return "readme" }
        if lower.hasPrefix(".env") { return "tune" }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return "docker" }
        let ext = (lower as NSString).pathExtension
        return extensions[ext] ?? "document"
    }

    static let folders: [String: String] = [
        "src": "folder-src", "source": "folder-src", "sources": "folder-src",
        "test": "folder-test", "tests": "folder-test", "__tests__": "folder-test", "spec": "folder-test",
        "doc": "folder-docs", "docs": "folder-docs",
        "script": "folder-scripts", "scripts": "folder-scripts", "bin": "folder-scripts",
        "lib": "folder-lib", "libs": "folder-lib", "vendor": "folder-lib",
        "app": "folder-app", "components": "folder-components", "public": "folder-public",
        "config": "folder-config", "configs": "folder-config", ".config": "folder-config",
        "images": "folder-images", "img": "folder-images", "assets": "folder-images",
        "node_modules": "folder-node", "dist": "folder-dist", "build": "folder-dist", ".build": "folder-dist", "out": "folder-dist",
        ".github": "folder-github", ".vscode": "folder-vscode", "resources": "folder-resource", ".git": "folder-git",
    ]

    static let files: [String: String] = [
        "package.json": "nodejs", "package-lock.json": "nodejs", ".gitignore": "git", ".gitattributes": "git",
        ".gitmodules": "git", "license": "certificate", "license.md": "certificate", "license.txt": "certificate",
        "makefile": "makefile", "package.resolved": "json", "docker-compose.yml": "docker", "docker-compose.yaml": "docker",
        "yarn.lock": "lock", "pnpm-lock.yaml": "lock", "cargo.lock": "lock", "podfile.lock": "lock", "gemfile.lock": "lock",
    ]

    static let extensions: [String: String] = [
        "swift": "swift", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
        "mts": "typescript", "jsx": "react", "tsx": "react_ts", "json": "json", "jsonc": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "xml": "xml", "plist": "xml", "html": "html", "htm": "html",
        "css": "css", "scss": "sass", "sass": "sass", "md": "markdown", "markdown": "markdown", "py": "python",
        "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "kts": "kotlin", "c": "c", "m": "c",
        "cpp": "cpp", "cc": "cpp", "mm": "cpp", "h": "h", "hpp": "hpp", "cs": "csharp", "rb": "ruby",
        "php": "php", "sh": "console", "bash": "console", "zsh": "console", "fish": "console",
        "lock": "lock", "png": "image", "jpg": "image", "jpeg": "image", "gif": "image", "webp": "image",
        "heic": "image", "ico": "image", "icns": "image", "svg": "svg", "pdf": "pdf", "zip": "zip", "gz": "zip",
        "tgz": "zip", "tar": "zip", "sql": "database", "sqlite": "database", "db": "database",
        "vue": "vue", "graphql": "graphql", "gql": "graphql", "log": "log", "lua": "lua", "dart": "dart",
        "ini": "settings", "conf": "settings", "cfg": "settings", "env": "tune", "pem": "certificate", "crt": "certificate",
    ]

    /// Every icon file a mapping can name (used by tests to check the bundle).
    public static var allNames: Set<String> {
        Set(folders.values).union(files.values).union(extensions.values).union(["folder", "readme", "tune", "docker", "document"])
    }
}
