# Linux build and legacy packaging notes

This directory contains older Linux packaging helpers. A normal source build and
the optional `build.sh` packaging flow are different workflows.

## Build from source

Run the source build from the repository root, after installing the development
tools and libraries required by `configure`:

```sh
./autogen.sh
./configure
make
```

The configure check rejects Free Pascal versions below 3.0.0 and declares no upper
version bound. The build also requires a C compiler, `pkg-config`,
and the SDL2, SDL2_image, FreeType, SQLite, Lua (5.1 or newer), and FFmpeg
(libavcodec, libavformat, libavutil) development packages. The Makefile base FPC
flags default to `-Si -Sg -Sc -v0Binwe`; release flags default to `-Xs -O4`.
See `src/Makefile.in` for the debug and release flag definitions.

The repository-root `install` helper is named `install`, without a `.sh`
suffix. It is a Debian/Ubuntu convenience script that uses `sudo apt-get`, runs
configure/build/install commands, and copies a desktop file into
`/usr/share/applications`. Review its system-wide effects before running it; it
is not required just to invoke the source build above.

## Legacy packaging status

The `dl.sh`, `build-deps.sh`, and `build.sh` scripts form a legacy workflow, not a
currently verified distro-independent package recipe. The downloader pins old
SDL2, SDL2_image, SQLite, FFmpeg 3.2.2, FreeType, libpng, and Yasm sources; the
build scripts also remove and recreate their generated `deps`, `prefix`, and
`output` directories. Do not assume this version set matches a current system or
the validation receipt in `docs/validation/results.md` (which records a local
Linux build with FPC 3.2.2 and FFmpeg 4.2.7 libraries). Generated packages need
separate testing on each target distribution.

`build.sh` expects to be run with the working directory set to `dists/linux`.
It builds and installs into `dists/linux/output`, then copies and scans shared
libraries. It does not copy `launch.sh` into that output directory. The legacy
`launch.sh` helper has not been validated as a launcher and contains a
post-launch write under `/usr/share/applications`; review it before use.

## Cleaning

Run the project Makefile targets from the configured repository root:

- `make clean` removes the default `game/WorldParty` binary and generated FPC
  build objects.
- `make distclean` also runs `clean-game`, which removes `game/*.log`,
  `game/*.db`, and `game/*.ini` files and attempts to remove empty data folders.
  Back up anything you need before using it; it can remove local game settings
  and databases.

There are no `make compress` or `make upload` targets in the checked-in
`Makefile.in`. The `make dist` target is a legacy SVN-based source archive task,
not a Linux binary-packaging command.
