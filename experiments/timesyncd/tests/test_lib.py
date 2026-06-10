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


class TestNtpProbeParse(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, LIB)
        import ntp_probe
        self.m = ntp_probe

    def _reply(self, t_server, mode=4, leap=0, stratum=2):
        """合成 48-byte server reply：T2=T3=t_server（unix 秒）。"""
        import struct
        sec = int(t_server) + self.m.NTP_EPOCH_OFFSET
        frac = int((t_server % 1) * 2**32)
        pkt = bytearray(48)
        pkt[0] = (leap << 6) | (4 << 3) | mode
        pkt[1] = stratum
        pkt[32:40] = struct.pack("!II", sec, frac)  # receive (T2)
        pkt[40:48] = struct.pack("!II", sec, frac)  # transmit (T3)
        return bytes(pkt)

    def test_build_packet(self):
        pkt = self.m.build_packet()
        self.assertEqual(len(pkt), 48)
        self.assertEqual(pkt[0], 0x23)  # LI=0 VN=4 Mode=3 (client)

    def test_offset_delay_math(self):
        # t1=1000.0, t4=1000.2, server T2=T3=1000.6
        # offset = ((T2-t1)+(T3-t4))/2 = (0.6+0.4)/2 = 0.5 (server - client)
        # delay  = (t4-t1)-(T3-T2) = 0.2
        off, dly = self.m.parse_reply(self._reply(1000.6), 1000.0, 1000.2)
        self.assertAlmostEqual(off, 0.5, places=6)
        self.assertAlmostEqual(dly, 0.2, places=6)

    def test_client_fast_reads_negative(self):
        # client 比 server 快 0.5s → offset 必須是負（sign convention）
        off, _ = self.m.parse_reply(self._reply(1000.0), 1000.4, 1000.6)
        self.assertLess(off, 0)

    def test_rejects_bad_packets(self):
        with self.assertRaises(ValueError):  # mode 3 不是 server reply
            self.m.parse_reply(self._reply(1000.0, mode=3), 1000.0, 1000.1)
        with self.assertRaises(ValueError):  # LI=3 unsynchronized
            self.m.parse_reply(self._reply(1000.0, leap=3), 1000.0, 1000.1)
        with self.assertRaises(ValueError):  # stratum 0
            self.m.parse_reply(self._reply(1000.0, stratum=0), 1000.0, 1000.1)
        with self.assertRaises(ValueError):  # 短封包
            self.m.parse_reply(b"\x00" * 20, 1000.0, 1000.1)


class TestFakeServerLoopback(unittest.TestCase):
    """Mac 可跑的 L2 整合測試：fake server + ntp_probe 走 localhost UDP。"""
    PORT = 12923

    def test_oneshot_against_fake_server(self):
        import time as _time
        srv = subprocess.Popen(
            [sys.executable, os.path.join(LIB, "fake_ntp_server.py"),
             "--bind", "127.0.0.1", "--port", str(self.PORT)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            out = None
            for _ in range(20):  # 等 server bind（最多 2s）
                _time.sleep(0.1)
                p = subprocess.run(
                    [sys.executable, os.path.join(LIB, "ntp_probe.py"),
                     "oneshot", "--server", "127.0.0.1", "--port", str(self.PORT)],
                    capture_output=True, text=True)
                if p.returncode == 0:
                    out = p.stdout.strip()
                    break
            self.assertIsNotNone(out, "probe 一直連不上 fake server")
            # 同一台機器、server 剛用 wall 錨定 → offset 應接近 0
            self.assertLess(abs(float(out)), 100.0)
        finally:
            srv.terminate()
            srv.wait(timeout=5)

    def test_skew_option(self):
        import time as _time
        srv = subprocess.Popen(
            [sys.executable, os.path.join(LIB, "fake_ntp_server.py"),
             "--bind", "127.0.0.1", "--port", str(self.PORT + 1),
             "--skew-ms", "250"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            val = None
            for _ in range(20):
                _time.sleep(0.1)
                p = subprocess.run(
                    [sys.executable, os.path.join(LIB, "ntp_probe.py"),
                     "oneshot", "--server", "127.0.0.1", "--port", str(self.PORT + 1)],
                    capture_output=True, text=True)
                if p.returncode == 0:
                    val = float(p.stdout.strip())
                    break
            self.assertIsNotNone(val)
            # server 快 250ms → probe offset（server−client）≈ +250
            self.assertGreater(val, 150.0)
            self.assertLess(val, 350.0)
        finally:
            srv.terminate()
            srv.wait(timeout=5)


class TestStepDetectorLogic(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, LIB)
        import step_detector
        self.m = step_detector

    def test_smooth_ramp_no_events(self):
        # 500ppm slew @10Hz：每樣本 0.05ms，遠低於 1ms 門檻
        ds = [i * 0.05 for i in range(100)]
        self.assertEqual(self.m.find_jumps(ds, 1.0), [])

    def test_single_step_detected(self):
        ds = [0.0] * 50 + [401.0] * 50  # 一次 401ms step
        events = self.m.find_jumps(ds, 1.0)
        self.assertEqual(len(events), 1)
        idx, jump = events[0]
        self.assertEqual(idx, 50)
        self.assertAlmostEqual(jump, 401.0, places=6)

    def test_backward_step_detected(self):
        ds = [100.0] * 10 + [98.0] * 10
        events = self.m.find_jumps(ds, 1.0)
        self.assertEqual(len(events), 1)
        self.assertLess(events[0][1], 0)


class TestLeaseSentinelLogic(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, LIB)
        import lease_sentinel
        self.m = lease_sentinel

    def test_normal_tick(self):
        self.assertIsNone(self.m.classify(1.0, 1.0, lease_s=5.0))

    def test_forward_jump_miss(self):
        # raw 過 1s 但 wall 過 6.5s → 時鐘前跳吃掉 lease
        self.assertEqual(self.m.classify(6.5, 1.0, lease_s=5.0), "miss")

    def test_stall_also_miss(self):
        # wall 與 raw 都過 6.5s → process 卡住，一樣是 miss
        self.assertEqual(self.m.classify(6.5, 6.5, lease_s=5.0), "miss")

    def test_backward(self):
        self.assertEqual(self.m.classify(-0.3, 1.0, lease_s=5.0), "backward")


if __name__ == "__main__":
    unittest.main()
