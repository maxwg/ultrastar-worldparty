# Contributing

This guide covers source builds and focused checks for the WorldParty source
fork. See [README.md](README.md) for project status and the documentation map.

## Preserve provenance

This tree contains historical UltraStar WorldParty and USDX material alongside
fork-specific changes. Keep existing copyright headers, license files, and
bundled notices intact. When adapting code or ideas from another project,
record the upstream project, relevant commit, and specific adaptation in the
feature documentation. Describe behavior in this fork separately from
upstream behavior.

## Build from source

The checked-in `autogen.sh` runs `autoreconf` and generates the configure files.
Install the Autotools needed by `autoreconf`, GNU make, and the platform
compiler/library dependencies before starting the Linux source build:

```sh
./autogen.sh
./configure
make
```

`configure.ac` requires Free Pascal 3.0.0 or newer, a C compiler, `pkg-config`,
SDL2, SDL2_image, FreeType, SQLite, Lua 5.1 or newer, and FFmpeg's
`libavformat` and `libavutil` packages. It probes `libavcodec` conditionally
and checks detected FFmpeg versions against its compatibility table. The FPC
check has no declared upper version limit.

For distribution-specific dependency notes and the separate legacy packaging
workflow, see [dists/linux/README.md](dists/linux/README.md). The Atom and VS
Code guides document editor wrappers, not alternate build systems.

## Focused tests

The root Makefile does not define an aggregate `test` or `check` target. The
Pascal helpers can be compiled individually from the repository root:

```sh
mkdir -p build/tests
fpc -B -Fu./src/base -FU./build/tests -FE./build/tests tests/artist_navigation_test.pas
./build/tests/artist_navigation_test
fpc -B -Fu./src/base -FU./build/tests -FE./build/tests tests/pitch_display_test.pas
./build/tests/pitch_display_test
```

These helpers cover isolated navigation and pitch-estimator logic. They do not
validate the full game UI, live audio capture, or physical microphones. Other
focused entry points include:

- `tests/run_capture_state_test.sh` uses a fake capture backend and requires
  existing application Pascal units; see
  [microphone recovery](docs/microphone-recovery.md).
- `tests/catalog_bridge/run.sh` uses offline fixtures and requires an absolute
  existing Python executable and FPC unit root; see
  [song-search integration](docs/song-search-integration.md).
- `tests/catalog/run_windows.py` is a separate offline Windows runner. It
  requires Python 3.11 or newer, MSVC, and explicit FFmpeg and ffprobe paths;
  its scope and retained history are in
  [catalog backend notes](docs/song-catalog-backend.md).

The [Linux verification report](docs/validation/results.md) is a dated record,
not an aggregate result for the current tree. Interpret each test result only
for its stated scope and candidate.

## Protect local game data

`make distclean` runs `clean-game`, which removes `game/*.db`, `game/*.ini`,
and `game/*.log`, then attempts to remove empty game-data directories. Back up
local settings and databases before using it. These paths are ignored by Git,
so deleting them may not appear in `git status`.

The repository-root `install` helper is a Debian/Ubuntu convenience script
with system package and install effects. Review the
[Linux build notes](dists/linux/README.md) before running it. It is not needed
for the direct source-build commands above.

## Reproducibility and release status

`configure` discovers system dependencies on the build host, and the legacy
packaging scripts describe a separate workflow. The checked-in reports name
specific environments and candidate snapshots; they do not provide a single
reproducible cross-platform build image. Windows, real-microphone, and live
catalog behavior remain unverified in the checked-in evidence. The experimental
catalog integration is not packaged, and the game UI keeps downloads disabled.
Do not treat a passing focused helper or the historical report as a
release-readiness claim.
