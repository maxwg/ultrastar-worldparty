"""Run unchanged installer assertions with an independent outer Job watchdog.

The strict production owner remains untouched in the separate installer worker.
The outer watchdog bounds the test, but never supplies its cleanup evidence.
"""
from dataclasses import asdict
import hashlib
import importlib.util
import json
from pathlib import Path
import runpy
import sys
import threading
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'catalog-tests'))
sys.path.insert(0, str(HERE))
import test_install_windows as base

production = base.owner
original_run_owned = production.run_owned
spec = importlib.util.spec_from_file_location(
    'installer_outer_watchdog', HERE / 'before-repair-20261014/owned_process.py')
watchdog = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = watchdog
spec.loader.exec_module(watchdog)


class OuterOnlyProxy:
    run_owned = staticmethod(watchdog.run_owned)

    def __getattr__(self, name):
        return getattr(production, name)


# Set the parent test-module alias before boundary imports it. Do not alter the
# real module object or sys.modules['owned_process']; workers import that file.
base.owner = OuterOnlyProxy()
import test_boundary_v2 as boundary
import test_repaired_install as repaired

GUARD = {}


class BoundaryGuardTests(repaired.RepairTests):
    def test_outer_watchdog_cannot_mask_live_descendant(self):
        self.outer_results, self.outer_errors = [], []

        def run():
            try:
                self.outer_results.append(base.owner.run_owned(
                    [sys.executable, '-I', '-S', '-B',
                     str(HERE / 'test_outer_boundary_worker.py'), str(self.case)],
                    cwd=str(self.case), timeout=12, stdout='devnull', cleanup_timeout=3))
            except BaseException as error:
                self.outer_errors.append(repr(error))

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()
        try:
            self.capture_roles(('guard_child',))
            (self.case / 'allow_return').write_text('release fixture', encoding='ascii')
            # Exercise the exact retained pre-cleanup assertion against a bad
            # synthetic worker. The outer watchdog must not turn it into a pass.
            with self.assertRaisesRegex(AssertionError, 'Production returned before exact fixture process termination'):
                boundary.BoundaryTests.finish(self)
            self.assertFalse(self.worker.is_alive())
            self.assertEqual(self.outer_errors, [])
            self.assertEqual(self.outer_results[0].reason, 'exited')
            self.assertEqual(self.outer_results[0].returncode, 0)
            self.assertEqual(production._wait(self.handles['guard_child'], 1000), production.WAIT_OBJECT_0)
            self.assertIs(production.run_owned, original_run_owned)
            GUARD.update({'expected_assertion_observed': True,
                          'boundary': boundary.BOUNDARY_RECEIPTS[-1],
                          'outer': asdict(self.outer_results[0]),
                          'exact_child_handle_after_outer_cleanup': 0,
                          'production_module_unmodified': True})
        finally:
            (self.case / 'allow_return').write_text('release fixture', encoding='ascii')
            (self.case / 'acknowledge').write_text('release fixture', encoding='ascii')
            self.worker.join(16)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == '__main__':
    paths = [HERE / 'owned_process.py', HERE / 'song_catalog.py',
             Path(__file__), HERE / 'test_outer_boundary_worker.py',
             HERE / 'before-repair-20261014/owned_process.py',
             *[HERE / 'catalog-tests' / name for name in
               ('test_install_windows.py', 'test_boundary_v2.py',
                'test_repaired_install.py', 'install_runner.py', 'boundary_runner.py')]]
    before = {str(path.relative_to(HERE)): sha(path) for path in paths}
    started = time.monotonic()
    guard = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite([
        BoundaryGuardTests('test_outer_watchdog_cannot_mask_live_descendant')]))
    boundary.BOUNDARY_RECEIPTS.clear()
    base.RECEIPTS.clear()
    installer_exit = None
    if guard.wasSuccessful():
        # Execute the retained selection, assertions and receipt writer verbatim.
        sys.argv = [str(HERE / 'catalog-tests/test_repaired_install.py'), 'fast']
        try:
            runpy.run_path(sys.argv[0], run_name='__main__')
            installer_exit = 0
        except SystemExit as error:
            installer_exit = error.code
    stable = before == {str(path.relative_to(HERE)): sha(path) for path in paths}
    untouched = production.run_owned is original_run_owned and sys.modules['owned_process'] is production
    receipt = {'schema_version': 1, 'guard_tests': guard.testsRun,
               'guard_failures': len(guard.failures), 'guard_errors': len(guard.errors),
               'guard': GUARD, 'installer_exit': installer_exit,
               'production_module_unmodified': untouched, 'source_bytes_stable': stable,
               'source_sha256': before, 'elapsed_seconds': time.monotonic() - started,
               'outer_watchdog_only': 'historical atomic Job owner; active-empty supervision, not production evidence',
               'success': guard.wasSuccessful() and installer_exit == 0 and stable and untouched}
    output = base.RUN / 'independent-installer-watchdog-receipt.json'
    output.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print('WATCHDOG_RECEIPT=' + str(output), flush=True)
    raise SystemExit(0 if receipt['success'] else 1)
