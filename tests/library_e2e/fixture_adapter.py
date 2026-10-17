"""Offline adapter fixture for the real SDL application smoke test."""
import json
from pathlib import Path
import shutil
import sys

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
        signed_in = True
        emit('login', ok=True, auth_state='signed_in'); emit('idle')
    elif op == 'search':
        emit('results', songs=[dict(id=4242+i, artist='E2E', title='Remote Fixture '+str(i+1), language='English') for i in range(14)]); emit('idle')
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
