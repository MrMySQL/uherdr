# uherdr coloring design

Status: implementation delivered in three increments on `feat/coloring`; acceptance evidence is recorded in `docs/verification.md`. The broad whole-branch review at `c183a4c` found no blocking issues, and its three minor follow-ups have been applied.

## Outcome and scope

Adopt upstream Herdr's existing theme and sidebar coloring features in uherdr. Apply global theme roles to the native sidebar, tabs, pane headers and borders, and status indicators while preserving existing embedded-terminal appearance behavior.

Confirmed scope: upstream coloring features only. Exclude individual workspace/tab/pane color assignments, resource-color inheritance, per-pane background overrides, and a new terminal “Match app theme” option. Native controls may expose upstream-supported theme tokens and sidebar rules, but must not introduce additional coloring semantics.

## Pre-adoption baseline

- `WorkspaceView.swift` defines one fixed green accent and applies it to the window.
- `DeviceSidebarView.swift` and `PaneLayoutView.swift` derive selection fills and borders from that accent.
- `TerminalSurface.swift` creates a fixed light/dark Ghostty theme. Its coordinator already updates appearance and font size without replacing the surface.
- `SessionStore.swift` owns appearance and font preferences; `DeviceStore.select` copies them between devices.
- `TerminalTabDeck.swift` retains hidden terminal hosts and defers cosmetic changes until reveal. Preserve this behavior.
- `HerdrCore/Models.swift` does not decode sidebar metadata tokens.

## Approach

Recommended: a native appearance store with an optional, read-only Herdr config source. Keep rendering and user preferences in uherdr; translate upstream settings at the boundary.

Alternatives considered:

1. Native settings only: smallest dependency surface, but duplicates configuration and misses the requested compatibility.
2. Write directly into Herdr's config: one settings file, but requires preserving unrelated TOML and makes native-only settings confusing. Do not choose this for the first implementation.

The recommended approach works offline, applies equally to local and SSH devices, and needs no runtime patch.

## Global constraints

- Keep macOS 14 as the minimum platform and Swift 6.0 as the documented build requirement.
- Keep Herdr 0.9.0 as the base runtime requirement; newer metadata is optional and capability-dependent.
- Keep GhosttyTerminal as the terminal renderer; use its existing configuration APIs without vendor edits.
- Store native appearance preferences locally; do not modify Herdr config files or remote machines.
- A color change must not recreate a terminal, restart a shell, acquire a new writable controller, or discard scrollback.
- Preserve retained-tab behavior: hidden tabs receive cosmetic changes before reveal, without continuous hidden-view publication.
- Preserve the current appearance until the user selects a theme or imports settings.
- Adopt only upstream-supported coloring semantics; add no individual resource colors or terminal palette customization.

## Theme behavior

Add Settings → Appearance with System / Light / Dark, a theme picker, separate light and dark choices, UI color overrides, and reset controls. Keep font size in the same shared store to eliminate device-switch copying. Migrate the existing `appearance` and `fontSize` preferences once.

Ship the current uherdr look as the default preset. Add the complete concrete built-in palette catalog from a pinned upstream Herdr revision, recording names, values, licenses, and provenance. Do not claim parity with an unpinned moving branch.

Resolve colors in this order:

1. Selected built-in preset for the effective appearance.
2. Imported common overrides.
3. Imported light/dark overrides when upstream auto-switching applies.
4. Native common and active-mode overrides.

Native System appearance follows macOS. Imported auto-switching uses that appearance signal; forced Light or Dark supplies the corresponding signal. With imported auto-switching disabled, the imported theme name stays fixed. Selecting a native preset switches the source back to Native; source selection is visible in Settings.

Use semantic roles for app surfaces and status colors. Resolve upstream colors into those roles once; views must not interpret TOML or palette keys. Expose only upstream-supported color overrides. Preserve non-color selection, focus, and status cues.

## Compatibility boundary

Upstream provides named themes, shared and mode-specific overrides, sidebar token styles, and ordered conditional rules. Styles are local to the client, including SSH use. [Herdr configuration](https://herdr.dev/docs/configuration/)

Import `[theme]`, `[theme.custom]`, its light/dark tables, and sidebar row/style configuration. The supported token inventory is `accent`, `panel_bg`, `sidebar_bg`, `active_row_bg`, `selection_bg`, `surface0`, `surface1`, `surface_dim`, `overlay0`, `overlay1`, `text`, `subtext0`, `mauve`, `green`, `yellow`, `red`, `blue`, `teal`, and `peach`. Mode-specific tables use the same inventory. [Config reference](https://herdr.dev/docs/config-reference/)

Use a real TOML parser: proposed dependency TOMLKit 0.5.0, pinned exactly after the build check. It exposes TOML parsing and Codable conversion. Record transitive notices in app packaging. [TOMLKit](https://github.com/LebJe/TOMLKit)

Settings offers Native / Herdr config sources, a file chooser initially pointing to `~/.config/herdr/config.toml`, Reload, and a diagnostic summary. Load on app startup and explicit Reload; automatic file watching is outside this first plan. Keep a persisted last-good imported snapshot for offline startup. Reject a malformed supported section atomically, retain the last good appearance, and show the path/key error. Ignore unrelated config sections; report unsupported theme/sidebar keys without failing unrelated settings.

Native adaptations:

| Upstream concept | uherdr behavior |
| --- | --- |
| Host-terminal light/dark signal | macOS appearance or native forced mode |
| `terminal` theme | Embedded terminal's configured ANSI palette; explain that there is no outer terminal |
| Reset/default/transparent color | Clear that override and use the native role fallback; do not make text invisible |
| Active sidebar row | Selected workspace or focused agent background |
| Navigate-mode selection | Keyboard-focused sidebar row; no new navigation mode |
| Pane borders and tab selection | Native rounded border/header and tab indicator roles |

The import changes UI colors. Keep the existing embedded terminal light/dark palettes and font controls; do not add terminal background, foreground, ANSI palette, or theme-matching controls. The `terminal` UI theme reads the existing embedded ANSI palette as its source without modifying it. Programs' explicit output colors remain authoritative. Do not claim to retheme RGB colors already present in server-rendered frames.

## Sidebar rules

Provide a dedicated sidebar row renderer so imported styles apply to the configured token occurrence. Support custom rows and per-agent row overrides as needed for coloring; do not expand this into general upstream UI parity.

Support fixed foreground, bold, and dim styles; first-match rules using `equals`, `contains`, `starts_with`, `gt`, and `lt`; upstream matching and validation semantics; and missing-token suppression. Apply rules before truncation. Token styles affect text only, not separators or row backgrounds. [Sidebar styling](https://herdr.dev/docs/configuration/#sidebar-row-layouts)

Decode optional workspace/pane/agent metadata through the existing snapshot path. Preserve old-server decoding. Built-in values come from existing models where available; branch/Git/title fields require verifying their actual wire schema before adding optional decoders. Unavailable fields disappear; show a compatibility note rather than fabricate values or poll each pane separately. Use read-only supplementary snapshot/list data only if needed and batch it with the existing refresh cycle.

The native rule editor provides target token, condition/value, color, bold/dim, ordering, and a preview. Imported rules stay read-only until copied into a native preset. Preserve explicit false modifiers, numeric comparisons, matching limits, and per-agent overrides on round trip.

## Architecture and performance

- `HerdrCore/Appearance`: Foundation-only colors, presets, resolver, import normalization, and sidebar rules.
- `HerdrMac/Appearance`: one app-owned `AppearanceStore`, native adapters, Settings, and a sidebar rule editor limited to upstream semantics.
- `DeviceStore` receives the shared store; `SessionStore` keeps compatibility forwarding accessors for font hotkeys/tests, without separately persisting appearance.
- SwiftUI views receive a resolved palette through the environment. Separately hosted terminal trees receive immutable, equatable appearance values through `TerminalTabSnapshot`.
- Keep Ghostty's existing font and light/dark update path. UI-only theme edits must not reconfigure terminal colors or replace surfaces.
- Theme resolution, config parsing, and rule normalization run outside the terminal frame path. Cache compiled rules per settings revision; metadata changes only reevaluate affected rows.

## Delivery and acceptance

Deliver three reviewable increments: native theme infrastructure and UI; Herdr import plus sidebar styling; acceptance and documentation. Each increment must build and preserve existing defaults.

Acceptance: imported presets and overrides render consistently; existing light/dark switches update visible terminals in place; hidden tabs adopt UI changes on reveal; UI-only theme changes preserve terminal palettes; malformed imports retain last-good settings; sidebar rules evaluate each device's own metadata; status cues remain distinguishable; and existing keyboard, terminal, and performance checks pass. Confirm that no individual-resource coloring controls or preferences are introduced.

This document records the approved design. See `docs/appearance.md` for implemented behavior and `docs/verification.md` for actual verification and capability limits. Newer optional metadata is schema-tested; a newer live runtime is not claimed.
