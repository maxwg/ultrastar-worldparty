"""Supervise the real test game and its helper in one owned Windows Job."""
import argparse
import importlib.util
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
args = parser.parse_args()
runtime = args.runtime.resolve()
repo = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('e2e_job_owner', repo/'tools/owned_process.py')
owner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = owner
spec.loader.exec_module(owner)
os.environ['SDL_AUDIODRIVER'] = 'dummy'
result = owner.run_owned([str(runtime/'WorldPartyE2E.exe')], cwd=str(runtime),
                         timeout=95, stdout='capture', max_output_bytes=262144)
receipt = runtime/'e2e-result.txt'
print(receipt.read_text() if receipt.exists() else 'FAIL: no game receipt')
if result.reason != 'exited' or result.returncode:
    raise SystemExit('FAIL: game '+result.reason+', exit '+str(result.returncode))
trace = (runtime/'adapter-trace.txt').read_text().splitlines()
assert trace.count('login') == 1, 'Repeated account submit must not duplicate automatic sign-in'
assert trace.count('download') == 2, 'Double-click must produce only failed source + successful retry'
assert trace.count('details') == 1, 'Repeated Enter must not duplicate source lookup'
errors = [line for line in (runtime/'Error.log').read_text(errors='replace').splitlines() if 'ERROR:' in line]
assert not errors, 'Unexpected game errors: '+repr(errors)
print('PASS: exact adapter request counts, clean game error log, owned Job cleanup')
