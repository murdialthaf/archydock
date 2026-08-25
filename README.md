# ArchyDock

Modern dock for **Hyprland / Omarchy (Quickshell/Quattro)** — a correct-by-construction replacement for `nwg-dock-hyprland`.

It fixes the two core nwg-dock problems:

1. **Icons are tied to window class.** ArchyDock treats the `.desktop` file as the source of truth. A running window is matched to its desktop entry via a tiered pipeline (launch-ledger → Flatpak sandboxed ID → exact/canonicalized app ID → `StartupWMClass` → executable basename via `/proc` → learned mappings), so you never need to rename `.desktop` files or hand-edit `Icon=` paths.
2. **Pinned apps cannot be reordered.** Pins are an ordered list in `~/.config/archydock/config.json` (XDG config, never cache) and can be reordered by drag-and-drop on the dock itself; right-click toggles pin. Order persists across restarts.

Plus a real **GUI settings surface** (icon size, spacing, padding, radius, position, autohide, indicators, grouping) and first-class **Omarchy integration** (theme-following via `Style`/`Color`, layer-shell positioning, IPC over `archydock` target).

> Marketplace: this repo is a valid [Omarchy plugin](https://omarchyplugins.com/develop.html) (`manifest.json` at root, `panel` kind, `Panel.qml` entry point). It runs inside the long-running `omarchy-shell` Quickshell process, unsandboxed, with your user permissions.

## Install

```sh
# From an Omarchy machine (Quattro)
omarchy plugin add https://github.com/murdialthaf/archydock.git
# The plugin is `keepLoaded:true`, so no bar placement step is needed — the dock appears at the bottom.
# Enable/disable (persists in shell.json):
omarchy plugin enable io.github.murdialthaf.archydock
omarchy plugin disable io.github.murdialthaf.archydock
```

Or clone manually for development:

```sh
git clone https://github.com/murdialthaf/archydock.git ~/.config/omarchy/plugins/io.github.murdialthaf.archydock
omarchy-shell shell rescanPlugins
```

## Usage

- **Running apps** appear automatically with correct icons; grouped by desktop entry when `groupWindows` is on.
- **Left-click** a running app to focus its window; clicking the focused app minimizes (configurable).
- **Right-click** an icon to **pin/unpin** (pin order = dock order). Pinned apps stay when nothing is running.
- **Drag a pinned icon** to reorder; order is written immediately to `~/.config/archydock/config.json`.
- **Right-click the dock background → Settings** (or `omarchy-shell shell summon io.github.murdialthaf.archydock`) to tune appearance/behaviour.
- **IPC** (scripts, keybinds):
  ```sh
  omarchy-shell shell summon io.github.murdialthaf.archydock    # show
  omarchy-shell shell hide    io.github.murdialthaf.archydock    # hide
  # Via the plugin's own IpcHandler target `archydock`:
  qs ipc call archydock pins          # JSON array of pinned desktop IDs
  qs ipc call archydock pin firefox.desktop
  qs ipc call archydock reorder 0 2
  ```

### Replacing nwg-dock-hyprland

Remove or stop the old dock's autostart (e.g. an `exec-once = nwg-dock-hyprland …` line), then enable ArchyDock. Pinned apps from nwg-dock live in `$XDG_CACHE_HOME/nwg-dock-pinned` (cache dir). Import them:

```sh
# One-shot importer — maps bare class strings to real desktop IDs through the pipeline
python3 ~/.config/omarchy/plugins/io.github.murdialthaf.archydock/tools/import-nwg-dock.py
```

## Configure

Appearance and behaviour are in `~/.config/archydock/config.json` (created on first run):

```json
{
  "pinnedIds": ["firefox.desktop","org.wezfurlong.wezterm.desktop","code.desktop"],
  "learnedMap": { "weird-electron-class": "slack.desktop" },
  "iconSize": 44
}
```

The dock hot-reloads this file; editing it and saving is enough. A GUI panel (Settings) is also provided.

## Remove

```sh
omarchy plugin remove io.github.murdialthaf.archydock
# Optional: clear persisted pins/corrections
rm -rf ~/.config/archydock
```

## How app identification works

`DockModel.js` implements the pipeline documented in the research notes:

```
Tier 0 launch ledger (pid of windows we spawned)
  → Tier 1 Flatpak sandboxed ID / .flatpak-info
  → Tier 2 exact & canonicalized app_id == desktop ID
  → Tier 3 StartupWMClass (instance before class, like GNOME Shell)
  → Tier 4 executable basename via /proc/<pid>/exe & cmdline
  → Tier 5 learnedMap (your corrections, persisted)
  → Tier 6 fallback (generic icon + "Identify…" affordance)
```

Icon lookup respects absolute `Icon=` paths, Flatpak export dirs (`/var/lib/flatpak/exports/share/icons` and `~/.local/share/flatpak/exports/share/icons`), and theme fallbacks.

## Validation

```sh
PLUGIN_DIR="$HOME/.config/omarchy/plugins/io.github.murdialthaf.archydock"
# Manifest + repo layout
omarchy plugin validate "$PLUGIN_DIR"
# QML lint against the installed shell imports
qmllint -I "$OMARCHY_PATH/shell" "$PLUGIN_DIR/Panel.qml"
# Self-test of the JS domain logic (no display needed)
qmljs -e 'import("./DockModel.js") as M; M._test()'  # or node -e with a stub
```

## External dependencies

- **Omarchy Quattro** with `quickshell` + `qt6-wayland` (bundled with Omarchy)
- At runtime `hyprctl` is invoked to list windows and to focus/launch (`gtk-launch` preferred for launching; it correctly handles `Exec=` field codes)
- No build step and no second Quickshell process. The plugin is pure QML/JS + shell invocations.

## License

MIT — see [LICENSE](LICENSE).
