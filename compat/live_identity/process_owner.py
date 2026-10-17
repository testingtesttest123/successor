"""Reap adopted orphan children in container test runs; no product changes."""

import ctypes
import os
import subprocess
import sys

libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER failed")
child = subprocess.Popen(sys.argv[1:])
while True:
    pid, status = os.waitpid(-1, 0)
    if pid == child.pid:
        child.returncode = os.waitstatus_to_exitcode(status)
        sys.exit(child.returncode)
