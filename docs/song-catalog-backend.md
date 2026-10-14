# New catalog backend slice for independent review

This is a new experimental backend/test integration against commit
`db718a997da54fd5c2baa47e825d540127a6e0de`. It is not recovery of the lost checkpoint.
There is no Pascal bridge, menu entry, app launch, or installation/package change.
The game cannot invoke these tools through this patch.

## Location and provenance

`Makefile.in` already defines `USDXWP_TOOLS_DIR` as the repository's `tools`
directory. The two smallest sibling runtime files are placed there:

- `tools/song_catalog.py`, SHA-256
  `7bf4c83e1f56d4f1f4ba4e4f026b5438e184be9eab05710d18b1c00b9d1f3211`
- `tools/owned_process.py`, SHA-256
  `9f6f62813541fa5f7e6a943e0be025727e76e697f0fa803930ee3fa702a91feb`

The catalog bytes are unchanged from the reviewed isolated Windows repair.
The owner has a narrow follow-up correction: detached launch avoids creation of
a hidden console-host Job member, and rejection messages include raw counts.
The lifetime-accounting predicate and cleanup rules are unchanged. The manifest
records both original and candidate hashes for independent review.
Narrow `.gitattributes` rules disable newline conversion for these
files and retained fixtures so future checkouts preserve their hashes. `tests/catalog/retained-manifest.json` binds the exact retained synthetic
test sources to that evidence. Its schema version describes provenance only;
it does not version the current JSON-lines protocol.

The USDB flow reference remains
[martiinii/ultrastar-cli](https://github.com/martiinii/ultrastar-cli) (MIT), commit
`85e549cca96c578e02e235db9a13e609d82fcb95`. No terminal UI, automatic registration,
account storage or separate song database is added.

## Dependency and packaging contract

This slice is developer source only. Existing game installers/build targets do
not copy it, and no target is added here. A future package must explicitly
include both Python files together and provide a reviewed bridge and runtime
configuration. Do not treat a loose copy of `song_catalog.py` as a usable game
feature or a supported application entry point.

- Python 3 standard library only; native tests verify CPython 3.13.3 x64.
  A lower minimum supported runtime has not been established. The new test
  runner uses `hashlib.file_digest` and therefore requires Python 3.11 or newer.
- Windows process ownership requires Windows 10+ Job APIs. No breakaway or
  compatibility fallback is provided. Existing enclosing Job restrictions can
  cause a closed failure.
- Real installation, when separately reviewed/enabled, requires `yt-dlp` and
  `ffprobe` executable discovery. A future bundle must explicitly decide and
  verify tool locations and versions. The standalone FFmpeg CLI is independent
  of WorldParty's bundled FFmpeg DLL ABI.
- The offline suite needs an existing MSVC x64 compiler/Windows SDK environment
  and explicit existing `ffmpeg.exe`/`ffprobe.exe` paths. No pip, Node, Lazarus,
  package installation or authorization grant is required.
- The historical helper under `tests/catalog/retained/before-repair-20261014`
  is only an independent outer test watchdog. It must never enter runtime
  packaging. Test fixture executables, objects, logs and synthetic songs are
  generated outside the checkout; no executable fixture binaries are committed.

## Current raw protocol and limitations

The raw Python CLI is **unversioned and download-capable if explicitly run**.
It has no capabilities/status response and no built-in download-disable gate.
This patch keeps app downloads unavailable by adding no game bridge or package
entry point; it does not claim that the raw CLI itself enforces that policy.
Do not wire or launch it from the game before independent contract review.

Requests are newline-delimited JSON objects on stdin; stdout emits JSON events.
The current operations are:

| Operation | Request fields | Main event |
| --- | --- | --- |
| `login` | `user`, `password` | `login`, `ok: true` |
| `search` | `artist`, `title`, optional `offset` | `results`, `songs` |
| `details` | `id` | `details`, `id`, `links` |
| `download` | `id`, `url`, `root` | `installed`, `folder`, `id` |
| `cancel`, `quit` | none | no explicit acknowledgement |

Workers emit `idle` after success/error. An operation already running rejects a
new request. Numeric `revision` is echoed on results, details and operation
errors, but not consistently on login, installed, idle, progress or busy errors.
Errors are currently human-readable messages rather than stable error codes.

Sign-in data exists only in the current request/worker memory; cookies are in a
memory-only jar. There is no saved credential lookup or automatic registration.
The tests use no account credentials and make no catalog HTTP request.

Windows download execution uses an owned Job with a 600-second runtime bound;
probe execution uses a 15-second bound and 65,536-byte capture limit. Cleanup has
a separate 3-second deadline. Source IDs determine destination directory names.
Staging is beside the library, not inside it; an existing destination is
preserved. Publication uses exclusive target creation and writes the chart last.
This is not an atomic whole-directory rename transaction and does not promise
safety against hostile concurrent path replacement. Windows downloader progress
is indeterminate; raw tool output does not enter the JSON control stream.

## Offline reproduction

Run in an already configured MSVC x64 developer shell, supplying local paths:

```text
python -I -S -B tests/catalog/run_windows.py --output <owned-scratch-parent> --cl <absolute-cl.exe> --ffmpeg <absolute-ffmpeg.exe> --ffprobe <absolute-ffprobe.exe>
```

The runner verifies source hashes, copies the exact backend and retained tests
into a fresh directory, compiles three inert C fixtures, and runs:

- parser/current-protocol fixtures (13 tests; no network);
- deterministic launch-accounting regression (3 stdout modes);
- native process ownership (10 tests);
- repaired installer fast suite (18 tests, including actual 15-second probe timeout);
- installer boundary negative control (1 test; deliberately live inert child);
- bounded output capture (8 cases);
- accounting/error paths (3 cases repeated 3 times);
- stage cleanup (5 tests) and final cancellation (1 test);
- native FFmpeg generation and ffprobe validation of a 0.2-second synthetic WAV.

Retained test discovery substitutes inert executable fixtures. No real downloader
is invoked, and source URLs are inert strings. The runner retains receipts and
all test scratch for review. Optional repeatable `--suite` selections are
recorded in the receipt; the default runs all suites and retains failures
while continuing independent suites. It never searches for processes by name or cleans
unrelated files. The already-retained actual 600-second timeout evidence applies
only to the original owner hash, not this corrected candidate. The bounded
runner does not repeat it. Historical
malformed non-PE startup-stall and superseded unbounded-probe reproduction cases
remain excluded exactly as specified by `test_repaired_install.py`.

## Required review before a Pascal bridge

1. Add a versioned protocol with explicit capabilities/setup state and stable
   correlation/error behavior. A disabled download must reject before network,
   tool discovery, process creation or filesystem effects. This slice leaves
   that contract change for separate review.
2. Bound stream framing before reading a whole line. The current 16,384-character
   check happens after the line has already been read; it is not a memory bound.
3. Define strict field types and cancellation for HTTP operations. Login/details
   can make sequential 20-second requests; cancellation is not checked between
   them and quit joins the worker for only 25 seconds.
4. Validate real downloader compatibility separately. Short-lived descendants
   the Windows owner cannot observe are rejected; inert fixture success does
   not prove compatibility with every yt-dlp distribution.
5. Review media/source matching, staging/scanner behavior, duplicate/race policy
   and redirects against the original integration requirements. No live-source
   behavior or publication transaction is certified by these fixtures.
6. Provide native UI/config/audio isolation before any game test. Windows startup
   initializes BASS recording devices; the Linux SDL shim does not isolate it.
   `-songpath` is additive, and `-configfile` alone does not isolate all user data.

Root owns the next integration decision and all publication. This patch does not
claim a complete in-game search/download workflow.

## Current Windows result: corrected candidate for independent review

Original failure evidence is retained unchanged. Three of 18 installer cases
failed inside production probe verification: parent-exit cleanup, probe failure
and relative-path tool resolution. Original raw Job counts were not recorded.
Consequently the diagnosis proves a reproduced mechanism, not the historical
identity of every process in those three failures.

Exact live Job-member handles identified `C:\Windows\System32\conhost.exe`
beside the native probe, even when that probe created no descendants. A fixed
diagnostic batch and launch-flag comparison confirmed the extra Job member.
With first enumeration deliberately deferred until natural exit, the identical
regression produced active=0, total=2, tracked=1 and failed in all three stdout
modes with the original owner. Detached creation produced 0,1,1 and passed all
three. Accounting values are real; no process is excluded by name and the final
equality assertion is unchanged.

The first corrected full run passed every non-installer suite. Its installer
results were 14 passed and 4 failures in the outer test watchdog: the three
original production outcomes were now correct, as was ordinary success, but
the outer strict owner missed short-lived inner process lifetimes. Counts were
0,7,6 for parent-exit and 0,3,2 for probe failure, relative path and success.
These separate failures and their receipts are also preserved.

The new test-only adapter uses the existing independent historical watchdog
for parent test supervision. It leaves the actual owner module and separate
installer worker untouched, and executes the retained installer selection and
assertions verbatim. Exact descendant handles are checked while the harness is
still alive, before outer cleanup. A negative control deliberately leaves a
child alive: the retained boundary assertion rejects it before the watchdog
cleans that child. All 19 retained source files remain byte-identical.

| Latest applicable candidate validation | Result |
| --- | --- |
| Parser/current protocol | 13 passed |
| Launch accounting | 3 passed (same tests: 3 failed on original owner) |
| Native ownership | 10 passed |
| Repaired installer via independent watchdog | 18 passed |
| Boundary negative control | 1 passed |
| Bounded capture | 8 passed |
| Accounting/error paths | 3 passed, each repeated 3 times |
| Stage cleanup | 5 passed |
| Final cancellation | 1 passed |
| Native synthetic FFmpeg/ffprobe | passed |

These are 62 logical tests/cases across the corrected full run and subsequent
installer-only validation, not a claim of a new single all-suite run. The
original failures, first corrected failures and later passing results must be
reviewed together. No real downloader, game, microphone or account was used.
Interactive-console compatibility, real downloader behavior, the changed
owner's full 600-second timeout and the Pascal/UI contract remain unvalidated.

The default `git diff --check` reports the preserved extra blank line at EOF in
`tests/catalog/retained/catalog-tests/test_repaired_install.py` and a final CRLF
in the otherwise LF launch regression. Both exact tested source hashes are
preserved. Allowing CR at EOL and blank EOF lines produces no other warnings.
