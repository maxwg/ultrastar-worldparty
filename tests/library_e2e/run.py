"""Supervise the real test game and its helper in one owned Windows Job."""
import argparse
import importlib.util
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--cancel-download', action='store_true')
args = parser.parse_args()
runtime = args.runtime.resolve()
repo = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('e2e_job_owner', repo/'tools/owned_process.py')
owner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = owner
spec.loader.exec_module(owner)
os.environ['SDL_AUDIODRIVER'] = 'dummy'
os.environ.pop('ULTRASTAR_E2E_RESTART', None)
os.environ['ULTRASTAR_E2E_CANCEL'] = '1' if args.cancel_download else '0'
result = owner.run_owned([str(runtime/'WorldPartyE2E.exe')], cwd=str(runtime),
                         timeout=95, stdout='capture', max_output_bytes=262144)
receipt = runtime/'e2e-result.txt'
print(receipt.read_text() if receipt.exists() else 'FAIL: no game receipt')
if result.reason != 'exited' or result.returncode:
    raise SystemExit('FAIL: game '+result.reason+', exit '+str(result.returncode))
trace = (runtime/'adapter-trace.txt').read_text().splitlines()
assert trace.count('login') == (2 if args.cancel_download else 1), 'Unexpected sign-in request count'
assert trace.count('download') == (1 if args.cancel_download else 2), 'Unexpected download request count'
assert trace.count('details') == 1, 'Repeated Enter must not duplicate source lookup'
errors = [line for line in (runtime/'Error.log').read_text(errors='replace').splitlines() if 'ERROR:' in line]
assert not errors, 'Unexpected game errors: '+repr(errors)
print('PASS: exact adapter request counts, clean game error log, owned Job cleanup')
if args.cancel_download:
    assert not list((runtime/'songs').glob('USDB-*')), 'Cancelled download was installed'
    raise SystemExit(0)
receipt.rename(runtime/'e2e-first-launch.txt')
os.environ['ULTRASTAR_E2E_RESTART'] = '1'
result = owner.run_owned([str(runtime/'WorldPartyE2E.exe')], cwd=str(runtime),
                         timeout=30, stdout='capture', max_output_bytes=262144)
print(receipt.read_text() if receipt.exists() else 'FAIL: no restart receipt')
assert result.reason == 'exited' and result.returncode == 0, 'Library persistence restart failed'
errors = [line for line in (runtime/'Error.log').read_text(errors='replace').splitlines() if 'ERROR:' in line]
assert not errors, 'Unexpected restart game errors: '+repr(errors)
