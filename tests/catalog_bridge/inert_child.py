#!/usr/bin/env python3
"""Offline child-process fixture. It performs no network or filesystem I/O."""
import json
import sys

if len(sys.argv) != 1:
    raise SystemExit('unexpected child arguments')

for raw in sys.stdin:
    request = json.loads(raw)
    request_id = request.get('request_id')
    if request.get('op') == 'status':
        print(json.dumps({
            'type': 'status', 'protocol_version': 1,
            'request_id': request_id, 'auth_state': 'signed_out',
            'setup_state': 'login_required',
            'session_scope': 'process_memory_only', 'busy': False,
            'capabilities': {'login': True, 'search': True, 'details': True,
                             'download': False},
        }), flush=True)
    elif request.get('op') == 'quit':
        print(json.dumps({
            'type': 'control_ack', 'protocol_version': 1,
            'request_id': request_id, 'command': 'quit', 'accepted': True,
            'target_request_id': None, 'code': 'process_exit_requested',
        }), flush=True)
        break
