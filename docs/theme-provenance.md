# Theme catalog provenance

The built-in Herdr palettes in `Sources/HerdrCore/Appearance/BuiltInThemes.swift`
are adapted from the official Herdr repository:

- Repository: <https://github.com/herdrdev/herdr>
- Fixed revision: `18061191fdc019498610aee81f0df93f6c2ebd31`
- Revision date: 2026-09-16
- Package version at that revision: Herdr 0.9.0
- Upstream license: Apache License 2.0, as declared in `Cargo.toml` and
  provided in upstream `LICENSE`
- Upstream source paths: `src/app/state.rs` (palette values, token meanings,
  exact-name lookup), `src/config/theme.rs` (catalog, aliases, color parser),
  and `src/app/mod.rs` (light/dark sibling selection and override order)

No upstream source file is vendored verbatim. The 17 concrete RGB palette
tables from `src/app/state.rs` were copied and adapted into
`Sources/HerdrCore/Appearance/BuiltInThemes.swift`. The catalog names,
aliases, appearance siblings, reset aliases, supported color names, RGB and
hex syntax, and semantic status mapping were adapted into the Foundation-only
types in `Sources/HerdrCore/Appearance`.

The pinned `THEME_NAMES` list contains 18 entries. This implementation includes
all 17 concrete presets: `catppuccin`, `catppuccin-latte`, `tokyo-night`,
`tokyo-night-day`, `dracula`, `nord`, `gruvbox`, `gruvbox-light`, `one-dark`,
`one-light`, `solarized`, `solarized-light`, `kanagawa`, `kanagawa-lotus`,
`rose-pine`, `rose-pine-dawn`, and `vesper`. It also adds the native `uherdr`
preset. The remaining upstream entry, `terminal`, contains symbolic ANSI colors
and reset values rather than a concrete RGB palette. It is deliberately kept as
a separately resolved palette source; requesting it from `BuiltInThemes`
returns `terminalRequiresPaletteSource` instead of inventing RGB values.

The seven upstream appearance sibling families are preserved:

| Dark | Light |
| --- | --- |
| `catppuccin` | `catppuccin-latte` |
| `tokyo-night` | `tokyo-night-day` |
| `gruvbox` | `gruvbox-light` |
| `one-dark` | `one-light` |
| `solarized` | `solarized-light` |
| `kanagawa` | `kanagawa-lotus` |
| `rose-pine` | `rose-pine-dawn` |

`palette(named:)` performs exact-name lookup for the upstream behavior when
auto-switching is disabled. `palette(named:variant:)` selects the appropriate
sibling for appearance-aware resolution. Unpaired presets are unchanged by the
variant.

All 19 upstream tokens are retained. Native semantic aliases are normalized as
follows so views do not interpret upstream palette keys:

| Native role | Upstream token |
| --- | --- |
| `window_bg` | `surface_dim` |
| `sidebar_bg` | `sidebar_bg` |
| `panel_bg` | `panel_bg` |
| `text` | `text` |
| `secondary_text` | `subtext0` |
| `border` | `surface1` |
| `focus` | `accent` |
| `selection` | `selection_bg` |
| `active_row` | `active_row_bg` |
| `status_done` | `green` |
| `status_working` | `yellow` |
| `status_blocked` | `red` |
| `status_unseen` | `blue` |
| `status_notification` | `teal` |
| `status_interrupted` | `peach` |
| `special_text` | `mauve` |

Upstream presets intentionally leave `sidebar_bg` as reset. A reset is a
fallback instruction, not transparent or invisible output: resolution restores
the role's base value, and the native adapter supplies the dynamic system color
when the base is also reset. The `uherdr` preset similarly preserves current
dynamic system surfaces and text through reset values while recording the
current literal accent (`0.34`, `0.73`, `0.58`, converted to 8-bit sRGB as
`87, 186, 148`) and current status color literals.
