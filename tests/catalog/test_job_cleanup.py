"""Focused Windows cleanup and merged-output regressions; no network."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import subprocess
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tested_job_owner', Path(__file__).resolve().parents[2] / 'tools/owned_process.py')
owner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = owner
spec.loader.exec_module(owner)

class CleanupTests(unittest.TestCase):
    def test_hidden_console_is_inherited_without_visible_windows(self):
        probe = '''import ctypes as C, json, subprocess, sys
k = C.WinDLL('kernel32')
u = C.WinDLL('user32')
k.GetConsoleWindow.restype = C.c_void_p
u.IsWindowVisible.argtypes = [C.c_void_p]
window = k.GetConsoleWindow()
state = {'window': window, 'visible': bool(u.IsWindowVisible(window))}
'''
        child = probe + "print(json.dumps(state))"
        parent = probe + (
            "inherited = json.loads(subprocess.check_output("
            "[sys.executable, '-I', '-S', '-c', " + repr(child) + "], text=True))\n"
            "print(json.dumps({'root': state, 'child': inherited}))"
        )
        with tempfile.TemporaryDirectory() as folder:
            result = owner.run_owned([sys.executable, '-I', '-S', '-c', parent],
                                     cwd=folder, timeout=10, stdout='capture',
                                     hidden_console=True)
        self.assertEqual((result.reason, result.returncode), ('exited', 0))
        windows = json.loads(result.stdout)
        self.assertTrue(windows['root']['window'], 'The wrapper needs a console to inherit')
        self.assertEqual(windows['root']['window'], windows['child']['window'])
        self.assertFalse(windows['root']['visible'])
        self.assertFalse(windows['child']['visible'])

    def test_exited_short_lived_children_do_not_fail_cleanup(self):
        with patch.object(owner, '_track_members'), patch.object(owner, '_stop_job'), patch.object(owner, '_accounting', return_value=SimpleNamespace(ActiveProcesses=0, TotalProcesses=9)):
            owner._cleanup_job(None, {}, 1)

    def test_active_children_still_fail_cleanup(self):
        with patch.object(owner, '_track_members'), patch.object(owner, '_stop_job'), patch.object(owner, '_accounting', return_value=SimpleNamespace(ActiveProcesses=1, TotalProcesses=9)):
            with self.assertRaises(RuntimeError):
                owner._cleanup_job(None, {}, 1)

    def test_capture_includes_diagnostic_stderr(self):
        with tempfile.TemporaryDirectory() as folder:
            result = owner.run_owned([sys.executable, '-I', '-S', '-c', "import sys; print('out'); print('diagnostic', file=sys.stderr)"], cwd=folder, timeout=10, stdout='capture')
            self.assertEqual(result.reason, 'exited')
            self.assertEqual(result.returncode, 0)
            self.assertIn('out', result.stdout)
            self.assertIn('diagnostic', result.stdout)

    def test_cancellation_cleans_descendants_and_preserves_unrelated_process(self):
        sentinel = subprocess.Popen([sys.executable, '-I', '-S', '-c', 'import time; time.sleep(30)'], creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            with tempfile.TemporaryDirectory() as folder:
                cancelled = threading.Event()
                timer = threading.Timer(0.5, cancelled.set)
                timer.start()
                try:
                    result = owner.run_owned([sys.executable, '-I', '-S', '-c', "import subprocess,sys,time; subprocess.Popen([sys.executable,'-I','-S','-c','import time; time.sleep(30)']); time.sleep(30)"], cwd=folder, timeout=10, stdout='capture', cancel=cancelled, hidden_console=True)
                    self.assertEqual(result.reason, 'cancelled')
                    self.assertIsNone(sentinel.poll())
                finally:
                    timer.cancel(); timer.join()
        finally:
            sentinel.terminate(); sentinel.wait(timeout=5)

    def test_output_flood_is_bounded_and_cleaned(self):
        with tempfile.TemporaryDirectory() as folder:
            result = owner.run_owned([sys.executable, '-I', '-S', '-c', "import os; data=b'x'*65536; exec('while True: os.write(1,data)')"], cwd=folder, timeout=10, stdout='capture', max_output_bytes=1024)
            self.assertEqual(result.reason, 'output_limit')
            self.assertLessEqual(len(result.stdout), 1024)

if __name__ == '__main__':
    unittest.main()
