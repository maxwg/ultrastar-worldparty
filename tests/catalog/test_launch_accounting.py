"""Deterministic observation-gap regression for console-free owned tool launch.

The fixture itself creates no descendants. Delay the first member enumeration
until the root and all natural Job members have exited, while retaining the root
handle returned at creation. No accounting values or assertions are substituted.
An unnecessary short-lived console host must not make this single-tool call fail.
"""
import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import time
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--backend', type=Path, required=True)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
source = args.backend / 'owned_process.py'
spec = importlib.util.spec_from_file_location('launch_regression_owner', source)
owner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = owner
spec.loader.exec_module(owner)
RECORDS = []

class LaunchAccountingTests(unittest.TestCase):
    def check_mode(self, mode):
        case = args.output / mode
        case.mkdir()
        exe = case / 'ffprobe.exe'
        shutil.copyfile(args.fixture, exe)
        (case / 'mode.txt').write_bytes(b'success')
        original_track, original_cleanup = owner._track_members, owner._cleanup_job
        record = {'mode':mode,'expected':{'active':0,'total':1,'tracked':1,'returncode':0,'reason':'exited'},'observations':[]}
        delayed = False
        def delay_first_enumeration(job, tracked):
            nonlocal delayed
            if not delayed:
                delayed = True
                self.assertEqual(len(tracked), 1, 'Creation must retain the exact root handle')
                root_handle = next(iter(tracked.values()))
                self.assertEqual(owner._wait(root_handle, 1500), owner.WAIT_OBJECT_0, 'Synthetic root must exit naturally')
                deadline = time.monotonic() + 1.5
                while True:
                    actual = owner._accounting(job)
                    if not actual.ActiveProcesses:
                        break
                    if time.monotonic() >= deadline:
                        raise AssertionError('Natural Job exit exceeded the diagnostic deadline')
                    time.sleep(.001)
                record['observation_gap_end']={'active':int(actual.ActiveProcesses),'total':int(actual.TotalProcesses),'tracked':len(tracked),'root_handle_state':owner._wait(root_handle,0)}
            original_track(job, tracked)
        def record_cleanup(job, tracked, timeout):
            try:
                return original_cleanup(job, tracked, timeout)
            finally:
                actual = owner._accounting(job)
                record['actual_final']={'active':int(actual.ActiveProcesses),'total':int(actual.TotalProcesses),'tracked':len(tracked),'all_retained_handles_signaled':all(owner._wait(handle,0)==owner.WAIT_OBJECT_0 for handle in tracked.values())}
        owner._track_members, owner._cleanup_job = delay_first_enumeration, record_cleanup
        started = time.monotonic()
        result = None
        error = None
        try:
            result = owner.run_owned([str(exe.resolve())], cwd=str(case.resolve()), timeout=4, stdout=mode, cleanup_timeout=1)
            record['result']=asdict(result)
        except Exception as caught:
            error = caught
            record['error']={'type':type(caught).__name__,'message':str(caught)}
        finally:
            owner._track_members, owner._cleanup_job = original_track, original_cleanup
            record['elapsed_seconds']=time.monotonic()-started
            RECORDS.append(record)
        self.assertIsNone(error, 'A tool without descendants must survive a late first observation: '+repr(error))
        self.assertEqual(result.reason,'exited')
        self.assertEqual(result.returncode,0)
        self.assertEqual(record['actual_final'],{'active':0,'total':1,'tracked':1,'all_retained_handles_signaled':True})
        if mode=='capture':
            self.assertEqual(json.loads(result.stdout),{'streams':[{'codec_type':'audio'}]})
        else:
            self.assertEqual(result.stdout,'')
        self.assertLess(record['elapsed_seconds'],3.5)

    def test_capture_with_delayed_first_observation(self):
        self.check_mode('capture')

    def test_devnull_with_delayed_first_observation(self):
        self.check_mode('devnull')

    def test_redirected_inherit_with_delayed_first_observation(self):
        self.check_mode('inherit')

stream = io.StringIO()
result = unittest.TextTestRunner(stream=stream,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LaunchAccountingTests))
receipt = {'time_utc':datetime.now(timezone.utc).isoformat(),'source':str(source),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'test_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'fixture_sha256':hashlib.sha256(args.fixture.read_bytes()).hexdigest(),'tests_run':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful(),'scope':'New deterministic observation-gap regression; native API accounting unchanged, no real downloader or original installer-case retry.','records':RECORDS,'unittest_output':stream.getvalue()}
path=args.output/'launch-accounting-receipt.json'
path.write_bytes((json.dumps(receipt,indent=2)+'\n').encode())
print(stream.getvalue(),end='')
print(json.dumps({'receipt':str(path),'passed':receipt['passed'],'tests_run':result.testsRun,'failures':len(result.failures),'errors':len(result.errors)}))
raise SystemExit(0 if receipt['passed'] else 1)
