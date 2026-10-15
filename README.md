# UltraStar WorldParty

Sing karaoke with up to six players. The game scores singing against the pitch
and rhythm in each song.

This repository is a development source fork of UltraStar WorldParty. The
original WorldParty project describes itself as a fork of UltraStar Deluxe 1.1 (USDX).
The changes below belong to this fork; they should not be read as
features of stock upstream releases. Historical contributor credits are in
[COPYRIGHT.txt](COPYRIGHT.txt). License terms and bundled notices are in
[LICENSE](LICENSE), [game/licenses](game/licenses), and the relevant vendored
directories.

## Changes in this fork

- Artist-first song navigation with an alphabet rail:
  [artist navigation](docs/artist-navigation.md).
- Target-note labels, a continuous detected-pitch trace, and an optional
  readout: [pitch display](docs/pitch-display.md).
- Microphone setup and SDL reconnect handling:
  [microphone recovery](docs/microphone-recovery.md).
- A Linux shutdown correction, with the remaining evidence limits recorded in
  the [validation report](docs/validation/results.md).
- An experimental, developer-only catalog search and sign-in screen. It
  requires explicit absolute paths to a Python executable and adapter, is not
  included in game packaging, and does not enable downloads:
  [integration boundary](docs/song-search-integration.md).

## Status

This is development source, not a packaged release. The checked-in Linux
gameplay report is dated 2026-10-13 and records results for its stated
environment and candidate; it does not validate every later change in this
tree. The report does not establish a Windows build or real-microphone
behavior. The catalog work is source-only, and no live catalog request or
download was part of its offline checks. See [CONTRIBUTING.md](CONTRIBUTING.md)
for build and test guidance and the remaining reproducibility limits.

## Build from source

For a Linux source build, run these commands from the repository root after
installing the required development tools and libraries:

```sh
./autogen.sh
./configure
make
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the checked dependencies and
focused test entry points. [Linux build notes](dists/linux/README.md) describe
legacy packaging scripts separately from a normal source build.

## Documentation

- [Build, tests, and contributor guidance](CONTRIBUTING.md)
- [Artist navigation](docs/artist-navigation.md)
- [Pitch display](docs/pitch-display.md)
- [Microphone setup and recovery](docs/microphone-recovery.md)
- [Experimental song-search integration](docs/song-search-integration.md)
- [Catalog backend and retained review evidence](docs/song-catalog-backend.md)
- [Dated Linux verification report](docs/validation/results.md)
- [Legacy Atom build workflow](dists/atom/README.md)
- [Legacy VS Code build workflow](dists/vscode/README.md)

## Upstream and community resources

- [WorldParty project and development resources](https://github.com/ultrastares/ultrastar-worldparty)
- [WorldParty wiki](https://github.com/ultrastares/ultrastar-worldparty/wiki)
- [Official WorldParty website](https://ultrastar-es.org)
- [Community forum](https://ultrastar-es.org/foro)
- [UltraStar Deluxe source project](https://github.com/UltraStar-Deluxe/USDX)

The badges and artwork below are inherited project links. They do not establish
that this source fork has a tested package or release.

[![WorldParty on Snapcraft](https://snapcraft.io/ultrastar-worldparty/badge.svg)](https://snapcraft.io/ultrastar-worldparty)
[![WorldParty on Snapcraft](https://snapcraft.io/ultrastar-worldparty/trending.svg?name=0)](https://snapcraft.io/ultrastar-worldparty)

![WorldParty logo](https://github.com/Daniel20Ultrastar-es/usdxworldparty/blob/master/promo/Worldparty%20logo.png)

![WorldParty screenshot](https://github.com/Daniel20Ultrastar-es/usdxworldparty/blob/master/promo/promocion1.gif)

![WorldParty screenshot](https://github.com/Daniel20Ultrastar-es/usdxworldparty/blob/master/promo/promocion2.gif)

![WorldParty screenshot](https://github.com/Daniel20Ultrastar-es/usdxworldparty/blob/master/promo/promocion3.gif)
