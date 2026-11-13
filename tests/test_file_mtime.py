"""Run with: python3 -m unittest discover -s tests -v."""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


LIB = Path(__file__).resolve().parents[1] / "scripts" / "lib.sh"


class FileMtimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="approve-all-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "path with spaces"
        self.path.mkdir()

    def run_bash(self, script, *args):
        result = subprocess.run(
            ["bash", "-euc", '. "$1"; shift\n' + script,
             "test", str(LIB), *map(str, args)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_native_mtime_is_only_the_timestamp(self):
        timestamp = 1700000000
        os.utime(self.path, (timestamp, timestamp))
        self.assertEqual(
            self.run_bash('file_mtime "$1"', self.path),
            str(timestamp) + "\n",
        )

    def test_gnu_stat_does_not_leak_failed_bsd_output(self):
        self.assertEqual(self.run_bash(r'''
stat() {
  if [ "$1" = -c ]; then
    printf '1700000000\n'
    return 0
  fi
  printf '  File: "lock"\n    ID: filesystem information\n'
  return 1
}
file_mtime lock
'''), "1700000000\n")

    def test_bsd_fallback_discards_failed_gnu_output(self):
        self.assertEqual(self.run_bash(r'''
stat() {
  if [ "$1" = -c ]; then
    printf 'failed probe output\n'
    return 1
  fi
  printf '1700000000\n'
}
file_mtime lock
'''), "1700000000\n")

    def test_successful_non_numeric_output_is_rejected(self):
        self.assertEqual(self.run_bash(r'''
stat() { printf 'File: invalid timestamp\n'; }
date() { printf '1700000001\n'; }
file_mtime lock
'''), "1700000001\n")

    def test_failed_probes_preserve_date_fallback(self):
        self.assertEqual(self.run_bash(r'''
stat() { printf 'failed probe output\n'; return 1; }
date() { printf '1700000001\n'; }
file_mtime lock
'''), "1700000001\n")

    def test_existing_fresh_lock_returns_busy_without_error(self):
        self.run_bash('''
if take_lock "$1" 60; then
  echo 'unexpectedly acquired an active lock' >&2
  exit 1
else
  code=$?
  [ "$code" -eq 1 ]
fi
''', self.path)
        self.assertTrue(self.path.is_dir())

    def test_expired_lock_can_be_reacquired(self):
        timestamp = time.time() - 120
        os.utime(self.path, (timestamp, timestamp))
        self.run_bash('take_lock "$1" 60', self.path)
        self.assertGreater(self.path.stat().st_mtime, timestamp)

    def test_timestamp_can_be_used_in_debounce_arithmetic(self):
        timestamp = 1700000000
        os.utime(self.path, (timestamp, timestamp))
        self.assertEqual(self.run_bash('''
now=1700000001
printf '%s\n' "$((now - $(file_mtime "$1")))"
''', self.path), "1\n")


if __name__ == "__main__":
    unittest.main()
