"""L2 unit tests for timesyncd drift lab lib. Run: python3 -m unittest discover -s experiments/timesyncd/tests -v"""
import json
import os
import subprocess
import sys
import unittest

LIB = os.path.join(os.path.dirname(__file__), "..", "lib")


def run_tool(script, *args):
    out = subprocess.run(
        [sys.executable, os.path.join(LIB, script), *args],
        capture_output=True, text=True, check=True)
    return out.stdout


class TestClockInjectDryRun(unittest.TestCase):
    def test_set_offset_positive(self):
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-offset", "--ms", "399"))
        self.assertEqual(d["modes_names"], ["ADJ_SETOFFSET", "ADJ_NANO"])
        self.assertEqual(d["time_tv_sec"], 0)
        self.assertEqual(d["time_tv_usec"], 399_000_000)  # ADJ_NANO: 此欄是 ns

    def test_set_offset_negative_normalized(self):
        # -250ms 必須正規化成 tv_sec=-1, frac=750ms（kernel 要求 0 <= tv_usec < 1e9）
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-offset", "--ms", "-250"))
        self.assertEqual(d["time_tv_sec"], -1)
        self.assertEqual(d["time_tv_usec"], 750_000_000)

    def test_set_offset_large_negative(self):
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-offset", "--ms", "-86400"))
        self.assertEqual(d["time_tv_sec"], -87)
        self.assertEqual(d["time_tv_usec"], 600_000_000)

    def test_set_tick(self):
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-tick", "--ppm", "1000"))
        self.assertEqual(d["tick"], 10010)
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-tick", "--ppm", "-400"))
        self.assertEqual(d["tick"], 9996)

    def test_set_tick_rejects_non_multiple_of_100(self):
        p = subprocess.run(
            [sys.executable, os.path.join(LIB, "clock_inject.py"), "--dry-run",
             "set-tick", "--ppm", "150"], capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)

    def test_set_freq_scaling(self):
        # time_freq 單位是 ppm << 16
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-freq", "--ppm", "10"))
        self.assertEqual(d["freq"], 10 << 16)
        d = json.loads(run_tool("clock_inject.py", "--dry-run", "set-freq", "--ppm", "-10"))
        self.assertEqual(d["freq"], -(10 << 16))


if __name__ == "__main__":
    unittest.main()
