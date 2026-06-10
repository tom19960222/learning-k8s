# timesyncd Drift Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建出 timesyncd 時鐘漂移恢復實驗的完整交付物：`experiments/timesyncd/` agent 執行包（scripts + README）、兩頁網站文章、projects.ts/quiz 整合，並完成 L1/L2 本機驗證後 commit + push。

**Architecture:** 所有實驗操作在 client VM 端（adjtimex 注入 + 1Hz SNTP probe 獨立量測），server 端 chrony 只做一次性 setup。失聯階段數學折疊成初始條件（offset = T×F + 殘留 ppm 注入），只跑恢復階段。Spec：`docs/superpowers/specs/2026-06-10-timesyncd-drift-lab-design.md`（已核准，所有設計決策以它為準）。

**Tech Stack:** bash + Python 3 stdlib（零第三方依賴）、ctypes 呼叫 `clock_adjtime(2)`、systemd-run transient units（detach）、iptables（只動 OUTPUT udp/123）、Next.js MDX（網站）。

**驗證分層：** 本 plan 只含 L1（靜態）/ L2（單元 + Mac loopback）；L3（PVE client VM 單機 rig）/ L4（雙 VM 全套）等使用者提供環境後另開 session，README 已含其步驟。

**Git：** 開 branch `timesyncd-drift-lab`；所有 commit 用 `git commit --no-gpg-sign`；最後 `make validate` exit 0 才能 merge/push（CLAUDE.md 規範）。

---

## File Map

| 檔案 | 責任 |
|---|---|
| `experiments/timesyncd/env.example.sh` | 環境變數範本（SERVER_IP 等） |
| `experiments/timesyncd/lib/clock_inject.py` | adjtimex 注入：SETOFFSET / TICK / FREQUENCY / reset / status，`--dry-run` 可在 Mac 測 |
| `experiments/timesyncd/lib/ntp_probe.py` | 1Hz SNTP probe → CSV；`oneshot` 模式印單次 offset |
| `experiments/timesyncd/lib/fake_ntp_server.py` | L3 用假 NTP server（MONOTONIC_RAW 基準） |
| `experiments/timesyncd/lib/step_detector.py` | REALTIME vs MONOTONIC_RAW 跳變監視 → CSV |
| `experiments/timesyncd/lib/lease_sentinel.py` | 5s deadline 哨兵（模擬 ceph mon lease watchdog） |
| `experiments/timesyncd/lib/analyze.py` | CSV → 收斂時間 / 校準 ppm / soak verdict / exp1 彙總 |
| `experiments/timesyncd/lib/common.sh` | preflight、狀態重置、iptables 安全規則、detach、state.json |
| `experiments/timesyncd/setup/setup-server.sh` | 24.04 chrony LAN server |
| `experiments/timesyncd/setup/setup-client.sh` | 22.04 timesyncd 指向 server + 安全網 |
| `experiments/timesyncd/setup/calibrate.sh` | 基線漂移校準 → results/calibration.json |
| `experiments/timesyncd/run/exp1-drift-recovery.sh` | 25 cells 失聯恢復 |
| `experiments/timesyncd/run/exp2-slew-399ms.sh` | 399/401ms 對照 |
| `experiments/timesyncd/run/exp3-restart-sync.sh` | 重啟對時 4 cells |
| `experiments/timesyncd/run/exp4-poll256-soak.sh` | 6 情境穩定度 soak |
| `experiments/timesyncd/run/all.sh` | 全套無人值守 + 斷點續跑 |
| `experiments/timesyncd/tests/test_lib.py` | L2 單元測試（unittest，Mac 可跑） |
| `experiments/timesyncd/README.md` | agent 執行計畫（部署、順序、判準、故障排除、L3 模式） |
| `next-site/content/systemd/features/timesyncd-drift-lab-methodology.mdx` | 頁 A 方法論 |
| `next-site/content/systemd/features/timesyncd-drift-lab-experiments.mdx` | 頁 B 實驗設計與結果 |
| `next-site/lib/projects.ts`（修改 :424-428、:450-462） | features / featureGroups / learningPaths |
| `next-site/content/systemd/quiz.json`（修改） | 新增 8 題（id 12–19） |
| `.gitignore`（修改） | 加 `experiments/timesyncd/env.sh` |

**重要慣例（所有 task 共用）：**

- **Sign convention（寫進每個工具的 docstring）**：probe offset = server − client；client 快 X ms → probe offset ≈ **−X**。`set-offset --ms +X` 把 client 撥快 X。注入 +ppm = client 變快。校準 `client_ppm = −slope(offset)`。
- 失聯折疊：`offset_ms = duration_s × ppm / 1000`（帶正負號）。
- 收斂判定：`|offset| < 50ms` 持續 60s，取首次進入時刻（相對 t0，t0 = timesyncd 啟動/重啟的 MONOTONIC_RAW 秒）。
- probe CSV 格式（全工具統一）：header `raw_s,wall_s,offset_ms,delay_ms,err`，err 非空代表該行量測失敗（offset_ms/delay_ms 為空）。
- iptables 鐵則：只允許出現 `-p udp --dport 123` 的 OUTPUT 規則操作。
- Python 3.10 相容（VM 是 22.04）；shell 用 `#!/usr/bin/env bash` + `set -euo pipefail`。
- 每個 commit 都 `--no-gpg-sign`。

---

### Task 0: Branch + scaffold

**Files:**
- Create: `experiments/timesyncd/{lib,setup,run,results,tests}/`、`experiments/timesyncd/env.example.sh`、`experiments/timesyncd/results/.gitkeep`
- Modify: `.gitignore`

- [ ] **Step 1: 開 branch 與目錄**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git checkout -b timesyncd-drift-lab
mkdir -p experiments/timesyncd/{lib,setup,run,results,tests}
touch experiments/timesyncd/results/.gitkeep
```

- [ ] **Step 2: 寫 `experiments/timesyncd/env.example.sh`**

```bash
# timesyncd drift lab 環境設定。複製成 env.sh 後填值（env.sh 已被 .gitignore 擋掉）
# NTP server VM 的 IP（client 看得到的那個）
SERVER_IP=192.168.1.10
# client 對外網卡（exp4 jitter 情境的 tc netem 用）
CLIENT_IFACE=eth0
# probe 打的 NTP port。真實環境 123；L3 fake server 模式也是 123（bind localhost）
NTP_PORT=123
# 結果輸出根目錄（預設 repo 內 results/）
RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"
```

- [ ] **Step 3: `.gitignore` 加一行**

在 `.gitignore` 結尾加：

```
experiments/timesyncd/env.sh
```

- [ ] **Step 4: Commit**

```bash
git add experiments/timesyncd .gitignore
git commit --no-gpg-sign -m "timesyncd-drift-lab: scaffold experiments 目錄與 env 範本"
```

---

### Task 1: `lib/clock_inject.py`（adjtimex 注入工具）

**Files:**
- Create: `experiments/timesyncd/lib/clock_inject.py`
- Test: `experiments/timesyncd/tests/test_lib.py`（本 task 先建檔，後續 task 往裡加 class）

`--dry-run` 模式不碰 syscall、印出將送出的 struct 欄位 JSON——這讓 Mac 上可完整單元測試注入參數的正確性（負 offset 正規化、tick 換算、freq scaling）。

- [ ] **Step 1: 寫失敗測試（建 `tests/test_lib.py`）**

```python
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
```

- [ ] **Step 2: 跑測試，確認 fail**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: FAIL（`clock_inject.py` 不存在 → FileNotFoundError）

- [ ] **Step 3: 寫 `lib/clock_inject.py`**

```python
#!/usr/bin/env python3
"""clock_inject.py — adjtimex(clock_adjtime) injection tool for the timesyncd drift lab.

Sign conventions (repo-wide):
  set-offset --ms +X : step CLOCK_REALTIME forward by X ms (client becomes FAST by X)
  set-tick / set-freq --ppm +P : clock runs FAST by P ppm
  NTP probe offset = server - client, so a FAST client reads NEGATIVE probe offset.

Mechanism mapping (spec decision 2):
  accumulated offset -> ADJ_SETOFFSET (atomic, not clamped by MAXPHASE)
  |ppm| >= 100, multiple of 100 -> ADJ_TICK (register untouched by kernel PLL / timesyncd)
  fine ppm (e.g. +-10)          -> ADJ_FREQUENCY (PLL rewrites it; dynamically equivalent)

--dry-run prints the struct fields as JSON without any syscall (works on macOS for L2 tests).
"""
import argparse
import ctypes
import json
import sys

ADJ_OFFSET = 0x0001
ADJ_FREQUENCY = 0x0002
ADJ_MAXERROR = 0x0004
ADJ_ESTERROR = 0x0008
ADJ_STATUS = 0x0010
ADJ_TIMECONST = 0x0020
ADJ_SETOFFSET = 0x0100
ADJ_NANO = 0x2000
ADJ_TICK = 0x4000
STA_PLL = 0x0001
STA_UNSYNC = 0x0040
CLOCK_REALTIME = 0
SYS_clock_adjtime = 305  # x86_64
NSEC_PER_SEC = 1_000_000_000
TICK_DEFAULT_USEC = 10000  # USER_HZ=100

MODE_NAMES = {
    ADJ_OFFSET: "ADJ_OFFSET", ADJ_FREQUENCY: "ADJ_FREQUENCY",
    ADJ_MAXERROR: "ADJ_MAXERROR", ADJ_ESTERROR: "ADJ_ESTERROR",
    ADJ_STATUS: "ADJ_STATUS", ADJ_TIMECONST: "ADJ_TIMECONST",
    ADJ_SETOFFSET: "ADJ_SETOFFSET", ADJ_NANO: "ADJ_NANO", ADJ_TICK: "ADJ_TICK",
}


class Timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class Timex(ctypes.Structure):
    # 對齊 linux/include/uapi/linux/timex.h 的 struct timex（x86_64 LP64，208 bytes）
    _fields_ = [
        ("modes", ctypes.c_uint),
        ("offset", ctypes.c_long), ("freq", ctypes.c_long),
        ("maxerror", ctypes.c_long), ("esterror", ctypes.c_long),
        ("status", ctypes.c_int),
        ("constant", ctypes.c_long), ("precision", ctypes.c_long),
        ("tolerance", ctypes.c_long),
        ("time", Timeval),
        ("tick", ctypes.c_long), ("ppsfreq", ctypes.c_long), ("jitter", ctypes.c_long),
        ("shift", ctypes.c_int),
        ("stabil", ctypes.c_long), ("jitcnt", ctypes.c_long), ("calcnt", ctypes.c_long),
        ("errcnt", ctypes.c_long), ("stbcnt", ctypes.c_long),
        ("tai", ctypes.c_int),
        ("_pad", ctypes.c_int * 11),
    ]


def tx_dump(tx):
    modes = tx.modes
    return {
        "modes": modes,
        "modes_names": [n for v, n in sorted(MODE_NAMES.items()) if modes & v],
        "offset": tx.offset, "freq": tx.freq, "status": tx.status,
        "tick": tx.tick,
        "time_tv_sec": tx.time.tv_sec, "time_tv_usec": tx.time.tv_usec,
    }


def do_call(tx, dry_run):
    if dry_run:
        print(json.dumps(tx_dump(tx)))
        return 0
    if sys.platform != "linux":
        sys.exit("clock_inject: real injection only works on Linux (use --dry-run elsewhere)")
    assert ctypes.sizeof(Timex) == 208, f"struct timex size {ctypes.sizeof(Timex)} != 208"
    libc = ctypes.CDLL(None, use_errno=True)
    ret = libc.syscall(SYS_clock_adjtime, CLOCK_REALTIME, ctypes.byref(tx))
    if ret < 0:
        err = ctypes.get_errno()
        sys.exit(f"clock_adjtime failed: errno={err}")
    return ret


def cmd_set_offset(args):
    total_ns = round(args.ms * 1_000_000)
    tv_sec = total_ns // NSEC_PER_SEC          # floor division：負值正規化
    tv_nsec = total_ns - tv_sec * NSEC_PER_SEC  # 0 <= tv_nsec < 1e9
    tx = Timex()
    tx.modes = ADJ_SETOFFSET | ADJ_NANO
    tx.time.tv_sec = tv_sec
    tx.time.tv_usec = tv_nsec  # ADJ_NANO 時此欄為 ns
    do_call(tx, args.dry_run)


def cmd_set_tick(args):
    if args.ppm % 100 != 0:
        sys.exit("set-tick: ppm 必須是 100 的倍數（tick 粒度 = 100ppm）")
    tick = TICK_DEFAULT_USEC + args.ppm // 100
    if not 9000 <= tick <= 11000:
        sys.exit(f"set-tick: tick {tick} 超出 kernel 範圍 9000–11000")
    tx = Timex()
    tx.modes = ADJ_TICK
    tx.tick = tick
    do_call(tx, args.dry_run)


def cmd_set_freq(args):
    if abs(args.ppm) > 500:
        print(f"warn: |{args.ppm}ppm| > 500，kernel 會 clamp 到 MAXFREQ", file=sys.stderr)
    tx = Timex()
    tx.modes = ADJ_FREQUENCY
    tx.freq = int(args.ppm * 65536)
    do_call(tx, args.dry_run)


def cmd_reset(args):
    # 依序：tick 歸位 → freq 歸零 → 開 PLL 清 time_offset → 標回 UNSYNC（等 timesyncd 接手）
    seq = []
    tx = Timex(); tx.modes = ADJ_TICK; tx.tick = TICK_DEFAULT_USEC; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_FREQUENCY; tx.freq = 0; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_STATUS; tx.status = STA_PLL; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_OFFSET | ADJ_NANO; tx.offset = 0; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_STATUS; tx.status = STA_UNSYNC; seq.append(tx)
    for tx in seq:
        do_call(tx, args.dry_run)
    if not args.dry_run:
        print("reset: tick=10000 freq=0 time_offset=0 status=UNSYNC")


def cmd_status(args):
    tx = Timex()
    tx.modes = 0
    state = do_call(tx, args.dry_run)
    if not args.dry_run:
        d = tx_dump(tx)
        d["freq_ppm"] = tx.freq / 65536
        d["kernel_state"] = state  # 0=TIME_OK 5=TIME_ERROR(unsync)
        print(json.dumps(d))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set-offset"); s.add_argument("--ms", type=float, required=True); s.set_defaults(fn=cmd_set_offset)
    s = sub.add_parser("set-tick"); s.add_argument("--ppm", type=int, required=True); s.set_defaults(fn=cmd_set_tick)
    s = sub.add_parser("set-freq"); s.add_argument("--ppm", type=float, required=True); s.set_defaults(fn=cmd_set_freq)
    s = sub.add_parser("reset"); s.set_defaults(fn=cmd_reset)
    s = sub.add_parser("status"); s.set_defaults(fn=cmd_status)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試，確認 pass**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add experiments/timesyncd/lib/clock_inject.py experiments/timesyncd/tests/test_lib.py
git commit --no-gpg-sign -m "timesyncd-drift-lab: clock_inject adjtimex 注入工具 + dry-run 單元測試"
```

---

### Task 2: `lib/ntp_probe.py`（獨立 SNTP probe）

**Files:**
- Create: `experiments/timesyncd/lib/ntp_probe.py`
- Modify: `experiments/timesyncd/tests/test_lib.py`（加 `TestNtpProbeParse`）

封包數學是純函式（`build_packet` / `parse_reply`），Mac 上可直接單元測試；網路部分（`query`）由 Task 3 的 loopback 整合測試覆蓋。

- [ ] **Step 1: 在 `tests/test_lib.py` 加失敗測試**

在檔案結尾（`if __name__ == "__main__":` 之前）加：

```python
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
```

- [ ] **Step 2: 跑測試確認 fail**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: `TestNtpProbeParse` 全 FAIL（ImportError: ntp_probe），Task 1 的 6 個照樣 PASS

- [ ] **Step 3: 寫 `lib/ntp_probe.py`**

```python
#!/usr/bin/env python3
"""ntp_probe.py — independent SNTP probe for the timesyncd drift lab.

Measurement independence: we never trust timesyncd's self-reported offset.
This probe sends its own SNTP queries (plain UDP, stdlib only).

Sign convention (repo-wide): offset = server - client.
A client running FAST by X ms reads offset ~= -X ms.

Modes:
  oneshot --server IP [--port 123] [--samples N]   print median offset_ms to stdout
  run --server IP --csv FILE [--interval 1.0]      1Hz loop -> CSV until SIGTERM/SIGINT
CSV header: raw_s,wall_s,offset_ms,delay_ms,err
"""
import argparse
import signal
import socket
import statistics
import struct
import sys
import time

NTP_EPOCH_OFFSET = 2208988800  # 1900-01-01 -> 1970-01-01


def build_packet():
    pkt = bytearray(48)
    pkt[0] = 0x23  # LI=0 VN=4 Mode=3 (client)
    return bytes(pkt)


def ntp_to_unix(sec, frac):
    return sec - NTP_EPOCH_OFFSET + frac / 2**32


def parse_reply(data, t1, t4):
    """回傳 (offset_s, delay_s)。t1/t4 = client 送出/收到的 time.time()。"""
    if len(data) < 48:
        raise ValueError(f"short packet ({len(data)} bytes)")
    leap = data[0] >> 6
    mode = data[0] & 0x7
    stratum = data[1]
    if mode != 4:
        raise ValueError(f"not a server reply (mode={mode})")
    if leap == 3:
        raise ValueError("server unsynchronized (LI=3)")
    if not 1 <= stratum <= 15:
        raise ValueError(f"bad stratum {stratum}")
    t2s, t2f = struct.unpack("!II", data[32:40])  # receive timestamp
    t3s, t3f = struct.unpack("!II", data[40:48])  # transmit timestamp
    if t3s == 0:
        raise ValueError("zero transmit timestamp")
    t2 = ntp_to_unix(t2s, t2f)
    t3 = ntp_to_unix(t3s, t3f)
    offset = ((t2 - t1) + (t3 - t4)) / 2.0  # server - client
    delay = (t4 - t1) - (t3 - t2)
    return offset, delay


def query(server, port, timeout=1.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        t1 = time.time()
        sock.sendto(build_packet(), (server, port))
        data, _ = sock.recvfrom(512)
        t4 = time.time()
    finally:
        sock.close()
    return parse_reply(data, t1, t4)


def raw_now():
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


def cmd_oneshot(args):
    offsets = []
    last_err = None
    for _ in range(args.samples):
        try:
            off, _ = query(args.server, args.port)
            offsets.append(off * 1000.0)
        except (OSError, ValueError) as e:
            last_err = e
        time.sleep(0.05)
    if not offsets:
        sys.exit(f"oneshot: all {args.samples} queries failed: {last_err}")
    print(f"{statistics.median(offsets):.3f}")


_stop = False


def _sig(_n, _f):
    global _stop
    _stop = True


def cmd_run(args):
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    with open(args.csv, "w", buffering=1) as f:
        f.write("raw_s,wall_s,offset_ms,delay_ms,err\n")
        next_t = time.monotonic()
        while not _stop:
            r, w = raw_now(), time.time()
            try:
                off, dly = query(args.server, args.port)
                f.write(f"{r:.3f},{w:.3f},{off * 1000:.3f},{dly * 1000:.3f},\n")
            except (OSError, ValueError) as e:
                f.write(f"{r:.3f},{w:.3f},,,{type(e).__name__}\n")
            next_t += args.interval
            pause = next_t - time.monotonic()
            if pause > 0:
                time.sleep(pause)
            else:
                next_t = time.monotonic()  # 落後就重新對齊，不補打


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("oneshot")
    s.add_argument("--server", required=True)
    s.add_argument("--port", type=int, default=123)
    s.add_argument("--samples", type=int, default=1)
    s.set_defaults(fn=cmd_oneshot)
    s = sub.add_parser("run")
    s.add_argument("--server", required=True)
    s.add_argument("--port", type=int, default=123)
    s.add_argument("--csv", required=True)
    s.add_argument("--interval", type=float, default=1.0)
    s.set_defaults(fn=cmd_run)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試確認 pass**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 10 tests PASS

- [ ] **Step 5: Commit**

```bash
git add experiments/timesyncd/lib/ntp_probe.py experiments/timesyncd/tests/test_lib.py
git commit --no-gpg-sign -m "timesyncd-drift-lab: ntp_probe 獨立 SNTP 量測 + 封包數學單元測試"
```

---

### Task 3: `lib/fake_ntp_server.py`（L3 單 kernel rig 的假 server）

**Files:**
- Create: `experiments/timesyncd/lib/fake_ntp_server.py`
- Modify: `experiments/timesyncd/tests/test_lib.py`（加 `TestFakeServerLoopback`）

原理（spec 決策 5 / L3）：`CLOCK_MONOTONIC_RAW` 不受 adjtimex 影響。server 啟動時錨定 `truth(t) = anchor_wall + (raw_now − anchor_raw)`，之後不管 client 對 REALTIME 注入什麼，server 回的都是「未被打亂的真時」。**必須在注入誤差前啟動**（README 會寫明）。

timesyncd 相容性關鍵：reply 必須把 request 的 transmit timestamp（bytes 40–48）複製到 reply 的 origin timestamp（bytes 24–32），timesyncd 會驗 origin 對不上就丟棄。

- [ ] **Step 1: 在 `tests/test_lib.py` 加失敗的 loopback 整合測試**

```python
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
```

- [ ] **Step 2: 跑測試確認 fail**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 新 2 個 FAIL（fake_ntp_server.py 不存在），其餘 10 個 PASS

- [ ] **Step 3: 寫 `lib/fake_ntp_server.py`**

```python
#!/usr/bin/env python3
"""fake_ntp_server.py — SNTP server anchored to CLOCK_MONOTONIC_RAW (L3 single-kernel rig).

CLOCK_MONOTONIC_RAW is immune to adjtimex, so after this server starts,
its replies stay on the *undisturbed* timeline no matter what clock_inject
does to CLOCK_REALTIME on the same kernel.

MUST be started BEFORE injecting any error (it anchors to wall time at startup).

--skew-ms N : deliberately serve time N ms ahead of the anchor (for rig self-tests).
"""
import argparse
import socket
import struct
import sys
import time

NTP_EPOCH_OFFSET = 2208988800


def raw_now():
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


def unix_to_ntp(t):
    sec = int(t)
    frac = int((t - sec) * 2**32)
    return sec + NTP_EPOCH_OFFSET, frac


def make_reply(request, truth_s):
    """48-byte server reply。origin ← request transmit（timesyncd 會驗）。"""
    pkt = bytearray(48)
    pkt[0] = (0 << 6) | (4 << 3) | 4  # LI=0 VN=4 Mode=4 (server)
    pkt[1] = 2                        # stratum 2
    pkt[2] = request[2]               # poll: echo client
    pkt[3] = 0xEC                     # precision ~2^-20
    # root delay / root dispersion = 0（bytes 4-12），refid = 'RAWC'
    pkt[12:16] = b"RAWC"
    sec, frac = unix_to_ntp(truth_s)
    pkt[16:24] = struct.pack("!II", sec, frac)  # reference timestamp
    pkt[24:32] = request[40:48]                 # origin ← client transmit
    pkt[32:40] = struct.pack("!II", sec, frac)  # receive (T2)
    pkt[40:48] = struct.pack("!II", sec, frac)  # transmit (T3)
    return bytes(pkt)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--port", type=int, default=123)
    p.add_argument("--skew-ms", type=float, default=0.0)
    args = p.parse_args()

    anchor_wall = time.time()
    anchor_raw = raw_now()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    print(f"fake_ntp_server: {args.bind}:{args.port} anchored "
          f"wall={anchor_wall:.3f} raw={anchor_raw:.3f} skew={args.skew_ms}ms",
          flush=True)
    while True:
        try:
            data, addr = sock.recvfrom(512)
        except KeyboardInterrupt:
            return
        if len(data) < 48 or (data[0] & 0x7) != 3:
            continue  # 不是 client request
        truth = anchor_wall + (raw_now() - anchor_raw) + args.skew_ms / 1000.0
        sock.sendto(make_reply(data, truth), addr)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 跑測試確認 pass**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 12 tests PASS（loopback 在 Mac 上實際走 UDP）

- [ ] **Step 5: Commit**

```bash
git add experiments/timesyncd/lib/fake_ntp_server.py experiments/timesyncd/tests/test_lib.py
git commit --no-gpg-sign -m "timesyncd-drift-lab: fake NTP server（MONOTONIC_RAW 錨定）+ loopback 整合測試"
```

---

### Task 4: `lib/step_detector.py` + `lib/lease_sentinel.py`（exp2/exp4 監視器）

**Files:**
- Create: `experiments/timesyncd/lib/step_detector.py`、`experiments/timesyncd/lib/lease_sentinel.py`
- Modify: `experiments/timesyncd/tests/test_lib.py`（加兩個 test class）

設計重點：

- **step_detector**：取樣 `d = REALTIME − MONOTONIC_RAW`（10Hz），相鄰樣本差 `|jump| > 1ms` 記一筆事件。物理依據：slew 平滑改 d、step 在一個取樣間隔內整段跳。穩態 soak 中 freq 補償頂多 500ppm = 0.05ms/0.1s，遠低於 1ms 門檻；大 offset slew（如 exp2 的 399ms，初速 ~53ms/s = 5.3ms/0.1s）會產生「一串遞減的小事件」，step 則是「單一一筆 ≈ 整個 offset 的事件」——這個 signature 差異正是 exp2 要打在圖上的東西，分類交給 analyze（`|jump| ≥ 50ms` 算 step）。
- **lease_sentinel**：模擬 ceph mon lease watchdog。每 1s（MONOTONIC sleep）續約一次 5s lease；wall 經過時間 > 5s → `miss`，wall 倒退 → `backward`。同時記 raw 經過時間，用來區分「時鐘跳」vs「process 卡住」。
- 兩者 CSV 都帶 `hb`（heartbeat，每 60s）列，讓 analyze 能驗證監視器真的活著蓋滿整段 soak。

- [ ] **Step 1: 在 `tests/test_lib.py` 加失敗測試**

```python
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
```

- [ ] **Step 2: 跑測試確認 fail**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 新 7 個 FAIL（ImportError），其餘 12 個 PASS

- [ ] **Step 3: 寫 `lib/step_detector.py`**

```python
#!/usr/bin/env python3
"""step_detector.py — detect CLOCK_REALTIME discontinuities (steps) vs smooth slew.

Samples d = CLOCK_REALTIME - CLOCK_MONOTONIC_RAW at --interval (default 0.1s).
A step (clock_settime / ADJ_SETOFFSET) moves d by the whole amount within one
sample; slew moves it gradually. Events with |jump| > --threshold-ms are logged.
Heartbeat row every 60s proves the detector was alive for the whole window.

CSV header: raw_s,wall_s,kind,jump_ms   (kind: jump | hb)
"""
import argparse
import signal
import sys
import time


def find_jumps(ds, threshold_ms):
    """純函式：d 序列（ms）→ [(index, jump_ms), ...]，|jump| > threshold 才算。"""
    events = []
    for i in range(1, len(ds)):
        jump = ds[i] - ds[i - 1]
        if abs(jump) > threshold_ms:
            events.append((i, jump))
    return events


def d_ms():
    return (time.clock_gettime_ns(time.CLOCK_REALTIME)
            - time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)) / 1e6


_stop = False


def _sig(_n, _f):
    global _stop
    _stop = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--csv", required=True)
    p.add_argument("--interval", type=float, default=0.1)
    p.add_argument("--threshold-ms", type=float, default=1.0)
    args = p.parse_args()
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    with open(args.csv, "w", buffering=1) as f:
        f.write("raw_s,wall_s,kind,jump_ms\n")
        prev = d_ms()
        last_hb = time.monotonic()
        while not _stop:
            time.sleep(args.interval)
            cur = d_ms()
            jump = cur - prev
            prev = cur
            r = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
            w = time.time()
            if abs(jump) > args.threshold_ms:
                f.write(f"{r:.3f},{w:.3f},jump,{jump:.3f}\n")
            if time.monotonic() - last_hb >= 60:
                f.write(f"{r:.3f},{w:.3f},hb,\n")
                last_hb = time.monotonic()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 寫 `lib/lease_sentinel.py`**

```python
#!/usr/bin/env python3
"""lease_sentinel.py — 5s-deadline sentinel modelled on the ceph mon lease watchdog.

Every --renew-s (1s, CLOCK_MONOTONIC sleep) the lease is renewed. At each tick:
  wall_elapsed > lease_s  -> 'miss'     (clock jumped forward past the lease, or stall)
  wall_elapsed < 0        -> 'backward' (CLOCK_REALTIME went backwards)
raw_elapsed is logged too so analysis can tell clock-jump (wall >> raw) from
process stall (wall ~= raw).

CSV header: raw_s,wall_s,kind,wall_elapsed_ms,raw_elapsed_ms   (kind: miss | backward | hb)
"""
import argparse
import signal
import sys
import time


def classify(wall_elapsed_s, raw_elapsed_s, lease_s=5.0):
    """純函式：一次 tick 的 wall/raw 經過時間 → None | 'miss' | 'backward'。"""
    if wall_elapsed_s < 0:
        return "backward"
    if wall_elapsed_s > lease_s:
        return "miss"
    return None


_stop = False


def _sig(_n, _f):
    global _stop
    _stop = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--csv", required=True)
    p.add_argument("--lease-s", type=float, default=5.0)
    p.add_argument("--renew-s", type=float, default=1.0)
    args = p.parse_args()
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    with open(args.csv, "w", buffering=1) as f:
        f.write("raw_s,wall_s,kind,wall_elapsed_ms,raw_elapsed_ms\n")
        prev_wall = time.time()
        prev_raw = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
        last_hb = time.monotonic()
        while not _stop:
            time.sleep(args.renew_s)
            w = time.time()
            r = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
            we, re_ = w - prev_wall, r - prev_raw
            kind = classify(we, re_, args.lease_s)
            if kind:
                f.write(f"{r:.3f},{w:.3f},{kind},{we * 1000:.1f},{re_ * 1000:.1f}\n")
            if time.monotonic() - last_hb >= 60:
                f.write(f"{r:.3f},{w:.3f},hb,,\n")
                last_hb = time.monotonic()
            prev_wall, prev_raw = w, r


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: 跑測試確認 pass**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 19 tests PASS

- [ ] **Step 6: Commit**

```bash
git add experiments/timesyncd/lib/step_detector.py experiments/timesyncd/lib/lease_sentinel.py experiments/timesyncd/tests/test_lib.py
git commit --no-gpg-sign -m "timesyncd-drift-lab: step detector 與 lease sentinel 監視器"
```

---

### Task 5: `lib/analyze.py`（收斂判定 / 校準 / verdict / 彙總）

**Files:**
- Create: `experiments/timesyncd/lib/analyze.py`
- Modify: `experiments/timesyncd/tests/test_lib.py`（加 `TestAnalyze`）

Exit code 約定（shell script 靠它分流）：`0` = 收斂 / PASS，`3` = 未收斂 / FAIL，`1` = 程式錯誤。

校準語意（spec 決策 4）：probe offset = server − client，client 快 → offset 隨時間下降 → `client_ppm = −slope_ms_per_s × 1000`（1 ms/s = 1000 ppm）。校準值不從 offset「扣掉」（offset 是 ground truth），而是寫進每個 cell 的 `effective_ppm = injected_ppm + client_ppm`，讓 ±10ppm cell 的解讀不被天然漂移污染。

- [ ] **Step 1: 在 `tests/test_lib.py` 加失敗測試**

```python
import math
import tempfile


def write_csv(path, rows):
    with open(path, "w") as f:
        f.write("raw_s,wall_s,offset_ms,delay_ms,err\n")
        for r in rows:
            f.write(",".join(str(x) for x in r) + "\n")


class TestAnalyze(unittest.TestCase):
    def _run(self, *args, ok=True):
        p = subprocess.run(
            [sys.executable, os.path.join(LIB, "analyze.py"), *args],
            capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def test_convergence_exponential_decay(self):
        # offset = 400·exp(−t/7.5)：跌破 50ms 在 t = ln(8)·7.5 ≈ 15.6s
        with tempfile.TemporaryDirectory() as d:
            csv = os.path.join(d, "probe.csv")
            rows = [(100.0 + t, 1000.0 + t, f"{400 * math.exp(-t / 7.5):.3f}", 0.2, "")
                    for t in range(0, 180)]
            write_csv(csv, rows)
            p = self._run("convergence", "--csv", csv, "--t0-raw", "100.0")
            d_ = json.loads(p.stdout)
            self.assertTrue(d_["converged"])
            self.assertGreater(d_["t_converge_s"], 13)
            self.assertLess(d_["t_converge_s"], 18)

    def test_convergence_not_reached_exit3(self):
        # 永遠在 ±200ms 徘徊 → exit 3、converged false
        with tempfile.TemporaryDirectory() as d:
            csv = os.path.join(d, "probe.csv")
            rows = [(100.0 + t, 1000.0 + t,
                     f"{200 * (1 if t % 2 else -1)}", 0.2, "") for t in range(0, 180)]
            write_csv(csv, rows)
            p = self._run("convergence", "--csv", csv, "--t0-raw", "100.0", ok=False)
            self.assertEqual(p.returncode, 3)
            self.assertFalse(json.loads(p.stdout)["converged"])

    def test_convergence_hold_resets_on_excursion(self):
        # 進 50ms 內 30s 後又彈出去 → 第一段不算，要等第二段滿 60s
        with tempfile.TemporaryDirectory() as d:
            csv = os.path.join(d, "probe.csv")
            rows = []
            for t in range(0, 30):
                rows.append((100.0 + t, 0, "10", 0.2, ""))
            rows.append((130.0, 0, "80", 0.2, ""))      # 彈出
            for t in range(31, 180):
                rows.append((100.0 + t, 0, "10", 0.2, ""))
            write_csv(csv, rows)
            p = self._run("convergence", "--csv", csv, "--t0-raw", "100.0")
            d_ = json.loads(p.stdout)
            self.assertGreater(d_["t_converge_s"], 30)

    def test_calibrate_slope(self):
        # offset 以 −0.01 ms/s 下降 → client 快 → client_ppm = +10
        with tempfile.TemporaryDirectory() as d:
            csv = os.path.join(d, "cal.csv")
            rows = [(100.0 + t, 0, f"{50 - 0.01 * t:.4f}", 0.2, "")
                    for t in range(0, 1800)]
            write_csv(csv, rows)
            out = os.path.join(d, "calibration.json")
            self._run("calibrate", "--csv", csv, "--out", out)
            cal = json.load(open(out))
            self.assertAlmostEqual(cal["client_ppm"], 10.0, places=1)

    def test_soak_verdict(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "ping.txt"), "w") as f:
                f.write("1440000 packets transmitted, 1440000 received, 0% packet loss, time 14400000ms\n")
            with open(os.path.join(d, "steps.csv"), "w") as f:
                f.write("raw_s,wall_s,kind,jump_ms\n100.0,0,hb,\n")
            with open(os.path.join(d, "sentinel.csv"), "w") as f:
                f.write("raw_s,wall_s,kind,wall_elapsed_ms,raw_elapsed_ms\n100.0,0,hb,,\n")
            with open(os.path.join(d, "journal-errors.txt"), "w") as f:
                f.write("")
            p = self._run("soak-verdict", "--dir", d)
            self.assertIn("PASS", p.stdout)
            # 加一個 step 事件 → FAIL（exit 3）
            with open(os.path.join(d, "steps.csv"), "a") as f:
                f.write("200.0,0,jump,401.0\n")
            p = self._run("soak-verdict", "--dir", d, ok=False)
            self.assertEqual(p.returncode, 3)
            self.assertIn("FAIL", p.stdout)
```

- [ ] **Step 2: 跑測試確認 fail**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: `TestAnalyze` 5 個 FAIL，其餘 19 個 PASS

- [ ] **Step 3: 寫 `lib/analyze.py`**

```python
#!/usr/bin/env python3
"""analyze.py — turn probe/monitor CSVs into convergence times, calibration and verdicts.

Subcommands:
  convergence  --csv F --t0-raw T [--threshold-ms 50] [--hold-s 60]
               JSON to stdout; exit 0 converged / 3 not converged.
               收斂定義（全實驗統一）：|offset| < threshold 持續 hold_s，
               取首次進入時刻（相對 t0-raw，單位秒）。樣本斷流 > 5s 視為 run 中斷。
  calibrate    --csv F --out calibration.json
               最小平方法斜率 → client_ppm = -slope_ms_per_s * 1000。
  soak-verdict --dir D [--expect-steps 0]
               讀 ping.txt / steps.csv / sentinel.csv / journal-errors.txt
               → verdict.md + verdict.json；exit 0 PASS / 3 FAIL。
  exp1-summary --results-dir D
               掃 D/cell-*/result.json → markdown 彙總表。
"""
import argparse
import json
import os
import re
import sys


def read_probe_csv(path):
    """[(raw_s, offset_ms)]，跳過量測失敗列。"""
    out = []
    with open(path) as f:
        next(f)  # header
        for line in f:
            parts = line.rstrip("\n").split(",")
            if len(parts) < 5 or parts[4].strip():
                continue
            if parts[2] == "":
                continue
            out.append((float(parts[0]), float(parts[2])))
    return out


def find_convergence(samples, t0, threshold_ms, hold_s, max_gap_s=5.0):
    """首次 |offset|<threshold 連續 hold_s 的進入時刻（相對 t0），找不到回 None。"""
    run_start = None
    prev_raw = None
    for raw, off in samples:
        if raw < t0:
            continue
        if run_start is not None and prev_raw is not None and raw - prev_raw > max_gap_s:
            run_start = None  # probe 斷流，重新計
        if abs(off) < threshold_ms:
            if run_start is None:
                run_start = raw
            if raw - run_start >= hold_s:
                return run_start - t0
        else:
            run_start = None
        prev_raw = raw
    return None


def cmd_convergence(args):
    samples = read_probe_csv(args.csv)
    t = find_convergence(samples, args.t0_raw, args.threshold_ms, args.hold_s)
    last = samples[-1][1] if samples else None
    result = {
        "converged": t is not None,
        "t_converge_s": round(t, 1) if t is not None else None,
        "threshold_ms": args.threshold_ms, "hold_s": args.hold_s,
        "samples": len(samples), "last_offset_ms": last,
    }
    print(json.dumps(result))
    return 0 if t is not None else 3


def cmd_calibrate(args):
    samples = read_probe_csv(args.csv)
    if len(samples) < 60:
        sys.exit(f"calibrate: 樣本太少（{len(samples)} < 60）")
    n = len(samples)
    mx = sum(s[0] for s in samples) / n
    my = sum(s[1] for s in samples) / n
    sxx = sum((s[0] - mx) ** 2 for s in samples)
    sxy = sum((s[0] - mx) * (s[1] - my) for s in samples)
    slope = sxy / sxx  # ms/s
    cal = {
        "client_ppm": round(-slope * 1000, 3),
        "slope_ms_per_s": round(slope, 6),
        "n": n,
        "duration_s": round(samples[-1][0] - samples[0][0], 1),
    }
    with open(args.out, "w") as f:
        json.dump(cal, f, indent=1)
    print(json.dumps(cal))
    return 0


def count_csv_kind(path, kind):
    if not os.path.exists(path):
        return None
    cnt = 0
    with open(path) as f:
        next(f, None)
        for line in f:
            parts = line.split(",")
            if len(parts) >= 3 and parts[2] == kind:
                cnt += 1
    return cnt


def cmd_soak_verdict(args):
    d = args.dir
    checks = []  # (name, value_desc, ok)
    ping_path = os.path.join(d, "ping.txt")
    if os.path.exists(ping_path):
        m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received",
                      open(ping_path).read())
        if m:
            tx, rx = int(m.group(1)), int(m.group(2))
            checks.append(("ping 0 丟包", f"{tx} tx / {rx} rx / lost {tx - rx}", tx == rx and tx > 0))
        else:
            checks.append(("ping 0 丟包", "ping.txt 沒有 summary（被 kill -9?）", False))
    else:
        checks.append(("ping 0 丟包", "ping.txt 不存在", False))
    steps = count_csv_kind(os.path.join(d, "steps.csv"), "jump")
    checks.append((f"step 事件 ≤ {args.expect_steps}",
                   f"{steps} 筆" if steps is not None else "steps.csv 不存在",
                   steps is not None and steps <= args.expect_steps))
    miss = count_csv_kind(os.path.join(d, "sentinel.csv"), "miss")
    back = count_csv_kind(os.path.join(d, "sentinel.csv"), "backward")
    ok_sent = miss is not None and miss == 0 and back == 0
    checks.append(("lease sentinel 0 miss/backward",
                   f"miss={miss} backward={back}" if miss is not None else "sentinel.csv 不存在",
                   ok_sent))
    je_path = os.path.join(d, "journal-errors.txt")
    if os.path.exists(je_path):
        nerr = sum(1 for line in open(je_path) if line.strip())
        checks.append(("journal 無 error", f"{nerr} 行", nerr == 0))
    else:
        checks.append(("journal 無 error", "journal-errors.txt 不存在", False))

    verdict = all(ok for _, _, ok in checks)
    lines = [f"# soak verdict: {'PASS' if verdict else 'FAIL'}", "",
             "| 判準 | 實測 | 結果 |", "|---|---|---|"]
    for name, val, ok in checks:
        lines.append(f"| {name} | {val} | {'✅' if ok else '❌'} |")
    md = "\n".join(lines) + "\n"
    with open(os.path.join(d, "verdict.md"), "w") as f:
        f.write(md)
    with open(os.path.join(d, "verdict.json"), "w") as f:
        json.dump({"pass": verdict,
                   "checks": [{"name": n, "value": v, "ok": o} for n, v, o in checks]},
                  f, ensure_ascii=False, indent=1)
    print(md)
    return 0 if verdict else 3


def cmd_exp1_summary(args):
    rows = []
    for name in sorted(os.listdir(args.results_dir)):
        rj = os.path.join(args.results_dir, name, "result.json")
        if not os.path.exists(rj):
            continue
        r = json.load(open(rj))
        rows.append(r)
    rows.sort(key=lambda r: (r.get("duration_h", 0), r.get("ppm", 0)))
    lines = ["| cell | 折疊 offset (ms) | ppm（注入/有效） | 收斂 | t_converge (s) |",
             "|---|---|---|---|---|"]
    for r in rows:
        eff = r.get("effective_ppm")
        lines.append("| {} | {} | {} / {} | {} | {} |".format(
            r.get("cell", "?"), r.get("injected_offset_ms", "?"),
            r.get("ppm", "?"), eff if eff is not None else "—",
            "✅" if r.get("converged") else "❌（timeout）",
            r.get("t_converge_s", "—")))
    md = "\n".join(lines) + "\n"
    out = os.path.join(args.results_dir, "summary.md")
    with open(out, "w") as f:
        f.write(md)
    print(md)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("convergence")
    s.add_argument("--csv", required=True)
    s.add_argument("--t0-raw", type=float, required=True)
    s.add_argument("--threshold-ms", type=float, default=50.0)
    s.add_argument("--hold-s", type=float, default=60.0)
    s.set_defaults(fn=cmd_convergence)
    s = sub.add_parser("calibrate")
    s.add_argument("--csv", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_calibrate)
    s = sub.add_parser("soak-verdict")
    s.add_argument("--dir", required=True)
    s.add_argument("--expect-steps", type=int, default=0)
    s.set_defaults(fn=cmd_soak_verdict)
    s = sub.add_parser("exp1-summary")
    s.add_argument("--results-dir", required=True)
    s.set_defaults(fn=cmd_exp1_summary)
    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試確認 pass**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 24 tests PASS

- [ ] **Step 5: Commit**

```bash
git add experiments/timesyncd/lib/analyze.py experiments/timesyncd/tests/test_lib.py
git commit --no-gpg-sign -m "timesyncd-drift-lab: analyze 收斂判定/校準/soak verdict + 合成 CSV 測試"
```

---

### Task 6: `lib/common.sh`（shell 共用層 + cell 生命週期）

**Files:**
- Create: `experiments/timesyncd/lib/common.sh`

只在 Linux VM 上執行（Mac 上僅 `bash -n` 驗語法）。被所有 setup / run script `source`。核心是 `run_recovery_cell`——exp1 / exp2 共用的「注入 → 啟動 → 等收斂 → 落檔 → 復原」生命週期（DRY）。

- [ ] **Step 1: 寫 `lib/common.sh`**

```bash
#!/usr/bin/env bash
# common.sh — timesyncd drift lab 共用函式。source 它，不要直接執行。
# 鐵則：iptables 只動「OUTPUT + udp dport 123」的規則；永不碰 INPUT、永不碰 TCP。

EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$EXP_ROOT/lib"
PY=python3

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

load_env() {
  [[ -f "$EXP_ROOT/env.sh" ]] || die "缺 $EXP_ROOT/env.sh（從 env.example.sh 複製後填值）"
  # shellcheck disable=SC1091
  source "$EXP_ROOT/env.sh"
  : "${SERVER_IP:?env.sh 缺 SERVER_IP}"
  : "${NTP_PORT:=123}"
  : "${RESULTS_DIR:=$EXP_ROOT/results}"
  mkdir -p "$RESULTS_DIR"
}

require_root() { [[ $EUID -eq 0 ]] || die "需要 root（sudo -i 後執行）"; }

raw_now() { $PY -c 'import time;print(f"{time.clock_gettime(time.CLOCK_MONOTONIC_RAW):.3f}")'; }
mono_now() { $PY -c 'import time;print(f"{time.clock_gettime(time.CLOCK_MONOTONIC):.3f}")'; }

ntp_offset_ms() {  # 中位數 3 次 oneshot；失敗回非零
  $PY "$LIB_DIR/ntp_probe.py" oneshot --server "$SERVER_IP" --port "$NTP_PORT" --samples 3
}

# ---------- iptables（鐵則範圍內） ----------
block_ntp() {
  iptables -C OUTPUT -p udp --dport 123 -j DROP 2>/dev/null \
    || iptables -I OUTPUT -p udp --dport 123 -j DROP
  log "NTP 出向流量已封鎖（OUTPUT udp/123 DROP）"
}
unblock_ntp() {
  while iptables -C OUTPUT -p udp --dport 123 -j DROP 2>/dev/null; do
    iptables -D OUTPUT -p udp --dport 123 -j DROP
  done
}
ntp_counter_add() {  # exp4 封包計數：ACCEPT 規則（OUTPUT policy 本來就 ACCEPT，無行為差異）
  iptables -C OUTPUT -p udp --dport 123 -j ACCEPT 2>/dev/null \
    || iptables -I OUTPUT -p udp --dport 123 -j ACCEPT
}
ntp_counter_read() {  # 印 "pkts bytes"
  iptables -L OUTPUT -v -x -n | awk '/udp dpt:123/ && /ACCEPT/ {print $1, $2; exit}'
}
ntp_counter_del() {
  while iptables -C OUTPUT -p udp --dport 123 -j ACCEPT 2>/dev/null; do
    iptables -D OUTPUT -p udp --dport 123 -j ACCEPT
  done
}

# ---------- preflight ----------
preflight() {
  require_root
  command -v timedatectl >/dev/null || die "找不到 timedatectl"
  systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1 \
    || die "systemd-timesyncd 未安裝"
  command -v iptables >/dev/null || die "找不到 iptables"
  local cs qga="inactive"
  cs="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
  systemctl is-active qemu-guest-agent >/dev/null 2>&1 && qga="active"
  if [[ "$qga" == active ]]; then
    log "警告：qemu-guest-agent 在跑。PVE 的 guest-set-time（如 vzdump/migration 後）會污染注入誤差。"
    log "建議實驗窗口內：systemctl stop qemu-guest-agent（實驗後再啟）"
  fi
  [[ "$cs" == "kvm-clock" ]] || log "警告：clocksource=$cs（預期 kvm-clock），記錄備查"
  ping -c 2 -W 2 "$SERVER_IP" >/dev/null || die "ping 不到 SERVER_IP=$SERVER_IP"
  cat > "$RESULTS_DIR/preflight.json" <<EOF
{"clocksource": "$cs", "qemu_guest_agent": "$qga",
 "kernel": "$(uname -r)", "date_utc": "$(date -u +%FT%TZ)"}
EOF
  log "preflight OK（clocksource=$cs, qga=$qga）"
}

# ---------- 狀態重置（每 cell 前後） ----------
reset_clock_state() {
  systemctl stop systemd-timesyncd 2>/dev/null || true
  unblock_ntp
  $PY "$LIB_DIR/clock_inject.py" reset
  local i off
  for i in 1 2 3 4 5; do
    off="$(ntp_offset_ms)" || die "reset_clock_state: 量不到 server offset"
    # off = server - client；把 client 撥 +off 就對齊 server
    if $PY -c "import sys; sys.exit(0 if abs(float('$off')) < 5 else 1)"; then
      log "reset_clock_state 完成（|offset| = ${off}ms < 5ms）"
      return 0
    fi
    $PY "$LIB_DIR/clock_inject.py" set-offset --ms "$off"
    sleep 1
  done
  die "reset_clock_state: 5 次校正後仍未進 5ms（最後 offset=${off}ms）"
}

# ---------- 背景監視器 ----------
start_probe() {  # $1 = csv 路徑；pid 落同目錄 probe.pid
  $PY "$LIB_DIR/ntp_probe.py" run --server "$SERVER_IP" --port "$NTP_PORT" --csv "$1" &
  echo $! > "$(dirname "$1")/probe.pid"
}
stop_probe() {  # $1 = csv 路徑
  local pidfile; pidfile="$(dirname "$1")/probe.pid"
  [[ -f "$pidfile" ]] && { kill "$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile"; }
}
start_step_detector() {  # $1 = csv
  $PY "$LIB_DIR/step_detector.py" --csv "$1" &
  echo $! > "$(dirname "$1")/steps.pid"
}
stop_step_detector() {
  local pidfile; pidfile="$(dirname "$1")/steps.pid"
  [[ -f "$pidfile" ]] && { kill "$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile"; }
}

# ---------- 注入 ----------
inject_ppm() {  # $1 = ppm（可 0；±100 倍數走 tick，其餘走 freq）
  local ppm=$1
  [[ "$ppm" == 0 ]] && return 0
  if (( ppm % 100 == 0 )); then
    $PY "$LIB_DIR/clock_inject.py" set-tick --ppm "$ppm"
  else
    $PY "$LIB_DIR/clock_inject.py" set-freq --ppm "$ppm"
  fi
}

# ---------- 收斂等待 ----------
wait_convergence() {  # $1=probe.csv $2=t0_raw $3=timeout_s；stdout=analyze JSON；rc 0/3
  local csv=$1 t0=$2 timeout=$3 t_start elapsed out rc
  t_start=$(raw_now)
  while true; do
    sleep 15
    set +e
    out="$($PY "$LIB_DIR/analyze.py" convergence --csv "$csv" --t0-raw "$t0" 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then echo "$out"; return 0; fi
    elapsed=$($PY -c "print($(raw_now) - $t_start)")
    if $PY -c "import sys; sys.exit(0 if $elapsed > $timeout else 1)"; then
      echo "$out"; return 3
    fi
  done
}

wait_synced() {  # 啟動 timesyncd 並等 |offset| < $1 ms（預設 5），最多 $2 秒（預設 300）
  local thr=${1:-5} max=${2:-300} i off
  systemctl start systemd-timesyncd
  for i in $(seq 1 $((max / 5))); do
    sleep 5
    off="$(ntp_offset_ms)" || continue
    if $PY -c "import sys; sys.exit(0 if abs(float('$off')) < $thr else 1)"; then
      log "已收斂（offset=${off}ms < ${thr}ms）"
      return 0
    fi
  done
  die "wait_synced: ${max}s 內未收斂到 ${thr}ms"
}

# ---------- exp1/exp2 共用：單一 recovery cell ----------
# run_recovery_cell <outdir> <offset_ms> <ppm> <timeout_s>
# 需要時 export WITH_STEP_DETECTOR=1。產出 outdir/{probe.csv,convergence.json,result.json}
run_recovery_cell() {
  local outdir=$1 offset_ms=$2 ppm=$3 timeout_s=$4 rc=0 t0
  mkdir -p "$outdir"
  # trap：不管成功失敗都復原（恢復連線、清暫存器、停監視器）
  trap 'stop_probe "$outdir/probe.csv"; [[ "${WITH_STEP_DETECTOR:-0}" == 1 ]] && stop_step_detector "$outdir/steps.csv"; reset_clock_state' RETURN
  reset_clock_state
  inject_ppm "$ppm"
  if [[ "$offset_ms" != 0 ]]; then
    $PY "$LIB_DIR/clock_inject.py" set-offset --ms "$offset_ms"
  fi
  start_probe "$outdir/probe.csv"
  [[ "${WITH_STEP_DETECTOR:-0}" == 1 ]] && start_step_detector "$outdir/steps.csv"
  sleep 2  # 讓 probe 先記到注入後、timesyncd 啟動前的基線
  t0=$(raw_now)
  systemctl start systemd-timesyncd
  set +e
  wait_convergence "$outdir/probe.csv" "$t0" "$timeout_s" > "$outdir/convergence.json"
  rc=$?
  set -e
  echo "$t0" > "$outdir/t0_raw"
  return $rc
}

# write_result <outdir> <cell> <duration_h> <ppm> <offset_ms>
# 合併 convergence.json + cell 中繼資料 + calibration → result.json
write_result() {
  local outdir=$1 cell=$2 duration_h=$3 ppm=$4 offset_ms=$5
  $PY - "$outdir" "$cell" "$duration_h" "$ppm" "$offset_ms" "$RESULTS_DIR/calibration.json" <<'PYEOF'
import json, os, sys
outdir, cell, dh, ppm, off, calpath = sys.argv[1:7]
r = json.load(open(os.path.join(outdir, "convergence.json")))
r.update(cell=cell, duration_h=float(dh), ppm=float(ppm), injected_offset_ms=float(off))
if os.path.exists(calpath):
    cal = json.load(open(calpath))
    r["client_ppm"] = cal["client_ppm"]
    r["effective_ppm"] = round(float(ppm) + cal["client_ppm"], 3)
json.dump(r, open(os.path.join(outdir, "result.json"), "w"), indent=1)
print(json.dumps(r))
PYEOF
}

# ---------- detach（SSH 斷線存活） ----------
# detach_self <unit名> <原始參數...>：用 systemd-run 重新執行自己（去掉 --detach）
detach_self() {
  local unit=$1; shift
  systemd-run --unit="tsexp-$unit" --collect \
    --property=WorkingDirectory="$EXP_ROOT" \
    "$(realpath "$0")" "$@"
  log "已 detach 成 transient unit tsexp-$unit"
  log "查進度： systemctl status tsexp-$unit ；journal： journalctl -u tsexp-$unit -f"
}
```

- [ ] **Step 2: 語法驗證（Mac 可跑）**

```bash
bash -n experiments/timesyncd/lib/common.sh && echo SYNTAX-OK
```
Expected: `SYNTAX-OK`

- [ ] **Step 3: Commit**

```bash
git add experiments/timesyncd/lib/common.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: common.sh 共用層（preflight/重置/注入/收斂/detach）"
```

---

### Task 7: `setup/setup-server.sh` + `setup/setup-client.sh`

**Files:**
- Create: `experiments/timesyncd/setup/setup-server.sh`、`experiments/timesyncd/setup/setup-client.sh`

- [ ] **Step 1: 寫 `setup/setup-server.sh`（在 24.04 server VM 上跑）**

```bash
#!/usr/bin/env bash
# setup-server.sh — Ubuntu 24.04 server VM：chrony 設成 LAN NTP server（一次性）。
# 用法：sudo ./setup-server.sh [--allow 192.168.0.0/16]
set -euo pipefail

ALLOW="0.0.0.0/0"
[[ "${1:-}" == "--allow" ]] && ALLOW="$2"
[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq chrony

cat > /etc/chrony/conf.d/driftlab.conf <<EOF
# timesyncd drift lab：對 LAN 提供 NTP
allow ${ALLOW}
# 上游斷線時仍以本機時鐘繼續服務（lab server 角色，stratum 8 防汙染真實 NTP 階層）
local stratum 8
EOF

systemctl restart chrony
sleep 3
chronyc tracking
echo "setup-server: OK。client 端把這台 IP 填進 env.sh 的 SERVER_IP。"
```

- [ ] **Step 2: 寫 `setup/setup-client.sh`（在 22.04 client VM 上跑）**

```bash
#!/usr/bin/env bash
# setup-client.sh — Ubuntu 22.04 client VM：timesyncd 指向 lab server + 實驗依賴 + 安全網。
# 用法：sudo ./setup-client.sh   （需先把 env.example.sh 複製成 env.sh 填好）
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
require_root

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iputils-ping iproute2 iptables python3

# 同一台不能有第二個 NTP client 搶 clock
if systemctl is-active chrony >/dev/null 2>&1; then
  die "client 上跑著 chrony，會跟 timesyncd 打架。先 systemctl disable --now chrony"
fi

# timesyncd 指向 lab server（drop-in，不動主設定檔）
mkdir -p /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/99-driftlab.conf <<EOF
[Time]
NTP=${SERVER_IP}
FallbackNTP=
EOF

# exp4 資源監測需要 accounting
mkdir -p /etc/systemd/system/systemd-timesyncd.service.d
cat > /etc/systemd/system/systemd-timesyncd.service.d/99-driftlab.conf <<EOF
[Service]
CPUAccounting=yes
MemoryAccounting=yes
EOF

systemctl daemon-reload
timedatectl set-ntp true
systemctl restart systemd-timesyncd
sleep 5
timedatectl timesync-status | head -8

preflight
echo "setup-client: OK。下一步：sudo ./setup/calibrate.sh"
```

- [ ] **Step 3: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/setup/setup-server.sh
bash -n experiments/timesyncd/setup/setup-client.sh
chmod +x experiments/timesyncd/setup/*.sh
git add experiments/timesyncd/setup
git commit --no-gpg-sign -m "timesyncd-drift-lab: server/client 一次性 setup scripts"
```

---

### Task 8: `setup/calibrate.sh`（天然漂移校準）

**Files:**
- Create: `experiments/timesyncd/setup/calibrate.sh`

spec 決策 4：停 timesyncd、歸零暫存器，量 30–60 分鐘天然基線 → `results/calibration.json`。兩台不同實體機時這一步把晶振天然相對漂移（±幾 ppm）變成已知量。

- [ ] **Step 1: 寫 `setup/calibrate.sh`**

```bash
#!/usr/bin/env bash
# calibrate.sh — 量 client 天然漂移基線（預設 30 分鐘）。
# 用法：sudo ./calibrate.sh [--minutes 30] [--detach]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
require_root

MINUTES=30
DETACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    --detach) DETACH=1; shift ;;
    *) die "未知參數 $1" ;;
  esac
done
if [[ "$DETACH" == 1 ]]; then
  detach_self calibrate --minutes "$MINUTES"
  exit 0
fi

OUT="$RESULTS_DIR/calibration"
mkdir -p "$OUT"
preflight
trap 'stop_probe "$OUT/probe.csv"; systemctl start systemd-timesyncd' EXIT

reset_clock_state            # 含停 timesyncd、暫存器歸零、步進回真時
start_probe "$OUT/probe.csv"
log "校準中：timesyncd 已停、暫存器歸零，free-run 量 ${MINUTES} 分鐘…"
sleep "$((MINUTES * 60))"
stop_probe "$OUT/probe.csv"

$PY "$LIB_DIR/analyze.py" calibrate --csv "$OUT/probe.csv" --out "$RESULTS_DIR/calibration.json"
log "校準完成 → $RESULTS_DIR/calibration.json"
```

- [ ] **Step 2: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/setup/calibrate.sh
chmod +x experiments/timesyncd/setup/calibrate.sh
git add experiments/timesyncd/setup/calibrate.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: 天然漂移校準 script"
```

---

### Task 9: `run/exp1-drift-recovery.sh`（25 cells 失聯恢復）

**Files:**
- Create: `experiments/timesyncd/run/exp1-drift-recovery.sh`

矩陣（spec）：主 3 時長 {1,4,24}h × 7 ppm {0,±10,±100,±1000} = 21 cells + 邊界探針 {±400,±500} × 1h = 4 cells。折疊公式 `offset_ms = duration_h × 3600 × ppm / 1000`。斷點續跑 = 跳過已有 `result.json` 的 cell。

- [ ] **Step 1: 寫 `run/exp1-drift-recovery.sh`**

```bash
#!/usr/bin/env bash
# exp1-drift-recovery.sh — NTP 失聯 × 頻率誤差恢復實驗（數學折疊後只跑恢復段）。
# 用法：
#   sudo ./exp1-drift-recovery.sh --duration-h 4 --ppm -100   # 單 cell
#   sudo ./exp1-drift-recovery.sh --all                       # 25 cells，斷點續跑
#   sudo ./exp1-drift-recovery.sh --detach                    # detached 跑 --all
#   ./exp1-drift-recovery.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

EXP_DIR="$RESULTS_DIR/exp1"
TIMEOUT_S="${EXP1_TIMEOUT_S:-1800}"   # ±1000ppm cells 預期吃滿（spec：non-convergent 本身是 finding）

# 25 cells："duration_h ppm"
CELLS=()
for d in 1 4 24; do
  for p in 0 10 -10 100 -100 1000 -1000; do CELLS+=("$d $p"); done
done
for p in 400 -400 500 -500; do CELLS+=("1 $p"); done

cell_dir() { echo "$EXP_DIR/cell-${1}h_${2}ppm"; }

run_cell() {
  local d=$1 p=$2 outdir offset_ms rc=0
  outdir="$(cell_dir "$d" "$p")"
  if [[ -f "$outdir/result.json" ]]; then
    log "skip ${d}h × ${p}ppm（已有 result.json）"
    return 0
  fi
  offset_ms="$($PY -c "print(round($d * 3600 * $p / 1000, 3))")"
  log "=== cell ${d}h × ${p}ppm：折疊 offset=${offset_ms}ms，殘留 ppm=${p}，timeout=${TIMEOUT_S}s ==="
  set +e
  run_recovery_cell "$outdir" "$offset_ms" "$p" "$TIMEOUT_S"
  rc=$?
  set -e
  write_result "$outdir" "${d}h_${p}ppm" "$d" "$p" "$offset_ms"
  if [[ $rc -eq 3 ]]; then
    log "cell ${d}h × ${p}ppm 未收斂（timeout ${TIMEOUT_S}s）——±1000ppm 預期如此，已記錄"
  fi
}

case "${1:-}" in
  --status)
    systemctl status tsexp-exp1 --no-pager 2>/dev/null || true
    done_cells=$(find "$EXP_DIR" -name result.json 2>/dev/null | wc -l | tr -d ' ')
    echo "已完成 cell：${done_cells} / 25"
    [[ -f "$EXP_DIR/summary.md" ]] && cat "$EXP_DIR/summary.md" || true
    exit 0 ;;
  --detach)
    require_root
    detach_self exp1 --all
    exit 0 ;;
  --all)
    require_root
    preflight
    mkdir -p "$EXP_DIR"
    for cell in "${CELLS[@]}"; do
      # shellcheck disable=SC2086
      run_cell $cell
    done
    $PY "$LIB_DIR/analyze.py" exp1-summary --results-dir "$EXP_DIR"
    log "exp1 全部完成 → $EXP_DIR/summary.md" ;;
  --duration-h)
    [[ "${3:-}" == "--ppm" ]] || die "用法：--duration-h X --ppm Y"
    require_root
    preflight
    mkdir -p "$EXP_DIR"
    run_cell "$2" "$4" ;;
  *)
    die "用法見檔頭註解（--all / --duration-h X --ppm Y / --status / --detach）" ;;
esac
```

- [ ] **Step 2: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/run/exp1-drift-recovery.sh
chmod +x experiments/timesyncd/run/exp1-drift-recovery.sh
git add experiments/timesyncd/run/exp1-drift-recovery.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: exp1 失聯恢復 25 cells（折疊注入 + 斷點續跑）"
```

---

### Task 10: `run/exp2-slew-399ms.sh`（0.4s 門檻兩側對照）

**Files:**
- Create: `experiments/timesyncd/run/exp2-slew-399ms.sh`

399ms（`NTP_MAX_ADJUST` 門檻下 1ms → 純 PLL slew，預測 ≈16s）vs 401ms（門檻上 1ms → step，秒級）。重點不是快慢而是**連續 vs 不連續**——所以這兩 cell 都開 step detector：399ms 應是一串 ≤10ms 的遞減小事件、401ms 應是單一 ≈400ms 事件。

- [ ] **Step 1: 寫 `run/exp2-slew-399ms.sh`**

```bash
#!/usr/bin/env bash
# exp2-slew-399ms.sh — NTP_MAX_ADJUST(0.4s) 門檻兩側 1ms 的對照實驗。
# 用法：sudo ./exp2-slew-399ms.sh [--detach] ；./exp2-slew-399ms.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

EXP_DIR="$RESULTS_DIR/exp2"
TIMEOUT_S=600

case "${1:-}" in
  --status)
    systemctl status tsexp-exp2 --no-pager 2>/dev/null || true
    for c in 399 401; do
      [[ -f "$EXP_DIR/cell-${c}ms/result.json" ]] && { echo "--- ${c}ms ---"; cat "$EXP_DIR/cell-${c}ms/result.json"; } || true
    done
    exit 0 ;;
  --detach)
    require_root; detach_self exp2; exit 0 ;;
  "") ;;
  *) die "用法：sudo ./exp2-slew-399ms.sh [--detach|--status]" ;;
esac

require_root
preflight
mkdir -p "$EXP_DIR"
export WITH_STEP_DETECTOR=1

for ms in 399 401; do
  outdir="$EXP_DIR/cell-${ms}ms"
  if [[ -f "$outdir/result.json" ]]; then
    log "skip ${ms}ms（已有 result.json）"
    continue
  fi
  log "=== cell ${ms}ms（門檻 0.4s 的$( [[ $ms -lt 400 ]] && echo 下 || echo 上 )側）==="
  set +e
  run_recovery_cell "$outdir" "$ms" 0 "$TIMEOUT_S"
  rc=$?
  set -e
  write_result "$outdir" "${ms}ms" 0 0 "$ms"
  # step 事件統計（連續 vs 不連續的 signature）
  jumps=$(grep -c ',jump,' "$outdir/steps.csv" || true)
  maxjump=$(awk -F, '$3=="jump" {v=($4<0?-$4:$4); if (v>m) m=v} END {print m+0}' "$outdir/steps.csv")
  log "cell ${ms}ms：step 事件 ${jumps} 筆，最大單筆 ${maxjump}ms（預期：399ms=一串小事件、401ms=單筆≈400ms）"
  [[ $rc -eq 3 ]] && log "警告：${ms}ms 未在 ${TIMEOUT_S}s 內收斂，違反預測，檢查 probe.csv"
done
log "exp2 完成 → $EXP_DIR"
```

- [ ] **Step 2: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/run/exp2-slew-399ms.sh
chmod +x experiments/timesyncd/run/exp2-slew-399ms.sh
git add experiments/timesyncd/run/exp2-slew-399ms.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: exp2 399/401ms 門檻對照（step detector signature）"
```

---

### Task 11: `run/exp3-restart-sync.sh`（重啟對時 4 cells）

**Files:**
- Create: `experiments/timesyncd/run/exp3-restart-sync.sh`

與 exp1/2 生命週期不同：先把 timesyncd 跑到收斂，**注入 offset 後立刻 restart**（趁 poll 間隔內 timesyncd 沒注意到），量 (a) restart → 首次聯絡 server 的延遲（journal `Contacted time server` 的 monotonic 時戳 − restart 時刻，回答「是否馬上對時」）、(b) → `<50ms` 收斂時間。

- [ ] **Step 1: 寫 `run/exp3-restart-sync.sh`**

```bash
#!/usr/bin/env bash
# exp3-restart-sync.sh — restart 後 timesyncd 是否馬上對時 + 各 offset 修正時間。
# 用法：
#   sudo ./exp3-restart-sync.sh --offset-ms 100      # 單 cell
#   sudo ./exp3-restart-sync.sh --all [--detach]     # 10/50/100/500ms
#   ./exp3-restart-sync.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

EXP_DIR="$RESULTS_DIR/exp3"
TIMEOUT_S=600
CELLS=(10 50 100 500)

run_cell() {
  local ms=$1 outdir t0 t0_mono cursor rc=0 contact_mono contact_latency
  outdir="$EXP_DIR/cell-${ms}ms"
  if [[ -f "$outdir/result.json" ]]; then
    log "skip ${ms}ms（已有 result.json）"
    return 0
  fi
  mkdir -p "$outdir"
  log "=== cell ${ms}ms：收斂 → 注入 → 立刻 restart ==="
  trap 'stop_probe "$outdir/probe.csv"; reset_clock_state' RETURN
  reset_clock_state
  wait_synced 5 300
  start_probe "$outdir/probe.csv"
  sleep 2
  cursor="$(journalctl -u systemd-timesyncd --show-cursor -n 0 2>/dev/null | sed -n 's/^-- cursor: //p')"
  # 注入後「立刻」restart：兩行之間不能有等待
  $PY "$LIB_DIR/clock_inject.py" set-offset --ms "$ms"
  t0=$(raw_now); t0_mono=$(mono_now)
  systemctl restart systemd-timesyncd
  set +e
  wait_convergence "$outdir/probe.csv" "$t0" "$TIMEOUT_S" > "$outdir/convergence.json"
  rc=$?
  set -e
  # journal：restart 後第一次真的打出去的時間（CLOCK_MONOTONIC，不受注入影響）
  journalctl -u systemd-timesyncd --after-cursor "$cursor" -o short-monotonic \
    > "$outdir/journal.txt" 2>/dev/null || true
  # short-monotonic 的時戳右對齊有補空白（如 "[    5.123456]"），用 sed 而非 awk $1
  contact_mono="$(sed -n 's/^\[ *\([0-9.]*\)\].*Contacted time server.*/\1/p' "$outdir/journal.txt" | head -1)"
  if [[ -n "$contact_mono" ]]; then
    contact_latency="$($PY -c "print(round($contact_mono - $t0_mono, 3))")"
  else
    contact_latency=null
  fi
  $PY - "$outdir" "$ms" "$contact_latency" <<'PYEOF'
import json, os, sys
outdir, ms, lat = sys.argv[1:4]
r = json.load(open(os.path.join(outdir, "convergence.json")))
r.update(cell=f"restart_{ms}ms", injected_offset_ms=float(ms),
         contact_latency_s=None if lat == "null" else float(lat))
json.dump(r, open(os.path.join(outdir, "result.json"), "w"), indent=1)
print(json.dumps(r))
PYEOF
  [[ $rc -eq 3 ]] && log "警告：${ms}ms 未在 ${TIMEOUT_S}s 內收斂，違反預測"
}

case "${1:-}" in
  --status)
    systemctl status tsexp-exp3 --no-pager 2>/dev/null || true
    for ms in "${CELLS[@]}"; do
      [[ -f "$EXP_DIR/cell-${ms}ms/result.json" ]] && { echo "--- ${ms}ms ---"; cat "$EXP_DIR/cell-${ms}ms/result.json"; } || true
    done
    exit 0 ;;
  --detach)
    require_root; detach_self exp3 --all; exit 0 ;;
  --all)
    require_root; preflight; mkdir -p "$EXP_DIR"
    for ms in "${CELLS[@]}"; do run_cell "$ms"; done
    log "exp3 全部完成 → $EXP_DIR" ;;
  --offset-ms)
    require_root; preflight; mkdir -p "$EXP_DIR"
    run_cell "$2" ;;
  *)
    die "用法見檔頭註解（--all / --offset-ms N / --status / --detach）" ;;
esac
```

- [ ] **Step 2: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/run/exp3-restart-sync.sh
chmod +x experiments/timesyncd/run/exp3-restart-sync.sh
git add experiments/timesyncd/run/exp3-restart-sync.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: exp3 重啟對時（journal 首次聯絡延遲 + 收斂時間）"
```

---

### Task 12: `run/exp4-poll256-soak.sh`（6 情境生產級穩定度）

**Files:**
- Create: `experiments/timesyncd/run/exp4-poll256-soak.sh`

生產判準（spec）：100Hz ping 0 丟包、step 0（>1ms 即記）、5s lease sentinel 0 miss、journal 0 error；另收 timesyncd CPU/記憶體與 udp/123 封包數。`--hours` 預設 4（quick），正式建議 24（README 寫明）。

- [ ] **Step 1: 寫 `run/exp4-poll256-soak.sh`**

```bash
#!/usr/bin/env bash
# exp4-poll256-soak.sh — PollIntervalMaxSec=256 生產級穩定度 soak（6 情境）。
# 用法（--detach 必須是第一個參數）：
#   sudo ./exp4-poll256-soak.sh --scenario soak-256 --hours 4
#   sudo ./exp4-poll256-soak.sh --all --hours 4
#   sudo ./exp4-poll256-soak.sh --detach --hours 24    # detached 跑 --all
#   ./exp4-poll256-soak.sh --status
# 情境：baseline-2048 / soak-256 / restart / outage-30m / inject-80ms / jitter
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

EXP_DIR="$RESULTS_DIR/exp4"
HOURS=4
SCENARIOS=(baseline-2048 soak-256 restart outage-30m inject-80ms jitter)
POLL_DROPIN=/etc/systemd/timesyncd.conf.d/50-driftlab-poll.conf

set_poll_max() {  # $1 = 秒數 | default
  if [[ "$1" == default ]]; then
    rm -f "$POLL_DROPIN"
  else
    cat > "$POLL_DROPIN" <<EOF
[Time]
PollIntervalMinSec=32
PollIntervalMaxSec=$1
EOF
  fi
  systemctl restart systemd-timesyncd
}

JCURSOR=""
start_monitors() {  # $1 = outdir
  local d=$1
  start_probe "$d/probe.csv"
  start_step_detector "$d/steps.csv"
  $PY "$LIB_DIR/lease_sentinel.py" --csv "$d/sentinel.csv" &
  echo $! > "$d/sentinel.pid"
  ping -i 0.01 -q "$SERVER_IP" > "$d/ping.txt" 2>&1 &
  echo $! > "$d/ping.pid"
  ntp_counter_add
  ( echo "raw_s,cpu_ns,mem_bytes,ntp_pkts" > "$d/resources.csv"
    while true; do
      sleep 60
      printf '%s,%s,%s,%s\n' "$(raw_now)" \
        "$(systemctl show systemd-timesyncd -p CPUUsageNSec --value)" \
        "$(systemctl show systemd-timesyncd -p MemoryCurrent --value)" \
        "$(ntp_counter_read | awk '{print $1}')" >> "$d/resources.csv"
    done ) &
  echo $! > "$d/resources.pid"
  JCURSOR="$(journalctl -u systemd-timesyncd --show-cursor -n 0 2>/dev/null | sed -n 's/^-- cursor: //p')"
}

stop_monitors() {  # $1 = outdir
  local d=$1 p
  for f in resources.pid sentinel.pid; do
    [[ -f "$d/$f" ]] && { kill "$(cat "$d/$f")" 2>/dev/null || true; rm -f "$d/$f"; }
  done
  if [[ -f "$d/ping.pid" ]]; then
    p="$(cat "$d/ping.pid")"
    kill -INT "$p" 2>/dev/null || true   # SIGINT 讓 ping 印 summary
    for _ in 1 2 3 4 5; do kill -0 "$p" 2>/dev/null || break; sleep 1; done
    rm -f "$d/ping.pid"
  fi
  stop_step_detector "$d/steps.csv"
  stop_probe "$d/probe.csv"
  ntp_counter_del
  journalctl -u systemd-timesyncd --after-cursor "$JCURSOR" -p err --no-pager \
    > "$d/journal-errors.txt" 2>/dev/null || true
}

soak() {  # $1 = outdir, $2 = 秒數, $3 = 中途動作（函式名，可空）
  local d=$1 secs=$2 action=${3:-}
  trap 'stop_monitors "$d"; unblock_ntp; tc qdisc del dev "$CLIENT_IFACE" root 2>/dev/null || true; set_poll_max default' RETURN
  wait_synced 50 600
  start_monitors "$d"
  if [[ -n "$action" ]]; then
    sleep "$((secs / 2))"
    "$action" "$d"
    sleep "$((secs / 2))"
  else
    sleep "$secs"
  fi
  stop_monitors "$d"
}

action_restart() {
  log "中途動作：systemctl restart systemd-timesyncd"
  echo "$(raw_now) restart" >> "$1/events.log"
  systemctl restart systemd-timesyncd
}

action_outage() {
  log "中途動作：封鎖 NTP 30 分鐘"
  echo "$(raw_now) block_ntp" >> "$1/events.log"
  block_ntp
  sleep 1800
  unblock_ntp
  echo "$(raw_now) unblock_ntp" >> "$1/events.log"
}

run_scenario() {
  local name=$1 outdir rc=0
  outdir="$EXP_DIR/$name"
  if [[ -f "$outdir/verdict.json" ]]; then
    log "skip $name（已有 verdict.json）"
    return 0
  fi
  mkdir -p "$outdir"
  log "=== scenario $name（${HOURS}h）==="
  case "$name" in
    baseline-2048)
      set_poll_max default
      soak "$outdir" "$((HOURS * 3600))" ;;
    soak-256)
      set_poll_max 256
      soak "$outdir" "$((HOURS * 3600))" ;;
    restart)
      set_poll_max 256
      soak "$outdir" "$((HOURS * 3600))" action_restart ;;
    outage-30m)
      set_poll_max 256
      soak "$outdir" "$((HOURS * 3600))" action_outage ;;
    inject-80ms)
      local poll sub t0
      for poll in 256 2048; do
        sub="$outdir/poll-$poll"
        mkdir -p "$sub"
        if [[ "$poll" == 2048 ]]; then set_poll_max default; else set_poll_max 256; fi
        trap 'stop_monitors "$sub"; set_poll_max default' RETURN
        wait_synced 50 600
        start_monitors "$sub"
        sleep 600   # 讓 poll interval 自然爬升後再注入
        t0=$(raw_now)
        echo "$t0 inject_80ms" >> "$sub/events.log"
        $PY "$LIB_DIR/clock_inject.py" set-offset --ms 80
        set +e
        wait_convergence "$sub/probe.csv" "$t0" 3600 > "$sub/convergence.json"
        set -e
        stop_monitors "$sub"
        log "inject-80ms @ poll=$poll：$(cat "$sub/convergence.json")"
      done
      # 80ms < 0.4s → 全程 slew，不准有 step
      ;;
    jitter)
      set_poll_max 256
      tc qdisc add dev "$CLIENT_IFACE" root netem delay 5ms 3ms
      soak "$outdir" 3600   # 固定 1 小時（spec）
      tc qdisc del dev "$CLIENT_IFACE" root 2>/dev/null || true ;;
    *) die "未知情境 $name（可用：${SCENARIOS[*]}）" ;;
  esac
  # verdict：inject-80ms 對兩個子目錄各跑一次
  set +e
  if [[ "$name" == inject-80ms ]]; then
    for poll in 256 2048; do
      $PY "$LIB_DIR/analyze.py" soak-verdict --dir "$outdir/poll-$poll"
      [[ $? -ne 0 ]] && rc=3
    done
    [[ $rc -eq 0 ]] && echo '{"pass": true}' > "$outdir/verdict.json" \
                    || echo '{"pass": false}' > "$outdir/verdict.json"
  else
    $PY "$LIB_DIR/analyze.py" soak-verdict --dir "$outdir"
    rc=$?
  fi
  set -e
  [[ $rc -eq 0 ]] && log "scenario $name → PASS" || log "scenario $name → FAIL（看 $outdir/verdict.md）"
  return 0   # FAIL 也繼續跑下一情境，總結看 verdict
}

case "${1:-}" in
  --status)
    systemctl status tsexp-exp4 --no-pager 2>/dev/null || true
    for s in "${SCENARIOS[@]}"; do
      [[ -f "$EXP_DIR/$s/verdict.json" ]] && echo "$s: $(cat "$EXP_DIR/$s/verdict.json")" || true
    done
    exit 0 ;;
  --detach)
    shift
    require_root; detach_self exp4 --all "$@"; exit 0 ;;
  --all)
    shift
    [[ "${1:-}" == "--hours" ]] && { HOURS="$2"; shift 2; }
    require_root; preflight; mkdir -p "$EXP_DIR"
    for s in "${SCENARIOS[@]}"; do run_scenario "$s"; done
    log "exp4 全部完成；各情境 verdict 在 $EXP_DIR/*/verdict.md" ;;
  --scenario)
    name="$2"; shift 2
    [[ "${1:-}" == "--hours" ]] && { HOURS="$2"; shift 2; }
    require_root; preflight; mkdir -p "$EXP_DIR"
    run_scenario "$name" ;;
  *)
    die "用法見檔頭註解（--all / --scenario 名稱 / --status / --detach）" ;;
esac
```

注意（實作者必讀）：

- `jitter` 情境的 netem 只 delay 不 drop，ping 0 丟包判準依然成立；tc 規則在 `soak` 的 RETURN trap 也會清（雙保險）。
- `inject-80ms` 的 `t_converge` 含「偵測延遲（等下一次 poll）+ 修正時間」，256 vs 2048 的差主要在前者；注入落在 poll 週期哪個相位是隨機的，文章解讀時以上界語意呈現。
- `--detach` 後接的 `--hours N` 會原樣傳給 transient unit 內的 `--all`。

- [ ] **Step 2: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/run/exp4-poll256-soak.sh
chmod +x experiments/timesyncd/run/exp4-poll256-soak.sh
git add experiments/timesyncd/run/exp4-poll256-soak.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: exp4 六情境生產級 soak（ping/step/lease/資源監測 + verdict）"
```

---

### Task 13: `run/all.sh`（全套無人值守）

**Files:**
- Create: `experiments/timesyncd/run/all.sh`

每個子 script 自帶斷點續跑（result.json / verdict.json 存在即 skip），`all.sh` 只負責順序與單一進度檔。

- [ ] **Step 1: 寫 `run/all.sh`**

```bash
#!/usr/bin/env bash
# all.sh — 校準 → exp1 → exp2 → exp3 → exp4 全套無人值守，可中斷後重跑（自動續）。
# 用法：sudo ./all.sh [--soak-hours 4] [--detach] ；./all.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOAK_HOURS=4
DETACH=0
STATE="$RESULTS_DIR/all-state.json"

mark() {  # mark <phase> <status>
  $PY - "$STATE" "$1" "$2" <<'PYEOF'
import json, os, sys
path, phase, status = sys.argv[1:4]
d = json.load(open(path)) if os.path.exists(path) else {}
d[phase] = status
json.dump(d, open(path, "w"), indent=1)
PYEOF
}

# while-loop 解析：--soak-hours 與 --detach 任意順序都行
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      systemctl status tsexp-all --no-pager 2>/dev/null || true
      { [[ -f "$STATE" ]] && cat "$STATE"; } || echo "尚未開始"
      exit 0 ;;
    --detach) DETACH=1; shift ;;
    --soak-hours) SOAK_HOURS="$2"; shift 2 ;;
    *) die "用法：sudo ./all.sh [--soak-hours N] [--detach] / --status" ;;
  esac
done

if [[ "$DETACH" == 1 ]]; then
  require_root
  detach_self all --soak-hours "$SOAK_HOURS"
  exit 0
fi

require_root
preflight

if [[ ! -f "$RESULTS_DIR/calibration.json" ]]; then
  mark calibrate running
  "$RUN_DIR/../setup/calibrate.sh" --minutes 30
fi
mark calibrate done

mark exp1 running; "$RUN_DIR/exp1-drift-recovery.sh" --all;                 mark exp1 done
mark exp2 running; "$RUN_DIR/exp2-slew-399ms.sh";                           mark exp2 done
mark exp3 running; "$RUN_DIR/exp3-restart-sync.sh" --all;                   mark exp3 done
mark exp4 running; "$RUN_DIR/exp4-poll256-soak.sh" --all --hours "$SOAK_HOURS"; mark exp4 done

log "全套完成。結果都在 $RESULTS_DIR；scp 回 repo 後 commit。"
```

- [ ] **Step 2: 語法驗證 + Commit**

```bash
bash -n experiments/timesyncd/run/all.sh
chmod +x experiments/timesyncd/run/all.sh
git add experiments/timesyncd/run/all.sh
git commit --no-gpg-sign -m "timesyncd-drift-lab: all.sh 全套無人值守 + 進度檔"
```

---

### Task 14: `experiments/timesyncd/README.md`（agent 執行計畫）

**Files:**
- Create: `experiments/timesyncd/README.md`

這份是「給未來 agent / 使用者照著跑」的計畫書，**不在網站路由內**（`next-site/content` 之外）。zh-TW 敘述 + 英文指令。內容必須完整涵蓋以下大綱，每節含可直接複製的指令與預期輸出：

- [ ] **Step 1: 寫 README.md，結構與必含內容如下**

````markdown
# timesyncd Drift Lab — 執行計畫

（一段導言：四個實驗問題、對應 spec 與兩篇網站文章的連結路徑）

## 0. 前提

- client VM：Ubuntu 22.04（systemd-timesyncd 受測）；server VM：Ubuntu 24.04（chrony）
- 皆可連 apt repo；皆可被你 SSH（root 或可 sudo -i）
- 兩台互通 udp/123 與 icmp
- 實體機配置（建議，不強制；scripts 相同）：實驗 1–3 兩 VM 同實體機更乾淨（同一顆振盪器、
  天然相對漂移 ≈ 0）；實驗 4 分開實體機更好（真實網路路徑、避免 noisy-neighbor 假陽性）。
  只想用一種配置就選分開實體機 + 校準（calibrate.sh 會把天然漂移變成已知量）
- **PVE 注意事項（重要）**：
  - 實驗窗口內停用該 VM 的 vzdump 備份、snapshot、live migration——三者都會凍結/跳動 guest 時鐘，直接汙染資料
  - 建議實驗窗口內 `systemctl stop qemu-guest-agent`（PVE 的 guest-set-time 會改 guest 時鐘）；preflight 會偵測並警告
  - 開跑前先拍 PVE snapshot（hypervisor 權限在你手上；時鐘玩壞了可以整台回滾）
- 實驗會大幅撥動 client 的 CLOCK_REALTIME（最大 ±86.4s）：**client VM 必須是乾淨實驗機**，
  不要掛任何在意時間的 workload（資料庫、cron 任務、TLS 服務）

## 1. 部署

```bash
# 在你的工作機
scp -r experiments/timesyncd root@<CLIENT_IP>:/root/
ssh root@<CLIENT_IP> 'cd /root/timesyncd && cp env.example.sh env.sh && vi env.sh'  # 填 SERVER_IP/CLIENT_IFACE
scp experiments/timesyncd/setup/setup-server.sh root@<SERVER_IP>:/root/
```

## 2. L3 單機驗證（只需要 client VM，先做這個）

原理：`CLOCK_MONOTONIC_RAW` 不受 adjtimex 影響 → fake server 在同一台 VM 上提供「未被打亂的真時」。

```bash
ssh root@<CLIENT_IP>
cd /root/timesyncd
# env.sh 設 SERVER_IP=127.0.0.1
python3 -m unittest discover -s tests -v          # 應 24 PASS
systemd-run --unit=tsexp-fakentp --collect python3 lib/fake_ntp_server.py --bind 127.0.0.1 --port 123
mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=127.0.0.1\nFallbackNTP=\n' > /etc/systemd/timesyncd.conf.d/99-driftlab.conf
systemctl restart systemd-timesyncd
./setup/calibrate.sh --minutes 5                  # L3 煙霧用短校準
./run/exp1-drift-recovery.sh --duration-h 1 --ppm 100   # 預期 ~360ms、十幾秒收斂
./run/exp2-slew-399ms.sh
./run/exp3-restart-sync.sh --offset-ms 100
./run/exp4-poll256-soak.sh --scenario inject-80ms        # exp4 縮時煙霧（自帶結束條件，不吃 --hours）
```

（L3 一節要明列每步預期輸出與 PASS 判準。`--hours` 是整數小時（bash 算式），所以 exp4 的縮時 smoke
選 `inject-80ms`——它以收斂為結束條件、不靠 soak 時長。
L3 驗不到、留給 L4 的清單：真實網路延遲、真 chrony、長時 soak、PVE 排程備份干擾。）

## 3. L4 全套（兩台 VM）

```bash
# server
ssh root@<SERVER_IP> 'bash /root/setup-server.sh'
# client：env.sh 改回真 SERVER_IP，移除 fake server 與 127.0.0.1 設定
systemctl stop tsexp-fakentp 2>/dev/null || true
./setup/setup-client.sh
./run/all.sh --detach --soak-hours 24     # 全套無人值守；正式 soak 24h
./run/all.sh --status                      # 隨時查進度（SSH 重連也行）
```

## 4. 每步預期輸出與 PASS 判準（表格）

| 步驟 | 指令 | 預期 | PASS 判準 |
|---|---|---|---|
| 單元測試 | python3 -m unittest … | 24 tests OK | exit 0 |
| 校準 | calibrate.sh | calibration.json 出現 | `client_ppm` 絕對值 < 50（VM 正常範圍） |
| exp1 單 cell | --duration-h 1 --ppm 100 | result.json converged=true | t_converge 秒級–分鐘級 |
| exp1 ±1000ppm | … | converged=false | timeout 1800s 是預期結果（finding） |
| exp2 | … | 399ms 無大 step、401ms 單一 ≈400ms step | result.json + steps.csv |
| exp3 | … | contact_latency_s 秒級 | 四 cell 都 converged |
| exp4 | … | 各情境 verdict.md | 全 PASS |

## 5. 故障排除

- SSH 斷線：所有長任務都跑在 tsexp-* transient unit 裡，重連後 `--status` / `journalctl -u tsexp-all -f`
- 時鐘玩壞了：`python3 lib/clock_inject.py reset` 後 `systemctl restart systemd-timesyncd`；
  最後手段：PVE snapshot 回滾
- iptables 殘留：`iptables -L OUTPUT -n | grep 123`，手動 `iptables -D OUTPUT -p udp --dport 123 -j DROP`
- tc 殘留：`tc qdisc del dev <iface> root`
- timesyncd 一直不 sync：`timedatectl timesync-status`、檢查 server 端 `chronyc tracking`

## 6. 時間預算

| 階段 | wall-clock |
|---|---|
| L3 全部 | ~1h |
| 校準 | 0.5–1h |
| exp1（25 cells） | ~5–6h（±1000 的 6 cells 各吃滿 30min timeout） |
| exp2 | ~0.5h |
| exp3 | ~1h |
| exp4 quick（4h soak） | ~10h |
| exp4 正式（24h soak） | ~50h |

## 7. 收尾

```bash
# 工作機上
scp -r root@<CLIENT_IP>:/root/timesyncd/results experiments/timesyncd/
git add experiments/timesyncd/results
git commit --no-gpg-sign -m "timesyncd-drift-lab: L4 實測結果"
```
結果進 repo 後，回填網站頁 B 的「在你環境跑後對照」欄位。
````

（以上即 README 的完整骨架；實作時把括號內的指示展開成正式內容，指令一字不改。）

- [ ] **Step 2: Commit**

```bash
git add experiments/timesyncd/README.md
git commit --no-gpg-sign -m "timesyncd-drift-lab: agent 執行計畫 README（L3/L4 步驟、判準、故障排除）"
```

---

### Task 15: 頁 A `timesyncd-drift-lab-methodology.mdx`（實驗方法論）

**Files:**
- Create: `next-site/content/systemd/features/timesyncd-drift-lab-methodology.mdx`

**MDX 規範（兩篇文章共通，違反即退稿）：**
- frontmatter 僅 `layout: doc` + `title:` + `description:`（與既有 timesyncd 篇一致）
- 不 import 任何元件；`<Callout>` 可直接用（全域註冊）
- prose 裸 `<` + 字母/數字會壞 build → 比較式寫 inline code（`` `< 0.4s` ``、`` `< 50ms` ``）
- 程式碼引用用 ` ```c File: linux/kernel/time/ntp.c:130 ` 形式 fence；每個 code block 前一句說明（explain-before-quote）
- zero-fabrication：所有常數 / 函式名 / 行號照 spec 的 source 表，不得新增未驗證的
- zh-TW 台灣用語；never-translate 清單保留英文
- 不放圖（本批不產 PNG；曲線圖等 L4 結果回填時再加）
- 測驗一律放 quiz.json（Task 17），MDX 內不寫 QuizQuestion

**文章結構與每節必含內容**（實作時展開成完整 prose，技術事實一字不差照下表）：

````markdown
---
layout: doc
title: timesyncd Drift Lab — 實驗方法論：怎麼在幾小時內測完 24 小時的失聯漂移
description: 設計一套可重現的 systemd-timesyncd 行為實驗：用數學折疊把 1–24 小時 NTP 失聯壓成零等待、用 adjtimex 三暫存器（SETOFFSET/TICK/FREQUENCY）高保真注入時鐘誤差、用獨立 SNTP probe 量收斂、用 CLOCK_MONOTONIC_RAW 錨定的假 NTP server 做單機驗證。並從 linux/kernel/time/ntp.c 拆穿「kernel slew 上限 500ppm」的 lore：PLL 相位滑動無 ppm 上限（τ≈7.5s 指數衰減）、MAXFREQ ±500ppm 是頻率補償極限、古典 adjtime() 的 500µs/s 才是 lore 出處。
---

## 場景
（從 ceph mon 50ms clock skew 的痛點出發：四個要回答的問題列表 = spec 目標 1–4。
連結既有篇：[斷網時 timesyncd 在做什麼](/systemd/features/timesyncd-outage-and-maintenance)、
[重啟對系統時間的影響](/systemd/features/timesyncd-restart-impact)、
[把 PollIntervalMaxSec 壓低會怎樣](/systemd/features/timesyncd-low-max-poll-simulation)。）

## TL;DR
（表格：四個設計決策 → 一句理由：數學折疊 / 三暫存器注入 / 獨立 probe / RAW 錨定假 server）

## 為什麼不用等真實時間：數學折疊
（核心論證：timesyncd 沒有有效 NTP reply 時完全不碰時鐘（引 outage 篇的 source 證明）
→ 失聯階段是確定性 free-run → 累積 offset = T × F → 直接注入初始條件。
說明為什麼比 10x/100x 時間加速「更準且更快」；恢復階段受 kernel 機制約束、本來就不可加速。）

## adjtimex 三暫存器解剖
（表格 = spec 決策 2 的注入機制表。重點段落：tick 是 timesyncd 與 kernel PLL 都不會改寫的暫存器
（注入後如真實晶振誤差持續存在）；freq register 會被 PLL 改寫但動力學等價——附「真實：晶振 +10ppm、
register 0→−10ppm；模擬：晶振 0、register +10ppm→0」的對照說明。
ADJ_SETOFFSET 原子注入 vs clock_settime 的 race 差異。）

## kernel 三種修正機制、三個上限——「slew 只有 500ppm」是 lore
（本文核心節。表格 = spec 決策 5 的三機制表（含全部 source 行號）。
三個 code block，每個前面一句說明：
1. `ntp.c:130` ntp_offset_chunk / SHIFT_PLL —— 每秒修剩餘 offset 的 1/2^(SHIFT_PLL+tc)，
   τ≈7.5s（tc=1、32s poll），對 399ms 偏移有效速率 ~53ms/s ≈ 53,000ppm，遠超 500ppm lore
2. `timex.h:136` MAXFREQ —— time_freq 硬 clamp ±500ppm：可補償晶振誤差的真極限
3. `ntp.c:43` MAX_TICKADJ —— 古典 adjtime() 固定 500µs/s，這才是 500ppm lore 的出處；
   timesyncd 不走這條
timesyncd 端門檻：`timesyncd-manager.c:52` NTP_MAX_ADJUST=0.4s、`:247` 的 slew/step 判斷。）

## 量測架構：不採信受測物
（probe = raw UDP SNTP query 1Hz、offset = server − client、LAN RTT sub-ms 對 50ms 判準足夠。
收斂判定全實驗統一：|offset| < 50ms 持續 60s。
校準：停 timesyncd 量 30 分鐘天然漂移 → client_ppm 記進每個 cell 的 effective_ppm。）

## 單 kernel 驗證 trick：MONOTONIC_RAW 假 server
（CLOCK_MONOTONIC_RAW 不受 adjtimex 影響 → fake server 錨定它之後，同一顆 kernel 上
REALTIME 被怎麼撥都不影響 server 回的真時。一台 VM 就能端到端驗證整套 rig。
注意事項：必須在注入前啟動。）

## 實驗包在哪
（`experiments/timesyncd/` 的目錄樹 + 一句「每實驗一條指令、SSH 斷線存活、斷點續跑」。
下一篇：[實驗設計與預測](/systemd/features/timesyncd-drift-lab-experiments)。）
````

- [ ] **Step 1: 寫 MDX 全文**（依上述結構展開；所有行號常數對照 spec「核心設計決策 5」的表）
- [ ] **Step 2: 本地驗證**

```bash
cd /Users/ikaros/Documents/code/learning-k8s && make validate
```
Expected: 此時 `projects.ts` 還沒加 slug，validate 對「孤兒 MDX」的行為若報錯，改成先跑
`python3 scripts/validate.py 2>&1 | head -30` 確認只有 slug 未註冊類的錯誤（Task 17 會解）；
frontmatter / 語法類錯誤必須在本 task 修完。

- [ ] **Step 3: Commit**

```bash
git add next-site/content/systemd/features/timesyncd-drift-lab-methodology.mdx
git commit --no-gpg-sign -m "timesyncd-drift-lab: 頁 A 實驗方法論（折疊/注入/量測/單機驗證）"
```

---

### Task 16: 頁 B `timesyncd-drift-lab-experiments.mdx`（實驗設計與結果）

**Files:**
- Create: `next-site/content/systemd/features/timesyncd-drift-lab-experiments.mdx`

MDX 規範同 Task 15。所有預測值照 spec「實驗矩陣」節，**預測與實測明確分欄**：預測欄寫死（source 推導），實測欄一律「＿＿（在你環境跑後對照）」——符合 CLAUDE.md 的 lab 驗證等級（需要真實環境的指令以 source + 文件交叉驗證、標註待實測）。

**文章結構與必含內容：**

````markdown
---
layout: doc
title: timesyncd Drift Lab — 四組實驗設計與 source 推導預測
description: 25 cells 失聯恢復矩陣（1/4/24hr × 0–±1000ppm + MAXFREQ 邊界探針）、399ms vs 401ms 跳錶門檻對照、重啟對時 4 cells、PollIntervalMaxSec=256 的六情境生產級 soak（100Hz ping 0 丟包、step 0、5s lease 0 miss）。每組附 linux/systemd source 推導的預測表與對應執行指令；實測欄留空待環境跑完回填。
---

## 場景
（一段：方法論篇講完「怎麼測才準」，這篇給四組實驗的完整設計、每 cell 預測、跑哪條指令。
連結：[實驗方法論](/systemd/features/timesyncd-drift-lab-methodology)。）

## 共用協定
（每 cell 生命週期 = spec「每 cell 標準生命週期」流程；收斂判定 |offset| < 50ms 持續 60s；
時間預算表 = spec 數字。執行包位置 `experiments/timesyncd/`，部署與前提見包內 README。）

## 實驗 1：失聯恢復（25 cells）
（折疊 offset 矩陣表 = spec 的 6×3 表。
預測表（每列：初始條件 → 機制 → 預測收斂時間 → 實測＿＿）：
- |offset| < 50ms（1h×10ppm = 36ms）：進場即合格，t ≈ 0
- 50–400ms 區（4h×10ppm=144ms、1h×100ppm=360ms）：PLL 相位滑動 τ≈7.5s
  → 144ms ≈ 8s、360ms ≈ 15s（ln(360/50)×7.5）
- > 400ms（其餘大多數 cells）：timesyncd 首個 sample 直接 ADJ_SETOFFSET 跳錶 → 秒級
  （含 24h×1000ppm = 86.4s 的極端 cell 也一樣秒級——跳錶不在乎幅度）
- ±400ppm×1h：跳錶後可鎖定，freq register 還有 100ppm headroom
- ±500ppm×1h：脆弱鎖定——register 頂死 MAXFREQ clamp，天然漂移 ±幾 ppm 即破界
- ±1000ppm：永不穩定收斂（淨漂移 ≥ 500ppm），timeout 1800s 記 non-convergent 是預期 finding
  ——這是生產上「晶振故障 / VM 計時異常」的 signature
指令：`sudo ./run/exp1-drift-recovery.sh --all --detach`，單 cell 與 --status 用法。）

## 實驗 2：399ms vs 401ms——0.4s 門檻的兩側
（NTP_MAX_ADJUST=0.4s（timesyncd-manager.c:52、:247）。預測：399ms 純 slew
ln(399/50)×7.5 ≈ 16s + 首 sample 延遲；401ms 跳錶秒級。
重點段：兩者都是秒級，差異不是快慢而是**連續 vs 不連續**——step detector 的 signature：
399ms = 一串 ≤10ms 遞減小事件、401ms = 單一 ≈400ms 事件。對 ceph lease、TLS、
資料庫 timestamp 而言，不連續才是風險。
指令：`sudo ./run/exp2-slew-399ms.sh`。實測欄＿＿。）

## 實驗 3：重啟後馬上對時嗎？
（4 cells {10,50,100,500ms}。量兩件事：contact_latency_s（journal 首次 Contacted time server
− restart 時刻）與 t_converge。預測：重啟後立即發 query（poll 從 32s min 重爬，首發不等 32s）；
10ms 無感（本來就 < 50ms）、50ms 邊界（判準臨界，靠 hold 60s 分辨）、100ms slew 約 5–10s、
500ms 跳錶秒級。
指令：`sudo ./run/exp3-restart-sync.sh --all`。實測欄＿＿。）

## 實驗 4：PollIntervalMaxSec=256 會不會搞死生產環境？
（判準先行：你的環境「連 2 個 ping 封包都不能掉、5 秒 downtime 都不可接受」→ 六情境表 = spec 表
（情境 / 內容 / 判準三欄照抄）。監測架構一段：100Hz ping、step detector（>1ms）、5s lease
sentinel（模擬 ceph mon lease watchdog）、CPU/記憶體 cgroup、udp/123 封包計數、journal error。
預測：六情境全 PASS——256s 改變的只是 poll 頻率（封包多 8 倍、仍每 4 分鐘 1 個 76-byte UDP）
與 PLL time constant；除非 jitter 情境驗出 low-max-poll-simulation 篇推論的失穩，否則無風險。
inject-80ms 是唯一預期可量到差異的情境：偵測延遲上界 256s vs 2048s。
指令：`sudo ./run/exp4-poll256-soak.sh --all --hours 24 --detach`。verdict 表實測欄＿＿。）

## 結果回填區
（<Callout> 說明：results/ 進 repo 後，上面各「實測＿＿」欄回填，預測 vs 實測對照是本篇核心價值。
回填時若實測與預測矛盾，**先懷疑實驗而不是 kernel**：檢查 preflight.json 的 clocksource、
qemu-guest-agent、PVE 備份窗口。）

## 邊界與不變式
（哪些情況這些結論不適用：chrony（makestep 行為不同）、bare-metal TSC vs kvm-clock、
NTP_MAX_ADJUST 可被發行版 patch 改、USER_HZ≠100 的 tick 基準不同。）
````

- [ ] **Step 1: 寫 MDX 全文**（預測數字與機制描述一字不差照上述；不得出現任何未在 spec source 表的行號）
- [ ] **Step 2: 本地驗證**（同 Task 15 Step 2 的 validate 方式）
- [ ] **Step 3: Commit**

```bash
git add next-site/content/systemd/features/timesyncd-drift-lab-experiments.mdx
git commit --no-gpg-sign -m "timesyncd-drift-lab: 頁 B 四組實驗設計與 source 推導預測"
```

---

### Task 17: `projects.ts` + `quiz.json` 整合

**Files:**
- Modify: `next-site/lib/projects.ts`（systemd 條目，現 :424-462）
- Modify: `next-site/content/systemd/quiz.json`（現有 11 題，新 id 從 12 起）

- [ ] **Step 1: `projects.ts` 三處修改（exact string replace）**

(a) `features`（:424）——在陣列尾端 `'timesyncd-prometheus-monitoring'` 後加 2 slug：

```ts
features: ['timesyncd-restart-impact', 'timesyncd-outage-and-maintenance', 'timesyncd-log-anatomy', 'timesyncd-poll-interval-adaptation', 'timesyncd-low-max-poll-simulation', 'timesyncd-poll-tuning-from-metrics', 'timesyncd-prometheus-monitoring', 'timesyncd-drift-lab-methodology', 'timesyncd-drift-lab-experiments'],
```

(b) featureGroups「時間同步 (timesyncd)」（:426）——slugs 尾端加同 2 slug：

```ts
      { label: '時間同步 (timesyncd)', icon: '🕒', slugs: ['timesyncd-restart-impact', 'timesyncd-outage-and-maintenance', 'timesyncd-log-anatomy', 'timesyncd-poll-interval-adaptation', 'timesyncd-low-max-poll-simulation', 'timesyncd-poll-tuning-from-metrics', 'timesyncd-drift-lab-methodology', 'timesyncd-drift-lab-experiments'] },
```

(c) learningPaths——intermediate 加 methodology（插在 `timesyncd-low-max-poll-simulation` 那筆之後）、advanced 加 experiments（插在 `timesyncd-poll-tuning-from-metrics` 那筆之後），閱讀順序 methodology → experiments：

```ts
        { slug: 'timesyncd-drift-lab-methodology', note: '怎麼設計可重現的 timesyncd 行為實驗：數學折疊 + adjtimex 注入 + 獨立 probe' },
```

```ts
        { slug: 'timesyncd-drift-lab-experiments', note: '25 cells 失聯恢復矩陣與 PollIntervalMaxSec=256 生產級 soak 的 source 推導預測' },
```

- [ ] **Step 2: `quiz.json` 加 8 題（id 12–19，answer 0-indexed，選項 4 個）**

新 section 名稱：`🧪 drift lab 方法論`（12–15）、`🧪 drift lab 實驗`（16–19）。完整題目：

```json
{
 "id": 12,
 "section": "🧪 drift lab 方法論",
 "question": "為什麼「NTP 失聯 24 小時」可以數學折疊成初始條件一次注入，而不用等 24 小時或做時間加速？",
 "options": [
  "因為沒有有效 NTP reply 時 timesyncd 完全不碰系統時鐘，失聯階段是確定性 free-run：累積 offset = 失聯時長 × 頻率誤差",
  "因為 kernel 會把失聯期間的漂移自動記在 time_offset 暫存器，恢復時一次補回",
  "因為 timesyncd 失聯時會以最後一次測得的 drift 繼續修正，所以漂移近似為零",
  "因為 PVE 的 kvm-clock 會在 guest 失聯時凍結 CLOCK_REALTIME"
 ],
 "answer": 0,
 "explanation": "timesyncd-outage-and-maintenance 篇已從 source 證明：沒有有效 reply 時 timesyncd 不做任何 clock 調整，時鐘以硬體 ppm 純 free-run。漂移因此是確定性的 T×F，可在恢復實驗開始前用 ADJ_SETOFFSET + 殘留 ppm 一次注入，比 10x/100x 時間加速更準（不是近似）也更快（失聯階段 0 秒）。"
},
{
 "id": 13,
 "section": "🧪 drift lab 方法論",
 "question": "模擬 ±100ppm 以上的晶振誤差時，為什麼選 ADJ_TICK 而不是 ADJ_FREQUENCY？",
 "options": [
  "tick 是 timesyncd 與 kernel PLL 都不會改寫的暫存器，注入後如真實晶振誤差般持續存在，NTP 迴路必須真的學會補償",
  "ADJ_TICK 的解析度比 ADJ_FREQUENCY 高，可以注入小數 ppm",
  "ADJ_FREQUENCY 需要 root 權限而 ADJ_TICK 不用",
  "tick 改變對 CLOCK_MONOTONIC_RAW 也生效，量測比較一致"
 ],
 "answer": 0,
 "explanation": "freq register（time_freq）是 PLL 的輸出，timesyncd 同步後會逐步把它改寫掉，注入值不會持續；tick 則只有人為 adjtimex 會動。tick 粒度 100ppm（10000µs ± 1µs/100ppm，範圍 9000–11000 見 timekeeping.c:2360），所以 ±10ppm 的細粒度 cell 才退而用 ADJ_FREQUENCY（動力學等價）。ADJ_TICK 不影響 MONOTONIC_RAW——這正是 RAW 能當獨立基準的原因。"
},
{
 "id": 14,
 "section": "🧪 drift lab 方法論",
 "question": "「Linux kernel 修時鐘最多只能 slew 500ppm」這句 lore 的真實出處是哪個機制？",
 "options": [
  "古典 adjtime()（ADJ_OFFSET_SINGLESHOT）的固定速率：MAX_TICKADJ = 500µs/s，恰好 500ppm——而 timesyncd 根本不走這條路",
  "PLL 相位滑動（ADJ_OFFSET + STA_PLL）的每秒修正上限",
  "NTP_MAX_ADJUST = 0.4s 換算成 ppm 的結果",
  "kvm-clock 對 guest 時鐘調整速率的硬體限制"
 ],
 "answer": 0,
 "explanation": "三種機制三個上限：PLL 相位滑動每秒修剩餘 offset 的 1/2^(SHIFT_PLL+tc)（ntp.c:130），無 ppm 形式上限（offset 進場被 MAXPHASE ±500ms clamp，有效上限 ~62,500ppm）；time_freq 頻率補償被 MAXFREQ 硬 clamp ±500ppm（timex.h:136）；古典 adjtime() 固定 500µs/s（ntp.c:43 MAX_TICKADJ）。lore 把第三條（timesyncd 不用）誤套到第一條上。"
},
{
 "id": 15,
 "section": "🧪 drift lab 方法論",
 "question": "單一 VM 上要端到端驗證整套實驗 rig（注入、probe、收斂判定），假 NTP server 為什麼要錨定 CLOCK_MONOTONIC_RAW？",
 "options": [
  "MONOTONIC_RAW 不受 adjtimex 影響：同一顆 kernel 上不管 REALTIME 被注入什麼誤差，server 回的都是未被打亂的時間線",
  "MONOTONIC_RAW 的解析度比 REALTIME 高一個數量級",
  "timesyncd 規定 NTP server 必須以 MONOTONIC_RAW 回應",
  "MONOTONIC_RAW 在 VM 裡不受 host 排程延遲影響"
 ],
 "answer": 0,
 "explanation": "clock_adjtime 的 offset/freq/tick 調整全部只作用在 CLOCK_REALTIME（與 MONOTONIC），MONOTONIC_RAW 永遠以硬體原始速率走。fake server 啟動時記 anchor_wall + anchor_raw，之後回 anchor_wall + (raw_now − anchor_raw)——等於一台「時鐘沒被動過的第二台機器」，但不需要第二顆 kernel。唯一前提：要在注入誤差前啟動。"
},
{
 "id": 16,
 "section": "🧪 drift lab 實驗",
 "question": "失聯恢復矩陣中，±1000ppm 的 cells 預測「永不穩定收斂」，依據是什麼？",
 "options": [
  "kernel 頻率補償被 MAXFREQ clamp 在 ±500ppm：晶振誤差 1000ppm 時淨漂移仍 ≥ 500ppm，offset 永遠追不平",
  "1000ppm 超過 ADJ_TICK 的注入範圍，實驗根本做不出來",
  "timesyncd 會在誤差超過 500ppm 時自動退出",
  "PLL 相位滑動的 τ≈7.5s 對 1000ppm 來說太慢"
 ],
 "answer": 0,
 "explanation": "time_freq 最多補 ±500ppm（timex.h:136）。殘留 ≥500ppm 的淨漂移讓 offset 持續累積：poll 短時在十幾 ms 徘徊、poll 拉長後跨 poll 漂移超過 0.4s 反覆觸發跳錶。timeout 1800s 記 non-convergent 本身就是 finding——生產上看到這個 signature 代表晶振故障或 VM 計時異常，不是 NTP 設定問題。tick 注入範圍 ±10%（9000–11000µs）≈ ±100,000ppm，1000ppm 完全做得出來。"
},
{
 "id": 17,
 "section": "🧪 drift lab 實驗",
 "question": "399ms 與 401ms 兩個 cell 的預測收斂時間都是「秒級到十幾秒」，那這組對照實驗到底在量什麼？",
 "options": [
  "連續性：399ms 走 PLL 滑動（step detector 看到一串遞減小事件、時間軸連續），401ms 走 ADJ_SETOFFSET 跳錶（單一 ≈400ms 不連續事件）",
  "量 NTP_MAX_ADJUST 的精確值是不是真的 0.4s",
  "量 kernel 在 400ms 附近的 slew 速率拐點",
  "量 timesyncd 重啟後的首次 poll 延遲"
 ],
 "answer": 0,
 "explanation": "timesyncd-manager.c:247 以 fabs(offset) < NTP_MAX_ADJUST(0.4s) 分流：slew 走 ADJ_OFFSET+STA_PLL（指數衰減 τ≈7.5s，ln(399/50)×7.5≈16s），step 走 ADJ_SETOFFSET（瞬間）。對 ceph mon lease、TLS、資料庫 timestamp 而言，風險不在收斂快慢而在時間軸是否不連續——這 1ms 之差正好跨在懸崖兩側。"
},
{
 "id": 18,
 "section": "🧪 drift lab 實驗",
 "question": "exp4 用什麼判準回答「PollIntervalMaxSec=256 在生產關鍵環境安不安全」？",
 "options": [
  "100Hz ping 0 丟包、REALTIME 對 RAW 無 >1ms 跳變、5 秒 deadline 哨兵 0 miss、journal 0 error——六情境（含 restart、30 分鐘失聯、80ms 注入、netem jitter）全程監測",
  "只比較 256s 與 2048s 兩種設定下的平均 offset 大小",
  "看 timesyncd 的 CPU 使用率有沒有超過 1%",
  "讓 ceph cluster 實際跑在上面看 HEALTH_WARN 出不出現"
 ],
 "answer": 0,
 "explanation": "判準從環境需求倒推：「連 2 個 ping 封包都不能掉、5 秒 downtime 不可接受」→ 連續性監測（step detector）、可用性監測（100Hz ping）、lease 語意監測（5s 哨兵，模擬 ceph mon lease watchdog）三者全程開著，再加資源與封包計數。預測唯一可量到的差異是 inject-80ms 情境的偵測延遲上界（256s vs 2048s）——這是低 max poll 的實際效益所在。"
},
{
 "id": 19,
 "section": "🧪 drift lab 實驗",
 "question": "實驗為什麼不直接讀 timesyncd 自己回報的 offset（timedatectl timesync-status），而要自建 1Hz SNTP probe？",
 "options": [
  "量測必須獨立於受測物：timesyncd 的自報值只在它自己 poll 的時刻更新、且反映它自己的演算法視角，無法當收斂判定的 ground truth",
  "timedatectl 需要 DBus，實驗 VM 上不可用",
  "timesyncd 的 offset 單位是 NTP 時間戳，換算誤差太大",
  "自報 offset 只有 root 看得到"
 ],
 "answer": 0,
 "explanation": "受測物自報數據有兩個問題：更新頻率綁在 poll interval（32–2048s，遠粗於收斂判定需要的 1Hz）、且它是演算法內部狀態而非外部真值。probe 直接對 server 做 SNTP query（offset = ((T2−T1)+(T3−T4))/2 = server − client），LAN RTT sub-ms 對 50ms 判準綽綽有餘，並把 raw_s（MONOTONIC_RAW）一起落檔讓注入時刻可對齊。"
}
```

- [ ] **Step 3: 驗證 + Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
python3 -c "import json; q=json.load(open('next-site/content/systemd/quiz.json')); print(len(q), [x['id'] for x in q[-8:]])"
make validate
```
Expected: `19 [12, 13, 14, 15, 16, 17, 18, 19]`；`make validate` exit 0（slug 已註冊、build 過）

```bash
git add next-site/lib/projects.ts next-site/content/systemd/quiz.json
git commit --no-gpg-sign -m "timesyncd-drift-lab: projects.ts 整合 + quiz 8 題"
```

---

### Task 18: 最終驗證（L1/L2）+ merge + push

**Files:** 無新檔；驗證 + git 操作。

- [ ] **Step 1: L1 靜態驗證（全部 shell + python）**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
for f in experiments/timesyncd/lib/common.sh experiments/timesyncd/setup/*.sh experiments/timesyncd/run/*.sh; do
  bash -n "$f" || exit 1
done
python3 -m py_compile experiments/timesyncd/lib/*.py experiments/timesyncd/tests/*.py
echo L1-OK
```
Expected: `L1-OK`（Mac 沒裝 shellcheck，`bash -n` 為準；若已裝 shellcheck 一併跑）

- [ ] **Step 2: L2 單元測試全綠**

```bash
python3 -m unittest discover -s experiments/timesyncd/tests -v
```
Expected: 24 tests PASS（含 fake server loopback 整合測試）

- [ ] **Step 3: `make validate`**

```bash
make validate
```
Expected: exit 0（MDX frontmatter、quiz 格式、projects.ts slug 對應、Next.js build 全過）

- [ ] **Step 4: merge 回 master + push（repo 慣例）**

```bash
git checkout master
git merge --no-ff --no-gpg-sign timesyncd-drift-lab -m "Merge timesyncd-drift-lab: 漂移實驗包 + 兩頁方法論/實驗文章"
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push
```
Expected: push 成功，使用者可在 GitHub review

- [ ] **Step 5: 完成回報**

回報內容：變更檔案清單、L1/L2/validate 結果、L3/L4 留待事項（等使用者提供 PVE VM 後另開 session，
入口 = `experiments/timesyncd/README.md` 第 2 節）。

---

## Plan 完

