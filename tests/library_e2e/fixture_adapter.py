"""Offline adapter fixture for the real SDL application smoke test."""
import json
from pathlib import Path
import shutil
import sys
import time

signed_in = False
downloads = 0
root = Path(__file__).resolve().parent
trace = (root / 'adapter-trace.txt').open('w', encoding='utf-8')
for line in sys.stdin:
    request = json.loads(line)
    op = request['op']
    trace.write(op + '\n'); trace.flush()
    context = {key:request[key] for key in ('protocol_version', 'request_id')}
    def emit(kind, **data):
        print(json.dumps(dict(type=kind, **context, **data)), flush=True)
    if op == 'status':
        emit('status', auth_state='signed_in' if signed_in else 'signed_out', session_scope='process_memory_only', busy=False, capabilities=dict(login=True,search=True,details=True,download=True))
    elif op == 'login':
        # Keep login in flight until the game has dispatched repeated submits.
        deadline = time.monotonic() + 30
        while not (root / 'release-login').exists():
            if time.monotonic() > deadline:
                raise RuntimeError('Game never released the login fixture')
            time.sleep(0.01)
        signed_in = True
        emit('login', ok=True, auth_state='signed_in'); emit('idle')
    elif op == 'search':
        songs = [dict(id=4242+i, artist='E2E', title='Remote Fixture '+str(i+1), language='English') for i in range(14)]
        # Keep the original fourteen rows and IDs first, then exercise both
        # local/remote and remote/remote title deduplication.
        songs.extend([
            dict(id=4256, artist='E2E', title='Local Fixture', language='English'),
            dict(id=4257, artist='E2E', title='Remote Fixture 1', language='English'),
        ])
        emit('results', songs=songs); emit('idle')
    elif op == 'details':
        emit('details', id=request['id'], links=['https://www.youtube.com/watch?v=AAAAAAAAAAA','https://www.youtube.com/watch?v=BBBBBBBBBBB']); emit('idle')
    elif op == 'download':
        downloads += 1
        if downloads == 1:
            emit('error', code='download_failed', message='Fixture source unavailable.'); emit('idle')
        else:
            folder = Path(request['root'])/('USDB-'+str(request['id']))
            folder.mkdir(parents=True)
            shutil.copyfile(root/'fixture.mp4', folder/'media.mp4')
            (folder/'song.txt').write_text((root/'fixture.txt').read_text(), encoding='utf-8')
            emit('installed', id=request['id'], folder=str(folder)); emit('idle')
    elif op == 'quit':
        break
