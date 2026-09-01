# Screenstamp — portable display layouts for macOS

Screenstamp is a small command-line **screen stamp** for macOS: save your screen
setup once, then stamp it onto the compatible screens connected at another
desk. It preserves resolution, refresh rate, color depth, scaling, enabled
state, rotation, and arrangement without tying a profile to one physical
monitor.

## Install

Screenstamp requires macOS and [Homebrew](https://brew.sh):

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/maclir/screenstamp/main/install.sh)"
```

The installer adds
[`displayplacer`](https://github.com/jakehilborn/displayplacer) through Homebrew
when it is missing, then installs `screenstamp` into Homebrew's `bin` directory.
Set `SCREENSTAMP_INSTALL_DIR` to override the destination.

To install from a source checkout instead:

```sh
git clone https://github.com/maclir/screenstamp.git
cd screenstamp
make install
```

`make install` defaults to `~/.local/bin/screenstamp`; override it with
`make install PREFIX=/another/path`. Make sure the selected `bin` directory is
on `PATH`.

## Usage

Configure a desk once in macOS Display Settings, then save the screen stamp:

```sh
screenstamp save office
```

At another desk with the same display topology, stamp that setup onto the
connected screens:

```sh
screenstamp load office
```

List the saved screen stamps:

```sh
screenstamp list
```

Names may contain letters, numbers, dots, underscores, and hyphens. Saving an
existing name updates that screen stamp.

Screen stamps live in `${XDG_CONFIG_HOME:-~/.config}/screenstamp/profiles`.
Set `SCREENSTAMP_PROFILE_DIR` to override that location.

The equivalent Make targets remain available when working in the repository:

```sh
make save office
make load office
make list
```

## How portability works

When saving, connected displays are assigned roles such as `builtin-1` and
`external-1`. When loading, those roles are mapped to the physical IDs connected
at that moment. Screenstamp refuses to continue unless the number and roles of
the connected displays match the saved screen stamp.

This is deterministic for the common MacBook plus one external monitor setup.
Multiple external monitors are recorded as `external-1`, `external-2`, and so
on, but macOS may enumerate identical monitors in a different order at another
dock. Every target monitor must also support the resolution and refresh rate
stored in the screen stamp.

## Tests

```sh
make test
```

The tests use a fake `displayplacer`; they do not modify the actual displays.

## License

[MIT](LICENSE) © 2026 Alireza Pazirandeh
