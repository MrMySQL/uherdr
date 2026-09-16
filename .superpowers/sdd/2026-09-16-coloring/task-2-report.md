# Task 2 implementation report

## Status

DONE

## What I implemented

- Added one `@MainActor` `AppearanceStore` for mode, font size, native/imported source state, paired preset selections, common/light/dark native overrides, the persisted last-good imported boundary, and one equatable light/dark resolved snapshot.
- Preserved the existing `appearance` and `fontSize` preference keys as the legacy-compatible canonical values. Invalid persisted values fall back in memory and remain untouched until the corresponding user edit.
- Added no-op suppression for mode, font, preset, source, override, imported-settings, and reset mutations. Each actual mutation increments a shared revision and sends one store publication.
- Injected the app-owned store through `HerdrApp` -> `DeviceStore` -> every `SessionStore`. `SessionStore.appearance` and `fontSize` remain read/write forwarding properties. Device selection no longer copies or writes global appearance state.
- Forwarded shared appearance changes through every existing `SessionStore` observer. `DeviceStore` deduplicates the same shared revision across its session subscriptions, so its observers receive one notification per actual appearance mutation.
- Added `NativePalette`, including dynamic AppKit semantic fallbacks for `.reset`/missing values, SwiftUI color conversion, and a resolved-appearance environment key. `WorkspaceView` supplies the environment itself so standalone mounted views do not depend on `HerdrApp` injection.
- Extracted native Appearance settings from `EditorSheet`: System/Light/Dark mode, separate light/dark presets, existing terminal font size, all upstream-supported UI roles, common/light/dark override sections, immediate preview, per-role fallback, and reset scoped to the displayed section. Herdr source/file controls remain deferred to Task 4.
- Added a normalized `ImportedAppearanceSettings` persistence boundary for Task 4 without implementing parsing or file loading. Fixed imported themes use exact-name palettes and ignore mode tables; auto-switching themes use sibling-aware palettes and active-mode tables.
- Updated every direct `SessionStore.swift` compile script to include `AppearanceStore.swift`; scripts that build `HerdrCore` directly also include `Sources/HerdrCore/Appearance/*.swift`.
- Added `Hashable` to `AppearanceMode` and `ThemeVariant` in `ColorValue.swift`. This additive Task 1 API change is required by the equatable resolved snapshot and typed SwiftUI picker tags. The appearance runner asserts snapshot equality across no-ops and inequality after a mode change; the full core appearance suite also passes.

## TDD evidence

### RED: store and shared-state contract

Command:

```sh
swiftc -parse-as-library -I .build/appearance-red -L .build/appearance-red -lHerdrCore \
  -Xlinker -rpath -Xlinker .build/appearance-red \
  Sources/HerdrMac/SessionStore.swift Sources/HerdrMac/DeviceStore.swift \
  Tests/HerdrMacTests/AppearanceStoreTests.swift \
  -o .build/appearance-red/AppearanceStoreTests
```

Expected failure before production implementation:

```text
Tests/HerdrMacTests/AppearanceStoreTests.swift:22:25: error: cannot find 'AppearanceStore' in scope
```

The runner already contained the migration, invalid fallback, no-op publication, resolved override, shared session/device publication, and device-switch isolation assertions. The compile failure was expected because the required store/API did not exist.

### RED: imported fixed-theme layer order

Command:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-appearance.sh
```

Expected failing output before the resolver correction:

```text
AppearanceStoreTests/AppearanceStoreTests.swift:30: Precondition failed
scripts/test-appearance.sh: line 28: ... Trace/BPT trap: 5
```

This proved that fixed imported themes were incorrectly applying light/dark override tables. The resolver now applies those tables only when imported auto-switching is enabled.

### RED: semantically invalid last-good import

Command:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-appearance.sh
```

Expected failing output before validation:

```text
AppearanceStoreTests/AppearanceStoreTests.swift:88: Precondition failed
scripts/test-appearance.sh: line 28: ... Trace/BPT trap: 5
```

This proved that decodable but unknown imported themes were being accepted. Initialization now falls back in memory without overwriting the saved source/data.

### GREEN

Command:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-appearance.sh
```

Final output:

```text
Build complete! (0.22 sec)
PASS: appearance migration, invalid fallback, resolution, shared publication, and device isolation
```

## Verification

- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --product Herdr` — exit 0.
- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run HerdrCoreTests` — exit 0; 10 protocol/layout/framing/selection/connection tests, tunnel/profile/file tests, and 6 appearance core tests passed.
- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-appearance.sh` — exit 0; migration, second initialization, invalid persistence preservation, fixed/auto imported resolution, exact publication/no-op counts, shared identity, and complete appearance-preference device isolation passed.
- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-agent-worktree.sh` — exit 0.
- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-pane-drag.sh` — exit 0; both transfer and docking groups passed.
- `bash -n` on all five changed scripts — exit 0.
- `git diff --check` — exit 0.

The process-local SDK is necessary because the selected CommandLineTools macOS 27 SDK lacks the `SwiftUIMacros` plugin. The compatible 26.5 SDK worked for both `swiftc` and SwiftPM. Existing CommandLineTools Developer framework/library search-path linker warnings remain; builds and tests exit successfully.

## Files changed

- `Sources/HerdrCore/Appearance/ColorValue.swift`
- `Sources/HerdrMac/Appearance/AppearanceStore.swift`
- `Sources/HerdrMac/Appearance/AppearanceSettingsView.swift`
- `Sources/HerdrMac/Appearance/NativePalette.swift`
- `Sources/HerdrMac/HerdrApp.swift`
- `Sources/HerdrMac/DeviceStore.swift`
- `Sources/HerdrMac/SessionStore.swift`
- `Sources/HerdrMac/EditorSheet.swift`
- `Sources/HerdrMac/WorkspaceView.swift`
- `Tests/HerdrMacTests/AppearanceStoreTests.swift`
- `scripts/test-appearance.sh`
- `scripts/test-agent-worktree.sh`
- `scripts/test-pane-drag.sh`
- `scripts/test-performance.sh`
- `scripts/test-devices.sh`

## Self-review

- Verified every task-brief checkbox against the implementation and tests.
- Strengthened the cross-device test to compare the complete set of `appearance`, `fontSize`, and `appearance.*` preferences before and after selection.
- Corrected fixed imported-theme layer order and semantic validation of persisted imported themes during self-review.
- Confirmed UI-only theme/override changes do not enter `TerminalTabSnapshot`; existing terminal palettes and retained terminal hosts therefore remain unchanged, while mode/font continue through the existing in-place terminal update path.
- Confirmed no importer, file chooser, file watcher, terminal color controls, resource color preferences, config writes, or vendor changes were added.

## Concerns

- No correctness concerns. Task 4 still needs to supply parser diagnostics and any terminal-symbolic palette source when it implements Herdr config loading.
- The repository's untracked controller-owned plan and design spec were not staged or modified by this task.
