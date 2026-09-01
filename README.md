# Display profiles

A small macOS command-line project for saving a display layout and applying it
to the screens connected at another desk. Profiles preserve resolution, refresh
rate, color depth, scaling, enabled state, rotation, and arrangement, but not
monitor-specific IDs.

## Requirement

Install [`displayplacer`](https://github.com/jakehilborn/displayplacer):

```sh
brew install displayplacer
```

## Usage

Configure a desk once in macOS Display Settings, then save it:

```sh
make save office
```

At another desk with the same display topology, apply it:

```sh
make load office
```

The `NAME` form is also available:

```sh
make save NAME=office
make load NAME=office
```

List profiles with `make list`. Profile names may contain letters, numbers,
dots, underscores, and hyphens. Saving an existing name updates that profile.

Profiles live in `profiles/` and are deliberately ignored by Git because they
describe the local machine. The command can also be used directly as
`bin/display-profile`.

## How portability works

When saving, connected displays are assigned roles such as `builtin-1` and
`external-1`. When loading, those roles are mapped to the physical IDs connected
at that moment. Loading refuses to continue unless the number and roles of the
connected displays match the saved profile.

This is deterministic for the common MacBook plus one external monitor setup.
Multiple external monitors are recorded as `external-1`, `external-2`, and so
on, but macOS may enumerate identical monitors in a different order at another
dock. Also, every target monitor must support the resolution and refresh rate
stored in the profile.

## Tests

```sh
make test
```

The tests use a fake `displayplacer`; they do not modify the actual displays.
