"""Supervise the real test game and its helper in one owned Windows Job."""
import argparse
import importlib.util
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--cancel-download', action='store_true')
parser.add_argument('--pitch-control', choices=('wrong', 'silence', 'rap'))
parser.add_argument('--verify-pitch-visual', action='store_true')
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
os.environ['ULTRASTAR_E2E_PITCH_CONTROL'] = args.pitch_control or 'normal'
result = owner.run_owned([str(runtime/'WorldPartyE2E.exe')], cwd=str(runtime),
                         timeout=95, stdout='capture', max_output_bytes=262144)
receipt = runtime/'e2e-result.txt'
print(receipt.read_text() if receipt.exists() else 'FAIL: no game receipt')
if result.reason != 'exited' or result.returncode:
    raise SystemExit('FAIL: game '+result.reason+', exit '+str(result.returncode))
if args.verify_pitch_visual and not args.cancel_download:
    from PIL import Image

    shots = sorted((runtime/'screenshots').glob('screenshot*.jpg'))
    assert len(shots) >= 3, 'Missing singing screenshots for pitch visual check'
    expected = 'mint' if args.pitch_control is None else (
        'coral' if args.pitch_control == 'wrong' else 'none')
    for shot in shots[-3:-1]:  # Two in-song captures, before sound-options capture.
        with Image.open(shot) as img:
            rgb = img.convert('RGB')
            width, height = rgb.size
            # Normalized note-lane region; excludes lyrics, score and avatars.
            sample = rgb.crop((int(width*.06), int(height*.48),
                               int(width*.96), int(height*.77)))
            raw = sample.tobytes()
            pixels = zip(raw[0::3], raw[1::3], raw[2::3])
        # Require vivid mint, not the cyan target bar or greenish JPEG
        # compression near rap's yellow scoring particles.
        mint = sum(g > 205 and g > r+65 and g > b+26 for r,g,b in pixels)
        pixels = zip(raw[0::3], raw[1::3], raw[2::3])
        coral = sum(r > 140 and r > g+50 and r > b+32 for r,g,b in pixels)
        if expected == 'mint':
            assert mint > 20 and coral < 20, f'{shot.name}: expected mint trace; got {mint}/{coral}'
        elif expected == 'coral':
            assert coral > 20 and mint < 20, f'{shot.name}: expected coral trace; got {mint}/{coral}'
        else:
            assert mint < 20 and coral < 20, f'{shot.name}: phantom pitch trace {mint}/{coral}'
    print(f'PASS: {expected} pitch visualization in both real OpenGL singing screenshots')
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
