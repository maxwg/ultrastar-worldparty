"""Inert local fixtures. Every process self-exits after 30 seconds as a backstop."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def mark(folder, role):
    (folder / (role + ".json")).write_text(
        json.dumps({"role": role, "pid": os.getpid(), "parent_pid": os.getppid()}),
        encoding="utf-8")


def child_args(role, folder):
    return [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()),
            role, str(folder)]


def main():
    role, folder = sys.argv[1], Path(sys.argv[2])
    if role in ("owner", "owner_suspended"):
        import owned_process

        def crash_when_requested():
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if (folder / "crash_owner").is_file():
                    os._exit(91)
                time.sleep(0.01)

        threading.Thread(target=crash_when_requested, daemon=True).start()
        mark(folder, role)
        if role == "owner_suspended":
            import ctypes
            original_create = owned_process._create_process

            def record_suspended(*values):
                result = original_create(*values)
                if result:
                    process = ctypes.cast(values[-1], ctypes.POINTER(
                        owned_process.ProcessInfo)).contents
                    (folder / "suspended.json").write_text(json.dumps(
                        {"role": "suspended", "pid": process.dwProcessId,
                         "parent_pid": os.getpid()}), encoding="utf-8")
                return result

            def stay_suspended(handle):
                time.sleep(30)  # owner crash requested via the local marker
                return 0xFFFFFFFF

            owned_process._create_process = record_suspended
            owned_process._resume_thread = stay_suspended
        owned_process.run_owned(child_args("parent", folder), cwd=str(folder),
                                timeout=25, stdout="inherit")
        return 0
    mark(folder, role)
    if role in ("parent", "child"):
        next_role = "child" if role == "parent" else "grandchild"
        # Deliberately broad inheritance in fixtures tests that the job handle
        # itself is never inheritable. Production helper restricts HANDLE_LIST.
        subprocess.Popen(child_args(next_role, folder), close_fds=False,
                         creationflags=subprocess.CREATE_NO_WINDOW)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if role == "parent" and (folder / "exit_parent").is_file():
            return 23
        time.sleep(0.01)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
