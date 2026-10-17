#!/usr/bin/env python3
"""WorldParty JSON-lines catalog adapter; Python 3 standard library + yt-dlp.

USDB endpoint/flow reference: martiinii/ultrastar-cli (MIT), commit 85e549c.
No automatic registration, persistent credentials, or shell command construction.
Requests arrive over stdin; stdout contains JSON events, never credentials.
"""
import html
import http.cookiejar
import json
import math
import os
import signal
import stat
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

ORIGIN = 'https://usdb.animux.de'
MAX_RESPONSE = 4 * 1024 * 1024
OUTPUT_LOCK = threading.Lock()
PROTOCOL_VERSION = 1
MAX_REQUEST_ID = 64
REQUEST_ID_PATTERN = re.compile(r'[A-Za-z0-9._:-]{1,64}\Z')


def emit(kind, **data):
    with OUTPUT_LOCK:
        print(json.dumps({'type': kind, **data}, ensure_ascii=True), flush=True)


class ProtocolError(Exception):
    def __init__(self, code, message, context=None, **extra):
        super().__init__(message)
        self.code = code
        self.context = context or {}
        self.extra = extra


class AuthenticationRequiredError(ValueError):
    pass


class DownloadControl:
    """Cancellation state with an atomic, explicit publication boundary."""
    def __init__(self):
        self._lock = threading.Lock()
        self._cancelled = threading.Event()
        self._publication_started = False

    def clear(self):
        with self._lock:
            self._publication_started = False
            self._cancelled.clear()

    def is_set(self):
        return self._cancelled.is_set()

    def wait(self, timeout=None):
        return self._cancelled.wait(timeout)

    def request_cancel(self):
        """Accept cancellation only before the publication point of no return."""
        with self._lock:
            if self._publication_started:
                return False
            self._cancelled.set()
            return True

    def set(self):
        # Event-compatible alias used by owned process cleanup and legacy paths.
        return self.request_cancel()

    def begin_publication(self):
        """Atomically refuse a prior cancel or claim the target publication phase."""
        with self._lock:
            if self._cancelled.is_set():
                return False
            self._publication_started = True
            return True


def begin_publication(cancelled):
    """Enter publication, preserving legacy callers that pass threading.Event."""
    transition = getattr(cancelled, 'begin_publication', None)
    if callable(transition):
        return transition()
    # Older test/runtime callers passed an Event. Their cancellation check is
    # retained for compatibility; v1 uses DownloadControl for atomic ordering.
    return not cancelled.is_set()


def emit_error(code, message, context=None, **extra):
    emit('error', **(context or {}), code=code, message=message, **extra)


def request_context(request):
    """Validate v1 correlation while retaining legacy revision requests."""
    context = {}
    request_id = None
    if 'request_id' in request:
        request_id = request.get('request_id')
        if (not isinstance(request_id, str) or
                len(request_id) > MAX_REQUEST_ID or
                not REQUEST_ID_PATTERN.fullmatch(request_id)):
            raise ProtocolError('invalid_request_id', 'Request ID must be 1-64 ASCII letters, digits, or . _ : - characters.')
        context['request_id'] = request_id

    if 'protocol_version' in request:
        version = request.get('protocol_version')
        if type(version) is not int:
            raise ProtocolError('invalid_request', 'Protocol version must be an integer.', context)
        if version != PROTOCOL_VERSION:
            raise ProtocolError('unsupported_protocol_version', 'This catalog adapter supports protocol version 1.',
                                context, supported_protocol_version=PROTOCOL_VERSION)
        if request_id is None:
            raise ProtocolError('request_id_required', 'Protocol version 1 requests require a request ID.', context)
        context['protocol_version'] = PROTOCOL_VERSION

    # Keep the old revision correlation field as an additive compatibility alias.
    revision = request.get('revision')
    if type(revision) is int and 0 <= revision <= 2147483647:
        context['revision'] = revision
    return context, 'protocol_version' in request


def require_text(request, key, context, *, maximum=None, nonempty=False):
    value = request.get(key, '')
    if not isinstance(value, str) or (nonempty and not value) or (maximum is not None and len(value) > maximum):
        raise ProtocolError('invalid_request', 'Invalid ' + key + ' field.', context)
    return value


def require_song_id(request, context, *, versioned):
    value = request.get('id')
    if versioned:
        if type(value) is not int or value <= 0:
            raise ProtocolError('invalid_request', 'Song ID must be a positive integer.', context)
        return value
    # Older unversioned callers commonly send the ID as a decimal string.
    if type(value) not in (int, str) or not re.fullmatch(r'\d{1,10}', str(value)) or int(value) <= 0:
        raise ProtocolError('invalid_request', 'Invalid song ID.', context)
    return int(value)


def resolve_login_credentials(request, context, credentials_path):
    """Return (user, password) for a login operation without echoing secrets.

    Typed user/password fields win. Otherwise the credentials come from the
    credentials_file field, or from the adapter's own --credentials argument.
    The file holds a small JSON object {"user": ..., "pass": ...}; values are
    kept in process memory only and never returned in events."""
    user = request.get('user')
    password = request.get('password')
    if user is not None or password is not None:
        user = require_text(request, 'user', context, maximum=200, nonempty=True)
        password = require_text(request, 'password', context, maximum=1024, nonempty=True)
        return user, password
    path = request.get('credentials_file')
    if path is not None:
        if not isinstance(path, str) or not path.strip() or len(path) > 4096:
            raise ProtocolError('invalid_request', 'Invalid credentials_file field.', context)
        credentials_path = path
    if credentials_path is None:
        raise ProtocolError('missing_credentials', 'Sign-in needs user/password or a credentials file.', context)
    try:
        with open(credentials_path, 'r', encoding='utf-8', errors='strict') as handle:
            stored = json.load(handle)
    except (OSError, UnicodeDecodeError):
        raise ProtocolError('credentials_file_unreadable', 'Credentials file could not be read.', context)
    except ValueError:
        raise ProtocolError('credentials_file_invalid', 'Credentials file is not valid JSON.', context)
    if not isinstance(stored, dict):
        raise ProtocolError('credentials_file_invalid', 'Credentials file is not a JSON object.', context)
    user = stored.get('user')
    password = stored.get('pass', stored.get('password'))
    if not isinstance(user, str) or not user or len(user) > 200:
        raise ProtocolError('credentials_file_invalid', 'Credentials file has an invalid user field.', context)
    if not isinstance(password, str) or not password or len(password) > 1024:
        raise ProtocolError('credentials_file_invalid', 'Credentials file has an invalid password field.', context)
    return user, password


def login_required_page(document):
    return re.search(r'you are not logged in|please login', document, re.I) is not None


def plain(text):
    return html.unescape(re.sub(r'<[^>]*>', '', text)).strip()


def parse_search(document):
    if login_required_page(document):
        raise ValueError('USDB sign-in is required.')
    songs = []
    for row in re.findall(r'<tr\b[^>]*class=[\"\']list_tr[12][^>]*>(.*?)</tr>', document, re.S | re.I):
        match = re.search(r'show_detail\((\d+)\)', row)
        cells = re.findall(r'<td\b[^>]*>(.*?)</td>', row, re.S | re.I)
        if match and len(cells) >= 2:
            songs.append({'id': int(match[1]), 'artist': plain(cells[0]), 'title': plain(cells[1]),
                          'language': plain(cells[6]) if len(cells) > 6 else ''})
    return songs


def parse_chart(document):
    match = re.search(r'<textarea\b[^>]*>(.*?)</textarea>', document, re.S | re.I)
    if not match:
        raise ValueError('No downloadable note chart. Check USDB sign-in.')
    chart = html.unescape(match[1]).replace('\r\n', '\n').replace('\r', '\n')
    if not re.search(r'^[:*FRG] -?\d+ \d+ -?\d+ ', chart, re.M):
        raise ValueError('The downloaded chart has no playable notes.')
    if not re.search(r'^- -?\d+', chart, re.M):
        raise ValueError('This WorldParty build requires a chart with lyric line breaks.')
    if not re.search(r'^E\s*$', chart, re.M):
        raise ValueError('The downloaded chart is incomplete.')
    headers = {}
    for line in chart.splitlines():
        if line.startswith('#') and ':' in line:
            key, value = line[1:].split(':', 1)
            headers[key.strip().upper()] = value.strip()
    try:
        bpm = float(headers.get('BPM', '').replace(',', '.'))
    except ValueError:
        bpm = 0
    if not headers.get('TITLE') or not headers.get('ARTIST') or not math.isfinite(bpm) or bpm <= 0:
        raise ValueError('The chart is missing a valid title, artist or tempo.')
    return chart


def media_links(document):
    # Only exact YouTube identifiers mentioned by the source, no guessed first hit.
    links = re.findall(r'(?:youtube\.com/(?:watch\?v=|embed/)|youtu\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])', html.unescape(document))
    return list(dict.fromkeys('https://www.youtube.com/watch?v=' + x for x in links))


def prepare_chart(chart):
    # Preserve all non-file headers and their complete values, including colons.
    external = {'MP3', 'AUDIO', 'VIDEO', 'COVER', 'BACKGROUND', 'INSTRUMENTAL', 'VOCALS', 'ENCODING'}
    lines = [line for line in chart.splitlines()
             if not (line.startswith('#') and line[1:].partition(':')[0].strip().upper() in external)]
    return '#MP3:media.mp4\n#VIDEO:media.mp4\n#ENCODING:UTF8\n' + '\n'.join(lines) + '\n'


class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        if target.scheme != 'https' or target.hostname != 'usdb.animux.de':
            raise ValueError('Unexpected catalog destination.')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Catalog:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.http = urllib.request.build_opener(SameOriginRedirect(), urllib.request.HTTPCookieProcessor(self.jar))
        # This is only a process-local indication that the login flow was
        # verified. It is never loaded from or written to disk.
        self.authenticated = False
        self.search_cache = {}
        self.detail_cache = {}

    def request(self, path, data=None):
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        req = urllib.request.Request(ORIGIN + path, body, {'User-Agent': 'WorldParty-PracticeFork/1.0'})
        with self.http.open(req, timeout=20) as response:
            if urllib.parse.urlsplit(response.url).hostname != 'usdb.animux.de':
                raise ValueError('Unexpected catalog destination.')
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise ValueError('Catalog response is too large.')
            return raw.decode(response.headers.get_content_charset() or 'utf-8', errors='replace')

    def check_session_page(self, document):
        if login_required_page(document):
            self.jar.clear()
            self.authenticated = False
            raise AuthenticationRequiredError('USDB sign-in is required.')

    def login(self, user, password):
        self.authenticated = False
        self.jar.clear()
        self.search_cache.clear()
        self.detail_cache.clear()
        if not user or not password:
            raise ValueError('Enter your existing USDB username and password.')
        try:
            self.request('/index.php?link=login', {'user': user, 'pass': password, 'login': 'Login'})
            # An arbitrary session cookie alone is not proof of successful login.
            page = self.request('/?link=list')
            if login_required_page(page):
                raise ValueError('USDB sign-in could not be verified.')
            form_fields = set(re.findall(r'name\s*=\s*["\']([^"\']+)', page, re.I))
            has_catalog = {'interpret', 'title'}.issubset(form_fields) or bool(parse_search(page))
            if not has_catalog:
                raise ValueError('USDB sign-in could not be verified.')
        except Exception:
            self.jar.clear()
            self.authenticated = False
            raise
        self.authenticated = True

    def search(self, artist, title, offset=0):
        key = (artist.strip().casefold(), title.strip().casefold(), offset)
        cached = self.search_cache.get(key)
        if self.authenticated and cached and time.monotonic() - cached[0] < 300:
            return [dict(row) for row in cached[1]]
        document = self.request('/?link=list', {
            'interpret': artist[:200], 'title': title[:200], 'limit': 6,
            'start': max(0, int(offset)), 'order': 'lastchange', 'ud': 'desc'})
        self.check_session_page(document)
        rows = parse_search(document)
        if len(self.search_cache) >= 64:
            self.search_cache.pop(next(iter(self.search_cache)))
        self.search_cache[key] = (time.monotonic(), rows)
        return [dict(row) for row in rows]

    def details(self, song_id):
        song_id = int(song_id)
        if song_id <= 0:
            raise ValueError('Invalid song ID.')
        cached = self.detail_cache.get(song_id)
        if self.authenticated and cached and time.monotonic() - cached[0] < 300:
            return cached[1], list(cached[2])
        chart_page = self.request('/?link=editsongs&id=' + str(song_id))
        self.check_session_page(chart_page)
        chart = parse_chart(chart_page)
        detail_page = self.request('/?link=detail&id=' + str(song_id))
        self.check_session_page(detail_page)
        links = media_links(detail_page)
        if len(self.detail_cache) >= 64:
            self.detail_cache.pop(next(iter(self.detail_cache)))
        self.detail_cache[song_id] = (time.monotonic(), chart, links)
        return chart, links


def remove_stage(stage, identity, timeout=3):
    """Remove this invocation's staging directory after owned processes close.

    Windows process termination can release directory handles asynchronously.
    Retry only sharing/lock violations, within one deadline. Preserve a replaced
    path or reparse point. This assumes the owned stage has no concurrent writer;
    the lstat identity check is not an atomic defense against hostile path swaps.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            current = stage.lstat()
        except FileNotFoundError:
            return
        if ((current.st_dev, current.st_ino) != identity or
                not stat.S_ISDIR(current.st_mode) or
                getattr(current, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
            raise ValueError('Staging path changed; unrelated files were preserved.')
        try:
            shutil.rmtree(stage)
            return
        except OSError as error:
            remaining = deadline - time.monotonic()
            if os.name != 'nt' or getattr(error, 'winerror', None) not in (32, 33) or remaining <= 0:
                raise
            time.sleep(min(.02, remaining))


def install_song(root, song_id, chart, url, cancelled, notify=emit, downloader='yt-dlp'):
    if not re.fullmatch(r'https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}', url):
        raise ValueError('Choose an exact supported source media link.')
    song_id = int(song_id)
    if song_id <= 0:
        raise ValueError('Invalid song ID.')
    if cancelled.is_set():
        raise ValueError('Download cancelled.')
    if os.name not in ('posix', 'nt'):
        raise ValueError('Downloads require verified process-tree cleanup on this platform.')
    root = Path(root).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    target = root / ('USDB-' + str(song_id))
    if target.exists():
        raise ValueError('This chart is already installed; existing files were preserved.')
    # Stage beside the library, never inside a directory the game scans for songs.
    stage = Path(tempfile.mkdtemp(prefix='.worldparty-download-', dir=root.parent))
    stage_stat = stage.lstat()
    stage_identity = (stage_stat.st_dev, stage_stat.st_ino)
    child = None
    reader = None
    published = False
    owned_target = False
    try:
        executable = shutil.which(downloader)
        if not executable:
            raise ValueError('yt-dlp is required. Install it from its official source.')
        executable = str(Path(executable).resolve())
        probe = shutil.which('ffprobe')
        if not probe:
            raise ValueError('FFmpeg/ffprobe is required to verify playable audio.')
        probe = str(Path(probe).resolve())
        args = [executable, '--ignore-config', '--no-playlist', '--no-warnings',
                '--newline', '--progress', '--max-filesize', '500M', '-f', 'bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best',
                '--merge-output-format', 'mp4', '--ffmpeg-location', str(Path(probe).parent),
                '-o', str(stage / 'media.mp4'), '--', url]
        # No cookie/password is passed to yt-dlp. Only the public media URL.
        if os.name == 'nt':
            # -I excludes the script directory. Load the trusted sibling by
            # absolute path rather than relying on PATH or ambient sys.path.
            import importlib.util
            module_name = '_worldparty_owned_process'
            owner = sys.modules.get(module_name)
            if owner is None:
                spec = importlib.util.spec_from_file_location(module_name, Path(__file__).resolve().with_name('owned_process.py'))
                owner = importlib.util.module_from_spec(spec)
                sys.modules[module_name] = owner
                spec.loader.exec_module(owner)
            run_owned = owner.run_owned
            # Do not mix downloader output with the JSON-lines control protocol.
            # Windows shows the existing indeterminate download state.
            result = run_owned(args, cwd=str(stage), timeout=600,
                               stdout='capture', cancel=cancelled, cleanup_timeout=3, max_output_bytes=262144)
            if result.reason != 'exited':
                raise ValueError('Download cancelled or timed out.')
            returncode = result.returncode
            if returncode:
                output = result.stdout.decode('utf-8', errors='replace') if isinstance(result.stdout, bytes) else str(result.stdout)
                if 'Video unavailable' in output or 'not available' in output or 'Private video' in output:
                    raise ValueError('This source video is unavailable. Trying another USDB source if listed.')
                if 'Sign in to confirm' in output:
                    raise ValueError('YouTube requires verification for this video. Try another source.')
        else:
            child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, encoding='utf-8', errors='replace', start_new_session=True)
            def drain():
                for line in child.stdout:
                    m = re.search(r'\[download\]\s+(\d+(?:\.\d+)?)%', line)
                    if m:
                        notify('progress', percent=min(100, float(m[1])))
            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            deadline = time.monotonic() + 600
            while child.poll() is None:
                if cancelled.wait(.1) or time.monotonic() > deadline:
                    raise ValueError('Download cancelled or timed out.')
            reader.join(timeout=2)
            returncode = child.returncode
        if returncode or not (stage / 'media.mp4').is_file() or (stage / 'media.mp4').stat().st_size < 32:
            raise ValueError('Media download failed or was unavailable. No song was installed.')
        if cancelled.is_set():
            raise ValueError('Download cancelled.')
        probe_args = [probe, '-v', 'error', '-show_entries', 'stream=codec_type',
                      '-of', 'json', str(stage / 'media.mp4')]
        if os.name == 'nt':
            verification = run_owned(probe_args, cwd=str(stage), timeout=15,
                                     stdout='capture', cancel=cancelled,
                                     cleanup_timeout=3, max_output_bytes=65536)
            if verification.reason != 'exited':
                raise ValueError('Audio verification cancelled, timed out, or exceeded its output limit.')
        else:
            verification = subprocess.run(probe_args, capture_output=True, timeout=15)
        if verification.returncode or not any(s.get('codec_type') == 'audio' for s in json.loads(verification.stdout).get('streams', [])):
            raise ValueError('Downloaded media has no readable audio stream.')
        if cancelled.is_set():
            raise ValueError('Download cancelled.')
        (stage / 'song.txt').write_text(prepare_chart(chart), encoding='utf-8')
        (stage / 'source.json').write_text(json.dumps({'usdb_id': song_id, 'media': url}), encoding='utf-8')
        # Existing destination is never overwritten. IDs avoid hostile artist paths.
        if target.exists():
            raise ValueError('This chart was installed by another operation.')
        # This is the linearizable point of no return. A v1 cancel racing this
        # transition either sets the cancellation event first (and prevents any
        # target creation), or is reported too late and cannot claim success.
        if not begin_publication(cancelled):
            raise ValueError('Download cancelled.')
        target.mkdir()  # exclusive creation: even an existing empty folder is preserved
        owned_target = True
        # Publish the chart last; the scanner cannot see a song before media exists.
        for name in ('media.mp4', 'source.json', 'song.txt'):
            (stage / name).rename(target / name)
        published = True
        return str(target)
    finally:
        if child is not None:
            # The downloader owns a new process group. Reap descendants even if
            # its leader exited first; inherited stdout must not outlive cleanup.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=3)
        if reader is not None:
            reader.join(timeout=2)
        if child is not None and child.stdout is not None:
            child.stdout.close()
        if owned_target and not published:
            for name in ('song.txt', 'source.json', 'media.mp4'):
                (target / name).unlink(missing_ok=True)
            try:
                target.rmdir()
            except OSError:
                pass  # preserve any unrelated files added by another process
        remove_stage(stage, stage_identity)


def operation_error_code(op, cancelled):
    if op == 'download' and cancelled.is_set():
        return 'operation_cancelled'
    if op == 'login':
        return 'authentication_failed'
    if op in ('search', 'details'):
        return 'catalog_request_failed'
    if op == 'download':
        return 'download_failed'
    return 'operation_failed'


def main(downloads_enabled=False, credentials_path=None):
    downloads_enabled = downloads_enabled is True
    if credentials_path is not None:
        if not isinstance(credentials_path, str) or not credentials_path.strip() or len(credentials_path) > 4096:
            raise SystemExit('--credentials needs a readable path of at most 4096 characters.')
    catalog = Catalog()
    cancelled = DownloadControl()
    worker = None
    active = False
    active_operation = None
    active_context = {}
    ready = threading.Lock()

    def run(request, context, versioned):
        nonlocal active, active_operation, active_context
        op = request.get('op')
        try:
            if op == 'login':
                user, password = resolve_login_credentials(request, context, credentials_path)
                catalog.login(user, password)
                emit('login', **context, ok=True, auth_state='signed_in')
            elif op == 'search':
                maximum = 200 if versioned else 16384
                artist = require_text(request, 'artist', context, maximum=maximum)
                title = require_text(request, 'title', context, maximum=maximum)
                offset = request.get('offset', 0)
                if versioned:
                    if type(offset) is not int or not 0 <= offset <= 2147483647:
                        raise ProtocolError('invalid_request', 'Offset must be a non-negative integer.', context)
                else:
                    try:
                        offset = int(offset)
                    except (TypeError, ValueError, OverflowError):
                        raise ProtocolError('invalid_request', 'Invalid offset.', context)
                    if not 0 <= offset <= 2147483647:
                        raise ProtocolError('invalid_request', 'Invalid offset.', context)
                query = require_text(request, 'query', context, maximum=200)
                if query.strip():
                    # One search box matches either artist or title, like the library.
                    by_id = {}
                    for row in catalog.search(query, '', offset) + catalog.search('', query, offset):
                        by_id.setdefault(row['id'], row)
                    songs = list(by_id.values())[:30]
                else:
                    songs = catalog.search(artist, title, offset)
                emit('results', **context, songs=songs)
            elif op == 'details':
                song_id = require_song_id(request, context, versioned=versioned)
                _, links = catalog.details(song_id)
                event_id = song_id if versioned else request.get('id')
                emit('details', **context, id=event_id, links=links)
            elif op == 'download':
                # The raw adapter remains non-downloading unless an explicit
                # launch flag opts in. Reject before details/network or install.
                if not downloads_enabled:
                    raise ProtocolError('download_disabled', 'Downloads are disabled for this adapter session.', context)
                song_id = require_song_id(request, context, versioned=versioned)
                url = require_text(request, 'url', context, maximum=512, nonempty=True)
                root = require_text(request, 'root', context, maximum=4096, nonempty=True)
                chart, links = catalog.details(song_id)
                if cancelled.is_set():
                    raise ValueError('Download cancelled.')
                if url not in links:
                    raise ValueError('Selected media no longer matches the catalog source.')
                notify = lambda kind, **data: emit(kind, **context, **data)
                folder = install_song(root, song_id, chart, url, cancelled, notify=notify)
                event_id = song_id if versioned else request.get('id')
                emit('installed', **context, folder=folder, id=event_id)
            elif op in ('cancel', 'quit'):
                # These legacy control requests intentionally have no response.
                return
            else:
                raise ProtocolError('unknown_operation', 'Unknown operation.', context)
        except AuthenticationRequiredError as error:
            emit_error('authentication_required', str(error), context)
        except ProtocolError as error:
            emit_error(error.code, str(error), error.context, **error.extra)
        except ValueError as error:
            emit_error(operation_error_code(op, cancelled), str(error), context)
        except Exception:
            # Never serialize server responses, cookies, request bodies or credentials.
            emit_error(operation_error_code(op, cancelled), 'Catalog request failed. Check connection and sign-in.', context)
        finally:
            with ready:
                active = False
                active_operation = None
                active_context = {}
                emit('idle', **context)

    def status(context):
        with ready:
            busy = active
            running = active_operation
        if busy and running == 'login':
            auth_state = 'signing_in'
            setup_state = 'signing_in'
        elif catalog.authenticated:
            auth_state = 'signed_in'
            setup_state = 'ready'
        else:
            auth_state = 'signed_out'
            setup_state = 'login_required'
        emit('status', **context,
             auth_state=auth_state,
             setup_state=setup_state,
             session_scope='process_memory_only',
             busy=busy,
             capabilities={'login': True, 'search': True, 'details': True,
                           'download': bool(downloads_enabled)})

    try:
        for line in sys.stdin:
            if len(line) > 16384:
                emit_error('request_too_large', 'Request too large.')
                continue
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ProtocolError('invalid_request', 'Invalid request.')
                context, versioned = request_context(request)
            except ProtocolError as error:
                emit_error(error.code, str(error), error.context, **error.extra)
                continue
            except (ValueError, TypeError):
                emit_error('invalid_request', 'Invalid request.')
                continue

            op = request.get('op')
            if op == 'status':
                if not versioned:
                    emit_error('protocol_version_required', 'Status requires protocol version 1 and a request ID.', context)
                else:
                    status(context)
                continue
            if op in ('cancel', 'quit'):
                if not versioned:
                    cancelled.set()
                    if op == 'quit':
                        break
                    continue
                with ready:
                    target_request_id = active_context.get('request_id') if active else None
                    if op == 'cancel':
                        can_cancel = active and active_operation == 'download'
                        if can_cancel:
                            can_cancel = cancelled.request_cancel()
                        emit('control_ack', **context, command='cancel',
                             accepted=can_cancel, target_request_id=target_request_id,
                             code=('cancel_requested' if can_cancel else
                                   'too_late_publication_started' if active and active_operation == 'download' else
                                   'operation_not_cancellable' if active else 'no_active_operation'),
                             semantics='cancel_before_publication')
                        continue
                    if active:
                        cancelled.set()
                    emit('control_ack', **context, command='quit', accepted=True,
                         target_request_id=target_request_id,
                         code='process_exit_requested',
                         semantics='exit_after_bounded_worker_join')
                if op == 'quit':
                    break
                continue
            with ready:
                if active:
                    emit_error('busy', 'An operation is already running.', context, retryable=True)
                    continue
                active = True
                active_operation = op
                active_context = context
                cancelled.clear()
                worker = threading.Thread(target=run, args=(request, context, versioned), daemon=True)
                worker.start()
    finally:
        cancelled.set()
        if worker:
            worker.join(timeout=25)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='WorldParty JSON-lines catalog adapter.')
    parser.add_argument('--enable-downloads', action='store_true',
                        help='Explicitly enable the download capability for this process.')
    parser.add_argument('--credentials', default=None,
                        help='Path to a JSON credentials file {"user": ..., "pass": ...}; '
                             'sign-in requests without typed fields use this file. '
                             'The file content stays in process memory and never appears in events.')
    args = parser.parse_args()
    main(downloads_enabled=args.enable_downloads, credentials_path=args.credentials)
