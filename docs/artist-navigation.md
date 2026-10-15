# Artist-first navigation

New configurations default to Artist sorting. Existing saved sort choices remain
unchanged; choose Artist or Artist2 in the song menu to enable the alphabet rail.

The song-screen rail shows # and A–Z. Click a letter or drag along it to
jump to its first visible song. Empty groups are dimmed and do nothing. Scroll the
mouse wheel over the rail, or press Alt+PageUp/Alt+PageDown, to move between nonempty
artist groups. Existing unmodified page keys retain their page navigation.

The index respects the current filtered list, categories and playlists. It uses
WorldParty's existing accent-normalized artist field; numbers, punctuation, empty
artist names and non-Latin initials use #. It does not change song metadata.
The index is rebuilt when sort/filter results change, not scanned on every frame.

## USDX comparison and provenance

Compared with UltraStar-Deluxe/USDX commit
c88370cc5c8e46f3cb685bd95aeb582fbd5dedb9, especially
src/screens/UScreenSong.pas. Adapted its artist-group navigation idea, retaining
WorldParty's plain page controls. Also corrected WorldParty's keyboard artist/title
jump to convert a global song index to a visible index before SkipTo, as USDX does.
This prevents jumping outside the filtered subset. No wholesale merge was used:
the forks have different UI and song-selection contracts. GPL notices are retained.

Standalone production-helper test (from the repository root):

    mkdir -p build/tests
    fpc -B -Fu./src/base -FU./build/tests -FE./build/tests tests/artist_navigation_test.pas
    ./build/tests/artist_navigation_test

Full build and interactive verification results are recorded separately. Passing
this helper does not prove SDL hit-testing, visual layout, audio, or game startup.
