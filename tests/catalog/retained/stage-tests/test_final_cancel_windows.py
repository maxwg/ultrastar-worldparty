"""One offline integration test of the final cancellation/publication boundary.

The real installer and Job owner execute the inert native fixture. Only external
tool lookup and an explicitly timed prepare_chart wrapper are substituted.
"""
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import threading
import time
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parent
sys.path.insert(0, str(PACKAGE))
import song_catalog as catalog
import owned_process

RUN = HERE / ('final-cancel-' + uuid.uuid4().hex[:12])
RUN.mkdir()
SOURCE_PATHS = {
    'installer': PACKAGE / 'song_catalog.py',
    'owner': PACKAGE / 'owned_process.py',
    'native_fixture_c': PACKAGE / 'catalog-tests' / 'native_fixture.c',
    'native_fixture_exe': PACKAGE / 'catalog-tests' / 'native_fixture.exe',
    'test': Path(__file__).resolve(),
}


def hashes():
    return {name: hashlib.sha256(path.read_bytes()).hexdigest()
            for name, path in SOURCE_PATHS.items()}


BEFORE = hashes()
OBSERVATIONS = {}


class FinalCancellationTest(unittest.TestCase):
    def test_cancel_after_preparing_chart_prevents_publication(self):
        case = RUN / 'synthetic-case'
        case.mkdir()
        tool_dir = case / 'tools'
        tool_dir.mkdir()
        root = case / 'Songs & [local] ü'
        root.mkdir()
        existing = root / 'USDB-999'
        existing.mkdir()
        marker = existing / 'preserve.txt'
        marker.write_bytes(b'unrelated existing synthetic song')
        sibling = case / 'unrelated.txt'
        sibling.write_bytes(b'unrelated sibling data')
        for name in ('downloader.exe', 'ffprobe.exe'):
            shutil.copyfile(SOURCE_PATHS['native_fixture_exe'], tool_dir / name)
            self.assertEqual(hashlib.sha256((tool_dir / name).read_bytes()).hexdigest(),
                             BEFORE['native_fixture_exe'])
        (tool_dir / 'mode.txt').write_text('success', encoding='utf-8')
        target = root / 'USDB-401'
        cancelled = threading.Event()
        prepare_observations = []
        original_prepare = catalog.prepare_chart
        audit_events = []

        def audit(event, args):
            if event not in ('os.mkdir', 'os.rename'):
                return
            first = args[0]
            if not isinstance(first, (str, bytes)):
                return
            path = Path(os.fsdecode(first)).absolute()
            if path.is_relative_to(case):
                audit_events.append({'event': event, 'path': str(path),
                                     'destination': os.fsdecode(args[1]) if event == 'os.rename' else None})

        sys.addaudithook(audit)  # Read-only evidence; no filesystem API mocking.

        def fixture_which(name):
            if name == 'yt-dlp':
                return str(tool_dir / 'downloader.exe')
            if name == 'ffprobe':
                return str(tool_dir / 'ffprobe.exe')
            raise AssertionError('Unexpected executable lookup')

        def prepare_then_cancel(chart):
            prepared = original_prepare(chart)
            stages = list(case.glob('.worldparty-download-*'))
            prepare_observations.append({
                'original_prepare_returned': True,
                'target_exists_before_cancellation': target.exists(),
                'stage_count': len(stages),
                'stage_media_exists': len(stages) == 1 and (stages[0] / 'media.mp4').is_file(),
                'event_was_set': cancelled.is_set(),
            })
            cancelled.set()  # Explicit synthetic timing: immediately after prepare_chart returns.
            return prepared

        chart = '#TITLE:Synthetic local fixture\n#ARTIST:Test\n#BPM:120\n: 0 4 60 la\n- 4\nE\n'
        url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'
        started = time.monotonic()
        with patch.object(catalog.shutil, 'which', side_effect=fixture_which), \
                patch.object(catalog, 'prepare_chart', side_effect=prepare_then_cancel):
            with self.assertRaisesRegex(ValueError, '^Download cancelled\\.$') as error:
                catalog.install_song(root, 401, chart, url, cancelled)
        elapsed = time.monotonic() - started
        self.assertTrue(cancelled.is_set())
        self.assertEqual(len(prepare_observations), 1)
        self.assertEqual(prepare_observations[0], {
            'original_prepare_returned': True,
            'target_exists_before_cancellation': False,
            'stage_count': 1, 'stage_media_exists': True, 'event_was_set': False,
        })
        self.assertFalse(target.exists())
        self.assertEqual(list(case.glob('.worldparty-download-*')), [])
        self.assertEqual(sorted(path.name for path in root.iterdir()), ['USDB-999'])
        self.assertEqual(marker.read_bytes(), b'unrelated existing synthetic song')
        self.assertEqual(sibling.read_bytes(), b'unrelated sibling data')
        self.assertFalse(any(event['event'] == 'os.mkdir' and Path(event['path']) == target
                             for event in audit_events), 'Destination mkdir was attempted')
        self.assertFalse(any(event['event'] == 'os.rename' and event['destination'] and
                             Path(event['destination']).is_relative_to(target)
                             for event in audit_events), 'Publication rename was attempted')
        fixture_pids = {name: int((tool_dir / name).read_text(encoding='ascii'))
                        for name in ('parent.pid', 'probe.pid')}
        self.assertNotEqual(fixture_pids['parent.pid'], fixture_pids['probe.pid'])
        self.assertEqual(hashes(), BEFORE)
        OBSERVATIONS.update({
            'elapsed_seconds': elapsed, 'error_type': type(error.exception).__name__,
            'error_message': str(error.exception), 'cancelled': cancelled.is_set(),
            'synthetic_event_timing': 'prepare_chart wrapper sets Event immediately after original returns',
            'prepare_observations': prepare_observations,
            'destination_absent': True, 'destination_mkdir_attempted': False,
            'publication_rename_attempted': False, 'staging_removed': True,
            'unrelated_existing_song_preserved': True, 'unrelated_sibling_preserved': True,
            'fixture_process_ids': fixture_pids, 'filesystem_audit': audit_events,
            'real_installer': catalog.__file__, 'real_owner': owned_process.__file__,
            'subprocess_or_owner_mocking': False,
        })


if __name__ == '__main__':
    if os.name != 'nt':
        raise SystemExit('This test requires Windows.')
    stream = io.StringIO()
    started = time.monotonic()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(FinalCancellationTest))
    after = hashes()
    receipt = {
        'created_at_utc': datetime.now(timezone.utc).isoformat(),
        'python': sys.version, 'platform': sys.platform, 'run_directory': str(RUN),
        'source_paths': {name: str(path) for name, path in SOURCE_PATHS.items()},
        'sha256_before': BEFORE, 'sha256_after': after,
        'sources_unchanged_during_test': BEFORE == after,
        'tests_run': result.testsRun, 'failures': len(result.failures),
        'errors': len(result.errors), 'elapsed_seconds': time.monotonic() - started,
        'passed': result.wasSuccessful() and BEFORE == after,
        'observations': OBSERVATIONS, 'unittest_output': stream.getvalue(),
        'scope': 'Only new stage-tests files; offline inert native copies; actual installer/owner; no production source, old test, receipt, downloader, network, credential, microphone, or user application changes.',
    }
    receipt_path = RUN / 'final-cancel-receipt.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    manifest = {'receipt': str(receipt_path),
                'receipt_sha256': hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                'source_paths': receipt['source_paths'], 'sha256': after}
    (RUN / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(stream.getvalue(), end='')
    print(json.dumps(manifest, indent=2))
    raise SystemExit(0 if receipt['passed'] else 1)
