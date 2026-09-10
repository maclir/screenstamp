# Screenstamp — portable display layouts & window placement for macOS

Screenstamp is a command-line screen and window manager for macOS: save your display setup and window layout once, then stamp it onto the compatible screens connected at another desk.

It preserves:
- **Display Topology**: Resolution, refresh rate, color depth, scaling, rotation, and arrangement without tying a profile to one physical monitor ID.
- **Native macOS Full Screen**: Reliably moves native full-screen windows across screens to their designated display.
- **Window Positioning**: Preserves the exact side and size of desktop windows (e.g. left half, right half, floating) scaled proportionally to each monitor.
- **Profile & PWA Disambiguation**: Differentiates between Google Chrome profiles (e.g. Work vs. Personal) and installed PWAs (e.g. Google Calendar, Google Meet).
- **Auto-Launch**: Automatically opens any saved apps or profiles that aren't already running before placing them.

## Install

Screenstamp requires macOS and [Homebrew](https://brew.sh):

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/maclir/screenstamp/main/install.sh)"
```

The installer adds [`displayplacer`](https://github.com/jakehilborn/displayplacer) through Homebrew when missing, builds the window helper using system Swift, and installs `screenstamp` into Homebrew's `bin` directory (or `SCREENSTAMP_INSTALL_DIR`).

To install from a source checkout:

```sh
git clone https://github.com/maclir/screenstamp.git
cd screenstamp
make install
```

`make install` defaults to `~/.local/bin/screenstamp`; override it with `make install PREFIX=/another/path`. Ensure the selected `bin` directory is on your `PATH`.

### Post-Installation: Automated Permissions Setup

Because Screenstamp inspects and moves application windows across displays, macOS requires granting **Accessibility** permissions to your terminal:

To set this up or check your status at any time, run:

```sh
screenstamp permissions
```

* If permissions are already active, it reports `Accessibility permissions: OK`.
* If not, **Screenstamp automatically triggers the macOS permission dialog and opens System Settings directly to the exact toggle screen** (`Privacy & Security > Accessibility`), so you only have to click the switch for your terminal application (**iTerm2**, **Terminal**, etc.).

## Usage

### 1. Save full layout (Displays + Apps)

Arrange your displays in macOS Display Settings and position your windows (including native full-screen apps and side-by-side splits), then run:

```sh
screenstamp save office
```

This saves both your display geometry (`office.profile`) and your open window/app placements (`office.apps`).

### 2. Save only display settings or app placements

If you only want to save display topology without modifying app layouts:

```sh
screenstamp save-displays office
```

Or if your displays are already set up and you only want to snapshot or refresh window placements:

```sh
screenstamp save-apps office
```

### 3. Load full layout (Displays + Windows)

At another desk with compatible displays, apply the display arrangement and restore your apps:

```sh
screenstamp load office
```

This will:
1. Stamp the display geometry (resolutions, orientations, scaling, and origins) onto the connected monitors.
2. Launch any saved applications or Chrome profiles that are not currently running.
3. Move non-fullscreen windows to their saved positions (e.g. left or right half of the screen).
4. Move native full-screen windows to their assigned monitors.

### 4. Load only display settings (without moving apps)

If you just want to set up your monitor resolutions, rotation, and arrangement without moving or touching any of your open apps:

```sh
screenstamp load-displays office
```

### 5. Load only app placements

If your displays are already configured and you just want to reposition and launch your apps:

```sh
screenstamp load-apps office
```

### 6. List saved profiles

```sh
screenstamp list
```

Names may contain letters, numbers, dots, underscores, and hyphens. Saving an existing name updates that screen stamp.

Profiles live in `${XDG_CONFIG_HOME:-~/.config}/screenstamp/profiles`. Set `SCREENSTAMP_PROFILE_DIR` to override that location.

The equivalent Make targets remain available when working in the repository:

```sh
make save office
make load office
make save-displays office
make load-displays office
make save-apps office
make load-apps office
make permissions
make list
```

## How portability works

### Displays
Connected displays are assigned portable roles such as `builtin-1` and `external-1`. When loading, those roles are mapped to the physical IDs connected at that moment, avoiding vendor ID mismatches across identical or equivalent monitors at different docks.

### Windows and Relative Positioning
Non-fullscreen window coordinates are stored as normalized percentages (from `0.0` to `1.0`) relative to the monitor's usable bounds:
- **Left half**: `rel_x: 0.0, rel_y: 0.0, rel_w: 0.5, rel_h: 1.0`
- **Right half**: `rel_x: 0.5, rel_y: 0.0, rel_w: 0.5, rel_h: 1.0`

When restored, coordinates scale to fit the target monitor regardless of whether its resolution is 1080p, 1440p, or 4K.

### Native macOS Full Screen
macOS native full-screen windows reside in dedicated Spaces that cannot be directly moved via standard window coordinates. Screenstamp coordinates a smooth transition:
1. Temporarily toggles full-screen off.
2. Moves the window into the origin coordinates of the target display.
3. Toggles full-screen back on, prompting macOS to establish the full-screen Space on that monitor.

### Chrome Profiles & Installed PWAs
- **Chrome Profiles**: Screenstamp reads Chrome's local state and window title suffixes to distinguish between profiles (e.g. `Work` vs `Default/Personal`). If closed, it launches the exact profile via `--profile-directory`.
- **Installed PWAs**: Web apps installed via Chrome (such as Google Calendar or Meet) are tracked by their dedicated app shims and bundle identifiers.

## Tests

```sh
make test
```

The tests run hermetically under macOS `/bin/zsh` with mocked display and app helper drivers; they do not alter real screens or user windows.

## License

[MIT](LICENSE) © 2026 Alireza Pazirandeh
