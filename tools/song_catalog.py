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


def emit(kind, **data):
    with OUTPUT_LOCK:
        print(json.dumps({'type': kind, **data}, ensure_ascii=True), flush=True)


def plain(text):
    return html.unescape(re.sub(r'<[^>]*>', '', text)).strip()


def parse_search(document):
    if 'You are not logged in' in document:
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

    def login(self, user, password):
        self.jar.clear()
        if not user or not password:
            raise ValueError('Enter your existing USDB username and password.')
        self.request('/index.php?link=login', {'user': user, 'pass': password, 'login': 'Login'})
        # An arbitrary session cookie alone is not proof of successful login.
        page = self.request('/?link=list')
        form_fields = set(re.findall(r'name\s*=\s*[\"\']([^\"\']+)', page, re.I))
        has_catalog = {'interpret', 'title'}.issubset(form_fields) or bool(parse_search(page))
        if 'Please login' in page or not has_catalog:
            self.jar.clear()
            raise ValueError('USDB sign-in could not be verified.')

    def search(self, artist, title, offset=0):
        return parse_search(self.request('/?link=list', {
            'interpret': artist[:200], 'title': title[:200], 'limit': 6,
            'start': max(0, int(offset)), 'order': 'lastchange', 'ud': 'desc'}))

    def details(self, song_id):
        song_id = int(song_id)
        if song_id <= 0:
            raise ValueError('Invalid song ID.')
        chart = parse_chart(self.request('/?link=editsongs&id=' + str(song_id)))
        links = media_links(self.request('/?link=detail&id=' + str(song_id)))
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
                '--newline', '--progress', '--max-filesize', '500M', '-f', 'best[ext=mp4]',
                '-o', str(stage / 'media.mp4'), '--', url]
        # No cookie/password is passed to yt-dlp. Only the public media URL.
        if os.name == 'nt':
            from owned_process import run_owned
            # Do not mix downloader output with the JSON-lines control protocol.
            # Windows shows the existing indeterminate download state.
            result = run_owned(args, cwd=str(stage), timeout=600,
                               stdout='devnull', cancel=cancelled, cleanup_timeout=3)
            if result.reason != 'exited':
                raise ValueError('Download cancelled or timed out.')
            returncode = result.returncode
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
        if cancelled.is_set():
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


def main():
    catalog = Catalog()
    cancelled = threading.Event()
    worker = None
    active = False
    ready = threading.Lock()
    def run(request):
        nonlocal active
        # Echo only a bounded numeric correlation value, never request content.
        revision = request.get('revision')
        context = {'revision': revision} if type(revision) is int and 0 <= revision <= 2147483647 else {}
        try:
            op = request.get('op')
            if op == 'login':
                catalog.login(request.get('user', ''), request.get('password', ''))
                emit('login', ok=True)
            elif op == 'search':
                emit('results', **context, songs=catalog.search(request.get('artist', ''), request.get('title', ''), request.get('offset', 0)))
            elif op == 'details':
                chart, links = catalog.details(request['id'])
                emit('details', **context, id=request['id'], links=links)
            elif op == 'download':
                chart, links = catalog.details(request['id'])
                url = request.get('url', '')
                if url not in links:
                    raise ValueError('Selected media no longer matches the catalog source.')
                folder = install_song(request['root'], request['id'], chart, url, cancelled)
                emit('installed', folder=folder, id=request['id'])
            else:
                raise ValueError('Unknown operation.')
        except ValueError as error:
            emit('error', **context, message=str(error))
        except Exception:
            # Never serialize server responses, cookies, request bodies or credentials.
            emit('error', **context, message='Catalog request failed. Check connection and sign-in.')
        finally:
            with ready:
                active = False
                emit('idle')
    try:
        for line in sys.stdin:
            if len(line) > 16384:
                emit('error', message='Request too large.')
                continue
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError()
            except (ValueError, TypeError):
                emit('error', message='Invalid request.')
                continue
            if request.get('op') in ('cancel', 'quit'):
                cancelled.set()
                if request['op'] == 'quit':
                    break
            else:
                with ready:
                    if active:
                        emit('error', message='An operation is already running.')
                        continue
                    active = True
                    cancelled.clear()
                    worker = threading.Thread(target=run, args=(request,), daemon=True)
                    worker.start()
    finally:
        cancelled.set()
        if worker:
            worker.join(timeout=25)


if __name__ == '__main__':
    main()
