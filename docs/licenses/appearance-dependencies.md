# Appearance import notices

The app bundles these runtime/adapted-code notices in `Contents/Resources`:

- `Herdr-LICENSE`: Apache-2.0 license from Herdr revision `18061191fdc019498610aee81f0df93f6c2ebd31`; copied/adapted palettes and terminal role mappings. That checkout has no root NOTICE file.
- `TOMLKit-LICENSE`: Jeff Lebrun's MIT license, TOMLKit 0.5.0 (`be015e1a4f84b5aeae3ce4c4eab5ff6ca7ce7ff9`).
- `tomlplusplus-LICENSE`: Mark Gillard's MIT license for the bundled toml++ v3.0.1 header, including Bjoern Hoehrmann's embedded UTF-8 decoder attribution and MIT permission notice (https://bjoern.hoehrmann.de/utf-8/decoder/dfa/).

SwiftPM's app dependency graph includes TOMLKit/CTOML and the existing GhosttyTerminal dependencies. The generated root `Package.resolved` pins the actual graph. TOMLKit declares Checkit solely for its own tests; it is not linked into this app. The standalone TOMLKit preflight resolved Checkit `master` at `f2b91bd4ec068a0ab8a73051c0077d1e1b614b43`, but the app's Swift 6.4 resolver omits that unused test dependency.

Validation used Apple Swift 6.4 and the macOS 26.5 SDK. The package retains macOS 14 deployment support and the documented Swift 6.0 build requirement; this is not a Swift 6.0 verification. Pinned dependency deprecation/conformance warnings and the installed SDK's missing linker search-path warnings remain unchanged.
