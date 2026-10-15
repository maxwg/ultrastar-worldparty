# New catalog backend slice for independent review

This is a new experimental backend/test integration against commit
`db718a997da54fd5c2baa47e825d540127a6e0de`. It is not recovery of the lost checkpoint.
There is no Pascal bridge, menu entry, app launch, or installation/package change.
The game cannot invoke these tools through this patch.

## Location and provenance

`Makefile.in` already defines `USDXWP_TOOLS_DIR` as the repository's `tools`
directory. The two smallest sibling runtime files are placed there:

- `tools/song_catalog.py`, SHA-256
  `4df770e571c2d583a78bf11d10cfe60df7e8e38dcd61b0419e1cac5e321ccabb`
- `tools/owned_process.py`, SHA-256
  `9f6f62813541fa5f7e6a943e0be025727e76e697f0fa803930ee3fa702a91feb`

The catalog backend now has a protocol-v1 follow-up for independent review,
covering status, capabilities, process-local authentication state, request
correlation, and stable error codes. It is source-only and adds no UI bridge. Its prior backend hash,
`7bf4c83e1f56d4f1f4ba4e4f026b5438e184be9eab05710d18b1c00b9d1f3211`, remains
recorded as the previously reviewed source. The historical retained manifest
and past receipts remain unchanged; `tests/catalog/current-candidate-manifest.json`
separately pins the current candidate and offline contract-test source.
The owner has a narrow follow-up correction: detached launch avoids creation of
a hidden console-host Job member, and rejection messages include raw counts.
The lifetime-accounting predicate and cleanup rules are unchanged, and the
historical retained test sources remain byte-identical.
Narrow `.gitattributes` rules disable newline conversion for these
files and retained fixtures so future checkouts preserve their hashes.
`tests/catalog/retained-manifest.json` continues to bind the historical retained
synthetic test sources and prior candidate hashes. The new
`tests/catalog/current-candidate-manifest.json` pins this protocol candidate and
the offline contract test without changing what the retained manifest or older
Windows receipts claim.

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

The raw Python CLI implements JSON-lines protocol version 1 while continuing to
accept legacy unversioned requests for existing tool callers. It still has no
game bridge or package entry point. Do not wire or launch it from the game before
independent review of the bridge and remaining limits below.

A v1 request includes `"protocol_version": 1` and a per-request `request_id` of
1–64 ASCII letters, digits, or `. _ : -` characters. The new `status` operation
is v1-only and performs no catalog request. Its response reports `auth_state`
(`signed_out`, `signing_in`, or `signed_in`), `setup_state` (`login_required`,
`signing_in`, or `ready`), `session_scope: "process_memory_only"`, `busy`, and
capabilities for login, search, details, and download. Capabilities describe
adapter support; authentication may still be a prerequisite. Status is a
process-local snapshot and does not probe whether the remote session remains
valid.

Example request and initial status response:

```json
{"protocol_version":1,"request_id":"status-1","op":"status"}
{"type":"status","protocol_version":1,"request_id":"status-1","auth_state":"signed_out","setup_state":"login_required","session_scope":"process_memory_only","busy":false,"capabilities":{"login":true,"search":true,"details":true,"download":false}}
```

Every response event for an accepted, structurally valid v1 request, including
results, progress, operation errors, and `idle`, carries the same
`protocol_version` and `request_id`. Parser-level failures (malformed JSON,
missing/invalid correlation fields, unsupported protocol versions, and
oversized lines rejected before parsing) cannot always be correlated; clients
must safely treat those `error` frames as uncorrelated. V1 `cancel` and `quit`
requests with valid correlation return a `control_ack`; legacy controls remain
silent.

Cancel targets only the currently active download and reports its request ID.
The download and cancel command share an atomic publication boundary. If cancel
wins that transition, it reports `accepted: true` and `cancel_requested`; the
worker must then refuse publication. When cancellation is the reason the
operation stops, it reports `operation_cancelled`; an earlier catalog/request
failure can still take precedence. Once the
worker claims publication, cancel reports `accepted: false` with
`too_late_publication_started`; installation may complete. This makes the
acknowledgement linearizable rather than a best-effort signal: acceptance means
no target publication will begin, while a too-late response makes no promise
that installation can be stopped. When idle cancel reports
`no_active_operation`; for other active operations it reports
`operation_not_cancellable`. Quit reports
`process_exit_requested` and the active request ID (or null), signals the active
operation, and begins the existing bounded worker join; this is not a guarantee
that an in-flight HTTP request stops immediately. If publication has already
started, the download is not canceled by quit and may finish before the worker
join completes. A busy rejection is correlated to the rejected request and
includes `retryable: true`. Control acknowledgement codes are
`cancel_requested`, `too_late_publication_started`, `no_active_operation`,
`operation_not_cancellable`, and `process_exit_requested`.
V1 errors include a stable `code` and a human-readable `message`; clients should
branch on codes, not message text. Stable codes are `invalid_request`,
`request_id_required`, `invalid_request_id`, `unsupported_protocol_version`,
`protocol_version_required`, `request_too_large`, `unknown_operation`, `busy`,
`download_disabled`, `authentication_failed`, `authentication_required`,
`catalog_request_failed`,
`download_failed`, `operation_cancelled`, and `operation_failed`. Valid legacy `revision` values remain
accepted and are echoed as a compatibility alias; legacy callers may ignore the
new `code` field.

`auth_state` and `setup_state` are process-local. Status reports `signing_in`
while a login operation is active, even if this process had a previously verified
session. Search and details detect known login-required HTML markers, clear the
in-memory cookie jar and authentication marker, and fail instead of presenting
an expired-session page as an empty result. Status itself does not probe the
remote service, so it cannot discover expiry until a catalog operation sees it.

The download capability is disabled by default. The explicit `--enable-downloads`
process flag enables it; otherwise a `download`
request returns `download_disabled` before catalog detail lookup, downloader
discovery, process creation, or filesystem changes. This flag is only an explicit
adapter-level gate, not approval of a song download and not a game UI setting.
No download was enabled or attempted in the offline protocol tests.

Sign-in data exists only in the current request/worker memory; cookies are in a
memory-only jar. The status state is only an in-process marker set after the
existing login flow verifies the catalog page; nothing loads or saves an account,
credential, token, or browser cookie. There is no automatic registration. Offline
tests use fixture pages and no account credentials or catalog HTTP requests.

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

The runner checks `current-candidate-manifest.json` for current backend and
contract-test hashes, verifies `retained-manifest.json` and the unchanged retained
fixtures, copies the exact sources into a fresh directory, compiles three inert C
fixtures, and runs:

- current parser/protocol fixtures (32 tests; no network);
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

Protocol v1 now provides status/capabilities, process-local auth/setup state,
request correlation, stable error codes, and a default-off download capability.
The bridge must send a request ID per v1 request, treat `download_disabled` as
terminal, and never enable downloads merely because the capability exists.
Before a Pascal bridge or game launch, still:

1. Bound stream framing before reading a whole line. The current 16,384-character
   check happens after the line has already been read; it is not a memory bound.
2. Review remaining request validation and cancellation gaps for HTTP operations.
   Login/details can make sequential 20-second requests; cancellation is not
   checked between them and quit joins the worker for only 25 seconds.
3. Validate real downloader compatibility separately. Short-lived descendants
   the Windows owner cannot observe are rejected; inert fixture success does
   not prove compatibility with every yt-dlp distribution.
4. Review media/source matching, staging/scanner behavior, duplicate/race policy
   and redirects against the original integration requirements. No live-source
   behavior or publication transaction is certified by these fixtures.
5. Provide native UI/config/audio isolation before any game test. Windows startup
   initializes BASS recording devices; the Linux SDL shim does not isolate it.
   `-songpath` is additive, and `-configfile` alone does not isolate all user data.

Root owns the next integration decision and all publication. This patch does not
claim a complete in-game search/download workflow.

## Historical Windows result: corrected pre-protocol candidate

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

| Historical pre-protocol candidate validation | Result |
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

These are historical results for the corrected pre-protocol candidate: 62
logical tests/cases across its full run and subsequent installer-only validation,
not a claim of a new single all-suite run. The original failures, first corrected
failures and later passing results must be reviewed together. No real downloader,
game, microphone or account was used. They do not validate the later protocol-v1
candidate, whose 30-test contract suite has only been run offline in Linux; its
candidate manifest explicitly records that the native Windows suites remain
unrun.
Interactive-console compatibility, real downloader behavior, the changed
owner's full 600-second timeout and the Pascal/UI contract remain unvalidated.

The offline parser/protocol contract suite now has 32 tests, including v1 status,
control acknowledgements, session-expiry invalidation, request correlation,
stable error codes, and disabled-download cases. They are included in the Windows
runner under the `contract` selection and make no network request. The current
candidate manifest records the offline result and explicitly says its native
Windows suites have not been run. `git diff --check` is clean; the historical
retained manifest, fixtures, and earlier Windows receipts remain unchanged.
