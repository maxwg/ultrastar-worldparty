# Atom build workflow (legacy)

This repository includes Atom Build wrappers, but this is a legacy editor
workflow. It requires Free Pascal and the development dependencies required by
the project; the wrappers do not install them.

On Debian/Ubuntu, the repository-root helper is `./install`, not `./install.sh`.
It runs `sudo apt-get`, then configure/build/install commands, and copies a
desktop file into `/usr/share/applications`. Review those system-wide effects
before running it. If you only need compiler dependencies, install the
appropriate development packages for your distribution separately.

Copy the matching configuration file from the repository root, then restart
Atom:

- Linux: copy `dists/atom/linux/.atom-build.json` to `.atom-build.json`.
- Windows: copy `dists/atom/windows/.atom-build.json` to `.atom-build.json`.

The checked-in key mappings are:

- F9: compile debug build.
- Ctrl+F9: compile regular build.
- F10: compile and execute debug build.
- Ctrl+F10: compile and execute regular build.
- F11: execute debug build without compiling.
- Ctrl+F11: execute regular build without compiling.

These mappings come from the checked-in Atom Build configuration. The wrapper
scripts call FPC directly; their build commands and flags are in
`dists/atom/linux/compile.sh` and `dists/atom/windows/compile.bat`.
