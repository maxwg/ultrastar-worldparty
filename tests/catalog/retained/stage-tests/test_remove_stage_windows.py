"""Offline remove_stage regression tests; only this directory is writable.

Run with Python 3 on Windows. No child processes or external applications start.
Four tests use real files/Win32 handles; one explicitly injects a WinError 5.
"""
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / 'song_catalog.py'
RUN = HERE / ('run-' + uuid.uuid4().hex[:12])
RUN.mkdir()
SOURCE_HASH_BEFORE = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
SPEC = importlib.util.spec_from_file_location('stage_test_catalog', SOURCE)
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)

kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
kernel32.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                               wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                               wintypes.HANDLE)
kernel32.CreateFileW.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
kernel32.CloseHandle.restype = wintypes.BOOL
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
OBSERVATIONS = []


def identity(path):
    value = path.lstat()
    return (value.st_dev, value.st_ino)


class DirectoryLock:
    """An exact, owned handle allowing read/write sharing but not deletion."""
    def __init__(self, path):
        assert path.resolve().is_relative_to(RUN.resolve())
        # FILE_LIST_DIRECTORY, FILE_SHARE_READ|WRITE, OPEN_EXISTING,
        # FILE_FLAG_BACKUP_SEMANTICS. No network or process APIs are used.
        self.handle = kernel32.CreateFileW(str(path), 1, 3, None, 3, 0x02000000, None)
        if self.handle == INVALID_HANDLE_VALUE:
            raise ctypes.WinError(ctypes.get_last_error())
        self.closed = threading.Event()
        self.close_error = None

    def close(self):
        if self.handle is None:
            return
        if not kernel32.CloseHandle(self.handle):
            self.close_error = ctypes.WinError(ctypes.get_last_error())
            self.closed.set()
            raise self.close_error
        self.handle = None
        self.closed.set()


class RemoveStageTests(unittest.TestCase):
    def setUp(self):
        self.case = RUN / self._testMethodName
        self.case.mkdir()
        self.stage = self.case / '.worldparty-download-synthetic'
        self.stage.mkdir()
        self.ident = identity(self.stage)
        self.sibling = self.case / 'unrelated.txt'
        self.sibling.write_bytes(b'preserve unrelated sibling\x00\xff')
        self.sibling_hash = hashlib.sha256(self.sibling.read_bytes()).hexdigest()
        self.locks = []
        self.timers = []

    def tearDown(self):
        for timer in self.timers:
            timer.join(timeout=1)
            self.assertFalse(timer.is_alive(), 'lock-release timer outlived test')
        for lock in self.locks:
            lock.close()
            self.assertIsNone(lock.close_error)
        self.assertTrue(self.sibling.is_file())
        self.assertEqual(hashlib.sha256(self.sibling.read_bytes()).hexdigest(), self.sibling_hash)

    def lock(self):
        lock = DirectoryLock(self.stage)
        self.locks.append(lock)
        # Confirm the actual Windows filesystem returns sharing violation 32.
        with self.assertRaises(OSError) as error:
            self.stage.rmdir()
        self.assertEqual(error.exception.winerror, 32)
        return lock

    def observe(self, **details):
        OBSERVATIONS.append({'test': self._testMethodName, **details})

    def test_transient_real_directory_lock_releases_and_cleans(self):
        lock = self.lock()
        release = threading.Timer(0.08, lock.close)
        self.timers.append(release)
        release.start()
        started = time.monotonic()
        catalog.remove_stage(self.stage, self.ident, timeout=0.5)
        elapsed = time.monotonic() - started
        self.assertTrue(lock.closed.is_set())
        self.assertIsNone(lock.close_error)
        self.assertFalse(self.stage.exists())
        self.assertLess(elapsed, 0.8)
        self.observe(mechanism='actual CreateFileW directory handle without delete sharing',
                     preflight_winerror=32, release_after_seconds=0.08,
                     cleanup_timeout_seconds=0.5, elapsed_seconds=elapsed,
                     stage_removed=True, unrelated_sibling_preserved=True)

    def test_held_real_directory_lock_raises_within_bound(self):
        lock = self.lock()
        started = time.monotonic()
        with self.assertRaises(OSError) as error:
            catalog.remove_stage(self.stage, self.ident, timeout=0.15)
        elapsed = time.monotonic() - started
        self.assertEqual(error.exception.winerror, 32)
        self.assertGreaterEqual(elapsed, 0.13)
        self.assertLess(elapsed, 0.6)
        self.assertTrue(self.stage.is_dir())
        self.assertEqual(identity(self.stage), self.ident)
        lock.close()
        catalog.remove_stage(self.stage, self.ident, timeout=0.15)
        self.assertFalse(self.stage.exists())
        self.observe(mechanism='actual CreateFileW directory handle without delete sharing',
                     preflight_winerror=32, result_winerror=error.exception.winerror,
                     cleanup_timeout_seconds=0.15, elapsed_seconds=elapsed,
                     locked_directory_preserved=True, unrelated_sibling_preserved=True,
                     cleanup_after_exact_handle_close_succeeded=True)

    def test_replaced_directory_identity_is_preserved(self):
        original = self.case / 'original-stage-preserved'
        self.assertTrue(original.resolve().is_relative_to(RUN.resolve()))
        self.stage.rename(original)
        self.stage.mkdir()
        marker = self.stage / 'replacement-must-survive.txt'
        marker.write_text('unrelated replacement contents', encoding='utf-8')
        replacement_identity = identity(self.stage)
        self.assertNotEqual(replacement_identity, self.ident)
        started = time.monotonic()
        with self.assertRaisesRegex(ValueError, 'Staging path changed'):
            catalog.remove_stage(self.stage, self.ident, timeout=0.15)
        elapsed = time.monotonic() - started
        self.assertEqual(marker.read_text(encoding='utf-8'), 'unrelated replacement contents')
        self.assertEqual(identity(original), self.ident)
        self.assertEqual(identity(self.stage), replacement_identity)
        self.assertLess(elapsed, 0.15)
        self.observe(mechanism='actual rename and replacement directory',
                     original_identity=list(self.ident), replacement_identity=list(replacement_identity),
                     elapsed_seconds=elapsed, replacement_contents_preserved=True,
                     original_directory_preserved=True, unrelated_sibling_preserved=True)

    def test_removal_preserves_unrelated_sibling_tree(self):
        other = self.case / 'unrelated-tree'
        other.mkdir()
        (other / 'keep.txt').write_bytes(b'keep this entire sibling tree')
        (self.stage / 'owned-media.tmp').write_bytes(b'synthetic media')
        nested = self.stage / 'owned-nested'
        nested.mkdir()
        (nested / 'owned.txt').write_text('synthetic nested file', encoding='utf-8')
        catalog.remove_stage(self.stage, self.ident, timeout=0.15)
        self.assertFalse(self.stage.exists())
        self.assertEqual((other / 'keep.txt').read_bytes(), b'keep this entire sibling tree')
        self.observe(mechanism='actual synthetic owned tree and unrelated sibling tree',
                     owned_tree_removed=True, unrelated_tree_preserved=True,
                     unrelated_sibling_preserved=True)

    def test_injected_nonsharing_error_fails_immediately(self):
        marker = self.stage / 'retained.txt'
        marker.write_bytes(b'narrow injected failure preserves content')
        injected = ctypes.WinError(5)  # Explicit injection: actual ACLs unchanged.
        started = time.monotonic()
        with patch.object(catalog.shutil, 'rmtree', side_effect=injected) as remove:
            with self.assertRaises(OSError) as error:
                catalog.remove_stage(self.stage, self.ident, timeout=0.15)
            self.assertEqual(remove.call_count, 1)
        elapsed = time.monotonic() - started
        self.assertEqual(error.exception.winerror, 5)
        self.assertLess(elapsed, 0.1)
        self.assertEqual(marker.read_bytes(), b'narrow injected failure preserves content')
        self.observe(mechanism='injected ctypes.WinError(5) at shutil.rmtree only; no ACL changes',
                     injected=True, result_winerror=5, rmtree_attempts=1,
                     elapsed_seconds=elapsed, directory_contents_preserved=True,
                     unrelated_sibling_preserved=True)


if __name__ == '__main__':
    if os.name != 'nt':
        raise SystemExit('These tests require Windows.')
    stream = io.StringIO()
    began = time.monotonic()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(RemoveStageTests))
    source_hash_after = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    receipt = {
        'created_at_utc': datetime.now(timezone.utc).isoformat(),
        'python': sys.version, 'platform': sys.platform,
        'source': str(SOURCE), 'source_sha256_before': SOURCE_HASH_BEFORE,
        'source_sha256_after': source_hash_after,
        'source_unchanged_during_test': source_hash_after == SOURCE_HASH_BEFORE,
        'test_source': str(Path(__file__).resolve()),
        'test_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'run_directory': str(RUN), 'tests_run': result.testsRun,
        'failures': len(result.failures), 'errors': len(result.errors),
        'elapsed_seconds': time.monotonic() - began,
        'passed': result.wasSuccessful() and source_hash_after == SOURCE_HASH_BEFORE,
        'observations': OBSERVATIONS, 'unittest_output': stream.getvalue(),
        'scope': 'Offline synthetic files below stage-tests; exact owned directory handles only; no processes, downloads, credentials, microphone, ACL, application, repository, or existing receipt changes.',
    }
    receipt_path = RUN / 'stage-cleanup-receipt.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    manifest = {'receipt': str(receipt_path),
                'receipt_sha256': hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                'test_source': receipt['test_source'], 'test_sha256': receipt['test_sha256'],
                'installer_source': str(SOURCE), 'installer_sha256': source_hash_after}
    (RUN / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(stream.getvalue(), end='')
    print(json.dumps(manifest, indent=2))
    raise SystemExit(0 if receipt['passed'] else 1)
