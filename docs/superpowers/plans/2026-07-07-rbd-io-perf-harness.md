# rbd-io-perf Harness Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建出 `experiments/rbd-io-perf/` 的實驗 harness（本機離線可測）+ 完成 `rbd-io-tuning-catalog` 批次 1 修正；Phase 2/3 真機執行由 spec §5/§7 與 README runbook 治理，不在本計畫。

**Architecture:** bash 3.2 orchestrator（macOS bastion）經 ssh 驅動 PVE node（`qm`/`rbd`）與 guest（fio）；`lib/` 純函式 + `run/` 薄入口；統計與 verdict 用一支 `lib/verdict.py`（bastion 端 python3）。測試全靠 PATH 覆蓋的 fake `ssh` + fixture，不碰真機。

**Tech Stack:** bash 3.2、python3（標準庫）、shellcheck、既有 `make validate`。

**Spec:** `docs/superpowers/specs/2026-07-07-rbd-io-perf-pve-experiments-design.md`（環境事實見 `experiments/rbd-io-perf/preflight-snapshot-2026-07-07.md`）

## Global Constraints

- bash 3.2 相容：**禁用** `mapfile`、`declare -A`、nameref；`set -u` 下空陣列用 `"${arr[@]+"${arr[@]}"}"` 保護。
- `shellcheck lib/*.sh run/*.sh tests/*.sh` 必須 0（含 info）；誤報才可用附註解的 `# shellcheck disable=SCxxxx`。
- stdout 只放機器要抓的那行；log/progress 一律 stderr。
- ssh 選項逐個寫死，不用「一整串變數」展開。
- 會變更遠端狀態的 run/ 腳本必須要求 `--yes-really-inject`。
- 每個 task 結尾：`bash experiments/rbd-io-perf/tests/run-tests.sh` 全綠才 commit；commit 用 `git commit --no-gpg-sign`。
- 常數（沿 spec/snapshot）：PVE_HOST=192.168.16.7、PVE_USER=ioperf、POOL=ioperf、VMID=1031、BRIDGE=vmbr1、BOOT_SIZE=10G、DATA_SIZE=16G、guest 帳號 ubuntu。
- MDX 修改須通過 `make validate`（zero-fabrication：只引用已驗證錨點）。

## File Structure

```
experiments/rbd-io-perf/
├── HYPOTHESES.md / preflight-snapshot-2026-07-07.md   # 已存在
├── README.md                       # Task 12
├── .gitignore                      # results/
├── lib/
│   ├── common.sh                   # ssh 向量、log/die、inject gate、bundle
│   ├── verdict.py                  # fio JSON 聚合 + 三態 verdict
│   ├── fio.sh                      # pattern 表、fio/prefill 指令 render
│   ├── collect.sh                  # ceph -s/dmesg/iostat/pid 收集、taint/guardrail
│   ├── rbdimg.sh                   # 測試 image 生命週期（create/map/unmap/meta/rm）
│   ├── pve.sh                      # 測試 VM 生命週期（create/set/restart/assert/ip/destroy）
│   └── scenarios.sh                # run_matrix、A/B 交錯、prediction/verdict 落檔
├── run/
│   ├── preflight.sh                # read-only
│   ├── krbd-check.sh               # E-01
│   ├── exp0-host-ceiling.sh        # E-02
│   ├── baseline.sh                 # E-03（建 VM + 噪音帶）
│   ├── scenario-exp-axis.sh        # E-04
│   ├── scenario-exp1-cache.sh ... scenario-exp15-rbdcache.sh（薄 wrapper）
│   ├── cleanup.sh
│   └── all.sh
├── tests/
│   ├── run-tests.sh
│   ├── fakes/ssh                   # PATH 覆蓋
│   ├── fixtures/                   # fio JSON、qm config、ceph -s 樣本
│   └── test-*.sh
└── results/                        # git-ignored
```

---

### Task 1: 骨架 + lib/common.sh + 測試機制

**Files:**
- Create: `experiments/rbd-io-perf/.gitignore`、`lib/common.sh`、`tests/run-tests.sh`、`tests/fakes/ssh`、`tests/test-common.sh`

**Interfaces (Produces):**
- `pve_ssh <cmd string>`：以固定 key/user/host 執行遠端指令（stdout 透傳）。環境變數 `PVE_HOST`/`PVE_USER`/`SSH_KEY` 可覆寫。
- `guest_ssh <ip> <cmd string>`：對 guest（ubuntu@ip）。
- `log <msg>`（stderr）、`die <msg>`（stderr + exit 1）。
- `require_inject_flag "$@"`：無 `--yes-really-inject` 即 die。
- `new_bundle <scenario>`：建 `results/<scenario>/<YYYYmmdd-HHMMSS>/` 並 echo 路徑（唯一 stdout）。
- 測試機制：`tests/fakes/ssh` 把完整參數列 append 到 `$FAKE_SSH_LOG`，並依 `$FAKE_SSH_DIR` 中「檔名 = 參數列 grep pattern」的 fixture 回覆 stdout；無匹配輸出空。

- [ ] **Step 1: 寫會失敗的測試**

`experiments/rbd-io-perf/tests/run-tests.sh`：

```bash
#!/usr/bin/env bash
# Test gate: run every tests/test-*.sh; summary on stdout.
set -u
cd "$(dirname "$0")" || exit 1
pass=0; fail=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  if bash "$t" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "PASS $t" >&2
  else
    fail=$((fail+1)); echo "FAIL $t" >&2; bash "$t" >&2 2>&1 || true
  fi
done
echo "tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

`experiments/rbd-io-perf/tests/fakes/ssh`：

```bash
#!/usr/bin/env bash
# Fake ssh: log args; reply from fixture whose filename (under FAKE_SSH_DIR)
# is a grep -F pattern matched against the full arg string.
set -u
args="$*"
printf '%s\n' "$args" >> "${FAKE_SSH_LOG:?}"
if [ -n "${FAKE_SSH_DIR:-}" ] && [ -d "$FAKE_SSH_DIR" ]; then
  for f in "$FAKE_SSH_DIR"/*; do
    [ -e "$f" ] || continue
    pat="$(basename "$f")"
    if printf '%s' "$args" | grep -qF -- "$pat"; then cat "$f"; exit 0; fi
  done
fi
exit 0
```

`experiments/rbd-io-perf/tests/test-common.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
# shellcheck disable=SC1091  # test-time relative source
. "$here/../lib/common.sh"

# 1. pve_ssh 走 fake、帶正確 user@host 與指令
printf 'ok\n' > "$FAKE_SSH_DIR/qm list"
out="$(pve_ssh 'sudo -n qm list')"
[ "$out" = "ok" ] || { echo "pve_ssh reply wrong: $out"; exit 1; }
grep -q 'ioperf@192.168.16.7' "$FAKE_SSH_LOG" || { echo "no user@host"; exit 1; }
grep -q 'sudo -n qm list' "$FAKE_SSH_LOG" || { echo "no cmd"; exit 1; }

# 2. require_inject_flag 擋住無旗標呼叫
if ( require_inject_flag --foo ) 2>/dev/null; then echo "gate not enforced"; exit 1; fi
( require_inject_flag --yes-really-inject ) || { echo "gate false positive"; exit 1; }

# 3. new_bundle 建目錄且 stdout 只有路徑
b="$(new_bundle smoke)"
[ -d "$b" ] || { echo "bundle dir missing"; exit 1; }
case "$b" in "$RESULTS_DIR/smoke/"*) : ;; *) echo "bad bundle path: $b"; exit 1 ;; esac
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh`
Expected: `FAIL test-common.sh`（lib/common.sh 不存在），summary `0 passed, 1 failed`，exit 非 0。

- [ ] **Step 3: 實作 lib/common.sh 與 .gitignore**

`experiments/rbd-io-perf/.gitignore`：

```
results/
```

`experiments/rbd-io-perf/lib/common.sh`：

```bash
#!/usr/bin/env bash
# Common helpers for the rbd-io-perf harness. bash 3.2 compatible.
# stdout is reserved for machine-readable output; logs go to stderr.

RBDPERF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$RBDPERF_ROOT/../.." && pwd)"
PVE_HOST="${PVE_HOST:-192.168.16.7}"
PVE_USER="${PVE_USER:-ioperf}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/.ssh/id_ed25519}"
RESULTS_DIR="${RESULTS_DIR:-$RBDPERF_ROOT/results}"
POOL="${POOL:-ioperf}"
VMID="${VMID:-1031}"
GUEST_USER="${GUEST_USER:-ubuntu}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

pve_ssh() {
  ssh -i "$SSH_KEY" \
      -o IdentitiesOnly=yes \
      -o IdentityAgent=none \
      -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=accept-new \
      "$PVE_USER@$PVE_HOST" "$@"
}

guest_ssh() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" \
      -o IdentitiesOnly=yes \
      -o IdentityAgent=none \
      -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "$GUEST_USER@$ip" "$@"
}

require_inject_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--yes-really-inject" ] && return 0
  done
  die "此腳本會變更遠端狀態，需要 --yes-really-inject"
}

new_bundle() {
  local d
  d="$RESULTS_DIR/$1/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$d" || die "cannot create bundle $d"
  printf '%s\n' "$d"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh`
Expected: `PASS test-common.sh`、`tests: 1 passed, 0 failed`、exit 0。
Run: `shellcheck experiments/rbd-io-perf/lib/common.sh experiments/rbd-io-perf/tests/run-tests.sh experiments/rbd-io-perf/tests/test-common.sh experiments/rbd-io-perf/tests/fakes/ssh`
Expected: 無輸出（exit 0）。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/.gitignore experiments/rbd-io-perf/lib/common.sh experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: harness skeleton with common.sh and fake-ssh test rig"
```

---

### Task 2: lib/verdict.py（fio 聚合 + 三態 verdict）

**Files:**
- Create: `experiments/rbd-io-perf/lib/verdict.py`、`tests/fixtures/fio-sample-a1.json`、`fio-sample-a2.json`、`fio-sample-b1.json`、`fio-sample-b2.json`、`tests/test-verdict.sh`

**Interfaces (Produces):**
- `python3 lib/verdict.py summarize FILE...` → 單行 JSON：`{"iops": <mean>, "iops_cov": <0-1>, "p99_us": <mean>, "p99_cov": <0-1>, "bw_mbs": <mean>, "n": <int>}`。fio JSON 的 read+write 兩向合併（IOPS/BW 相加；p99 取有 IO 那一向；混合時取較大者）。
- `python3 lib/verdict.py compare --metric {iops|p99} --expect {better|worse|none} --noise-cov F --baseline A.json[,B...] --variant C.json[,D...]` → 單行 JSON：`{"verdict": "confirmed|violated|indistinguishable", "delta_pct": <float>, "band_pct": <float>}`。
- 規則：`band_pct = max(2*noise_cov, 0.05)*100`；`delta_pct` 對 iops 取 (variant−base)/base、對 p99 同式但「better」意謂 p99 下降。|delta| ≤ band → `none` 預期時 `confirmed`、否則 `indistinguishable`；超帶且方向符合預期 → `confirmed`；超帶且方向相反 → `violated`（`none` 預期超帶亦 `violated`）。

- [ ] **Step 1: 建 fixtures + 會失敗的測試**

fixture 為最小可解析 fio JSON（4 檔同構、數值不同）。`tests/fixtures/fio-sample-a1.json`：

```json
{"jobs": [{"jobname": "rr-4k-qd1",
  "read":  {"iops": 1000.0, "bw_bytes": 4096000,
            "clat_ns": {"percentile": {"99.000000": 2000000}}},
  "write": {"iops": 0.0, "bw_bytes": 0,
            "clat_ns": {"percentile": {"99.000000": 0}}}}]}
```

`fio-sample-a2.json` 同上但 `iops: 1040.0`、p99 `2100000`；`fio-sample-b1.json`：`iops: 1500.0`、p99 `1500000`；`fio-sample-b2.json`：`iops: 1560.0`、p99 `1440000`。

`tests/test-verdict.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
V="$here/../lib/verdict.py"
FX="$here/fixtures"

s="$(python3 "$V" summarize "$FX/fio-sample-a1.json" "$FX/fio-sample-a2.json")"
python3 - "$s" <<'EOF' || exit 1
import json,sys
d=json.loads(sys.argv[1])
assert d["n"]==2, d
assert abs(d["iops"]-1020.0)<0.01, d
assert abs(d["p99_us"]-2050.0)<0.01, d
assert 0 < d["iops_cov"] < 0.05, d
EOF

# baseline→variant IOPS +~50%，noise 2% → band 5% → confirmed
c="$(python3 "$V" compare --metric iops --expect better --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-b1.json,$FX/fio-sample-b2.json")"
echo "$c" | grep -q '"verdict": "confirmed"' || { echo "want confirmed: $c"; exit 1; }

# 反向預期 → violated
c="$(python3 "$V" compare --metric iops --expect worse --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-b1.json,$FX/fio-sample-b2.json")"
echo "$c" | grep -q '"verdict": "violated"' || { echo "want violated: $c"; exit 1; }

# 同組對打 → indistinguishable（expect better 落帶內）
c="$(python3 "$V" compare --metric iops --expect better --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json")"
echo "$c" | grep -q '"verdict": "indistinguishable"' || { echo "want indistinguishable: $c"; exit 1; }

# p99 下降 = better → confirmed
c="$(python3 "$V" compare --metric p99 --expect better --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-b1.json,$FX/fio-sample-b2.json")"
echo "$c" | grep -q '"verdict": "confirmed"' || { echo "want p99 confirmed: $c"; exit 1; }
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh`
Expected: `FAIL test-verdict.sh`（verdict.py 不存在）。

- [ ] **Step 3: 實作 lib/verdict.py**

```python
#!/usr/bin/env python3
"""fio JSON aggregation and 3-state verdict for rbd-io-perf.

summarize FILE...          -> one-line JSON with mean/CoV across runs
compare --metric M --expect E --noise-cov F --baseline A,B --variant C,D
                           -> one-line JSON verdict
"""
import argparse, json, statistics, sys


def _load(path):
    with open(path) as f:
        return json.load(f)["jobs"][0]


def _point(job):
    rd, wr = job.get("read", {}), job.get("write", {})
    iops = float(rd.get("iops", 0)) + float(wr.get("iops", 0))
    bw = float(rd.get("bw_bytes", 0)) + float(wr.get("bw_bytes", 0))
    p99s = []
    for side in (rd, wr):
        v = side.get("clat_ns", {}).get("percentile", {}).get("99.000000", 0)
        if v:
            p99s.append(float(v))
    p99_us = max(p99s) / 1000.0 if p99s else 0.0
    return iops, p99_us, bw / 1e6


def _agg(paths):
    pts = [_point(_load(p)) for p in paths]
    iops = [p[0] for p in pts]
    p99 = [p[1] for p in pts]
    bw = [p[2] for p in pts]

    def cov(xs):
        m = statistics.mean(xs)
        if m == 0 or len(xs) < 2:
            return 0.0
        return statistics.stdev(xs) / m

    return {
        "iops": statistics.mean(iops), "iops_cov": cov(iops),
        "p99_us": statistics.mean(p99), "p99_cov": cov(p99),
        "bw_mbs": statistics.mean(bw), "n": len(pts),
    }


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summarize")
    s.add_argument("files", nargs="+")
    c = sub.add_parser("compare")
    c.add_argument("--metric", choices=["iops", "p99"], required=True)
    c.add_argument("--expect", choices=["better", "worse", "none"], required=True)
    c.add_argument("--noise-cov", type=float, required=True)
    c.add_argument("--baseline", required=True)
    c.add_argument("--variant", required=True)
    args = ap.parse_args()

    if args.cmd == "summarize":
        print(json.dumps(_agg(args.files)))
        return

    base = _agg(args.baseline.split(","))
    var = _agg(args.variant.split(","))
    key = "iops" if args.metric == "iops" else "p99_us"
    if base[key] == 0:
        print(json.dumps({"verdict": "violated", "delta_pct": 0.0,
                          "band_pct": 0.0, "error": "baseline metric is 0"}))
        return
    delta = (var[key] - base[key]) / base[key]
    band = max(2 * args.noise_cov, 0.05)
    # for p99, "better" means the value went DOWN
    improved = delta > 0 if args.metric == "iops" else delta < 0
    if abs(delta) <= band:
        verdict = "confirmed" if args.expect == "none" else "indistinguishable"
    elif args.expect == "none":
        verdict = "violated"
    elif (args.expect == "better") == improved:
        verdict = "confirmed"
    else:
        verdict = "violated"
    print(json.dumps({"verdict": verdict, "delta_pct": round(delta * 100, 2),
                      "band_pct": round(band * 100, 2)}))


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh`
Expected: `tests: 2 passed, 0 failed`。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/verdict.py experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: verdict.py fio aggregation and 3-state verdict"
```

---

### Task 3: lib/fio.sh（pattern 表與指令 render）

**Files:**
- Create: `lib/fio.sh`、`tests/test-fio.sh`

**Interfaces (Produces):**
- `FIO_PATTERNS`：空白分隔的 `name:rw:bs:iodepth` 清單，8 點：`rr-4k-qd1:randread:4k:1 rr-4k-qd8:randread:4k:8 rr-4k-qd32:randread:4k:32 rw-4k-qd1:randwrite:4k:1 rw-4k-qd8:randwrite:4k:8 rw-4k-qd32:randwrite:4k:32 sr-1m:read:1M:16 sw-1m:write:1M:16`
- `fio_cmd <pattern-entry> <filename>` → echo 單行 fio 指令（`--output-format=json`、`--ramp_time=15 --runtime=60`、`--randseed=8675309`）。
- `fio_cmd_numjobs <pattern-entry> <filename> <numjobs>` → 同上但指定 numjobs（E-08 用）。
- `prefill_cmd <filename>` → echo 全盤寫滿指令。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-fio.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"

n=0
for p in $FIO_PATTERNS; do n=$((n+1)); done
[ "$n" -eq 8 ] || { echo "want 8 patterns, got $n"; exit 1; }

c="$(fio_cmd "rr-4k-qd32:randread:4k:32" /dev/vdb)"
echo "$c" | grep -q -- '--rw=randread' || { echo "rw missing: $c"; exit 1; }
echo "$c" | grep -q -- '--bs=4k' || exit 1
echo "$c" | grep -q -- '--iodepth=32' || exit 1
echo "$c" | grep -q -- '--filename=/dev/vdb' || exit 1
echo "$c" | grep -q -- '--ramp_time=15' || exit 1
echo "$c" | grep -q -- '--output-format=json' || exit 1
echo "$c" | grep -q -- '--randseed=8675309' || exit 1
echo "$c" | grep -q -- '--numjobs=1' || exit 1

c="$(fio_cmd_numjobs "rr-4k-qd8:randread:4k:8" /dev/vdb 4)"
echo "$c" | grep -q -- '--numjobs=4' || { echo "numjobs missing: $c"; exit 1; }

c="$(prefill_cmd /dev/vdb)"
echo "$c" | grep -q -- '--rw=write' || exit 1
echo "$c" | grep -q -- '--filename=/dev/vdb' || exit 1
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-fio.sh`。

- [ ] **Step 3: 實作 lib/fio.sh**

```bash
#!/usr/bin/env bash
# fio pattern table and command rendering. Pure string functions (no ssh).

FIO_PATTERNS="rr-4k-qd1:randread:4k:1 rr-4k-qd8:randread:4k:8 rr-4k-qd32:randread:4k:32 rw-4k-qd1:randwrite:4k:1 rw-4k-qd8:randwrite:4k:8 rw-4k-qd32:randwrite:4k:32 sr-1m:read:1M:16 sw-1m:write:1M:16"

fio_cmd_numjobs() {
  local entry="$1" filename="$2" numjobs="$3"
  local name rw bs qd
  name="${entry%%:*}"; entry="${entry#*:}"
  rw="${entry%%:*}"; entry="${entry#*:}"
  bs="${entry%%:*}"; qd="${entry##*:}"
  printf 'fio --name=%s --filename=%s --direct=1 --rw=%s --bs=%s --iodepth=%s --numjobs=%s --ioengine=libaio --ramp_time=15 --runtime=60 --time_based --randseed=8675309 --group_reporting --output-format=json\n' \
    "$name" "$filename" "$rw" "$bs" "$qd" "$numjobs"
}

fio_cmd() { fio_cmd_numjobs "$1" "$2" 1; }

prefill_cmd() {
  printf 'fio --name=prefill --filename=%s --direct=1 --rw=write --bs=1M --iodepth=8 --ioengine=libaio --group_reporting --output-format=json\n' "$1"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 3 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/lib/fio.sh experiments/rbd-io-perf/tests/test-fio.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/fio.sh experiments/rbd-io-perf/tests/test-fio.sh
git commit --no-gpg-sign -m "rbd-io-perf: fio pattern table and command rendering"
```

---

### Task 4: lib/collect.sh（收集、taint、guardrail）

**Files:**
- Create: `lib/collect.sh`、`tests/test-collect.sh`、`tests/fixtures/ceph-s-clean.txt`、`ceph-s-recovery.txt`、`ceph-health-err.txt`

**Interfaces:**
- Consumes: `pve_ssh`、`log`、`die`（common.sh）。
- Produces:
  - `collect_ceph_status <outfile>`：`ceph -s` 存檔。
  - `taint_check <ceph-s-file>`：內容含 `recovery`/`backfill`/`degraded` → return 1（tainted），否則 0。
  - `guard_check <ceph-s-file> <baseline-health-file>`：出現 `HEALTH_ERR`、或出現 baseline 沒有的 `slow ops` 行 → die（abort）。
  - `collect_dmesg_marker`：echo 目前遠端 `dmesg | wc -l`（供 delta）。
  - `collect_dmesg_delta <marker> <outfile>`：存 marker 之後的新行；grep `bad crc|socket closed` 命中則 log 警示。
  - `qemu_pid <vmid>`：echo 遠端 `/var/run/qemu-server/<vmid>.pid` 內容。
  - `sample_iostat_host <dev> <secs> <outfile>` / `sample_iostat_guest <ip> <dev> <secs> <outfile>`：前景收集（呼叫端自行以 `&` 背景化，PID 由呼叫端管理）。

- [ ] **Step 1: fixtures + 會失敗的測試**

`tests/fixtures/ceph-s-clean.txt`：貼 pre-flight 實際輸出的精簡版（health HEALTH_WARN + `1 OSD(s) experiencing slow operations in BlueStore` + `pgs: 289 active+clean`）。
`tests/fixtures/ceph-s-recovery.txt`：同上再加一行 `recovery: 12 MiB/s, 3 objects/s`。
`tests/fixtures/ceph-health-err.txt`：`health: HEALTH_ERR` 版本。

`tests/test-collect.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"

# taint_check
taint_check "$here/fixtures/ceph-s-clean.txt" || { echo "clean judged tainted"; exit 1; }
if taint_check "$here/fixtures/ceph-s-recovery.txt"; then echo "recovery not tainted"; exit 1; fi

# guard_check：ERR 要 die（subshell 驗證 exit）
if ( guard_check "$here/fixtures/ceph-health-err.txt" "$here/fixtures/ceph-s-clean.txt" ) 2>/dev/null; then
  echo "guard passed HEALTH_ERR"; exit 1
fi
( guard_check "$here/fixtures/ceph-s-clean.txt" "$here/fixtures/ceph-s-clean.txt" ) || { echo "guard false positive"; exit 1; }

# qemu_pid 走 fake
printf '4321\n' > "$FAKE_SSH_DIR/qemu-server/1031.pid"
# fixture 檔名不能含 /：改用 pattern 片段
rm -rf "$FAKE_SSH_DIR"; mkdir -p "$FAKE_SSH_DIR"
printf '4321\n' > "$FAKE_SSH_DIR/1031.pid"
p="$(qemu_pid 1031)"
[ "$p" = "4321" ] || { echo "qemu_pid=$p"; exit 1; }
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-collect.sh`。

- [ ] **Step 3: 實作 lib/collect.sh**

```bash
#!/usr/bin/env bash
# Cluster/host observation, taint detection and courtesy guardrails.
# Requires lib/common.sh to be sourced first.

collect_ceph_status() {
  pve_ssh 'sudo -n ceph -s' > "$1"
}

taint_check() {
  if grep -qiE 'recovery|backfill|degraded' "$1"; then
    log "taint: 背景 recovery/backfill/degraded 活動"
    return 1
  fi
  return 0
}

guard_check() {
  local cur="$1" base="$2"
  if grep -q 'HEALTH_ERR' "$cur"; then
    die "guardrail: HEALTH_ERR 出現，立即中止（見 $cur）"
  fi
  if grep -qi 'slow ops' "$cur" && ! grep -qi 'slow ops' "$base"; then
    die "guardrail: 新增 slow ops（baseline 無），立即中止"
  fi
  return 0
}

collect_dmesg_marker() {
  pve_ssh 'sudo -n dmesg | wc -l' | tr -d '[:space:]'
}

collect_dmesg_delta() {
  local marker="$1" out="$2"
  pve_ssh "sudo -n dmesg | tail -n +$((marker + 1))" > "$out" || true
  if grep -qiE 'bad crc|socket closed' "$out"; then
    log "警示: dmesg 出現 bad crc / socket closed（rxbounce 徵兆，見 $out）"
  fi
}

qemu_pid() {
  pve_ssh "sudo -n cat /var/run/qemu-server/$1.pid" | tr -d '[:space:]'
}

sample_iostat_host() {
  local dev="$1" secs="$2" out="$3"
  pve_ssh "iostat -x 1 $secs $dev" > "$out" || true
}

sample_iostat_guest() {
  local ip="$1" dev="$2" secs="$3" out="$4"
  guest_ssh "$ip" "iostat -x 1 $secs $dev" > "$out" || true
}
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 4 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/lib/collect.sh experiments/rbd-io-perf/tests/test-collect.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/collect.sh experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: collectors, taint check and courtesy guardrails"
```

---

### Task 5: lib/rbdimg.sh（測試 image 生命週期）

**Files:**
- Create: `lib/rbdimg.sh`、`tests/test-rbdimg.sh`

**Interfaces:**
- Consumes: `pve_ssh`、`log`、`die`、`POOL`。
- Produces（全部以 `ioperf-` 前綴強制隔離，操作非此前綴的 image 一律 die）：
  - `img_create <name> <size> [extra rbd create args...]`（如 `--object-size 16M`）。
  - `img_rm <name>`、`img_exists <name>`（return 0/1）、`img_info <name>` → stdout 原文。
  - `img_map <name> [map options]` → echo `/dev/rbdN`（解析 `rbd map` stdout）；`img_unmap <dev>`。
  - `img_meta_set <name> <key> <val>` / `img_meta_get <name> <key>`。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-rbdimg.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"

# 前綴防呆：非 ioperf- 名稱一律拒絕
if ( img_create vm-103-disk-0 16G ) 2>/dev/null; then echo "prefix guard missing"; exit 1; fi
if ( img_rm vm-103-disk-0 ) 2>/dev/null; then echo "rm prefix guard missing"; exit 1; fi

img_create ioperf-data 16G --object-size 16M
grep -q 'rbd create ioperf/ioperf-data --size 16G --object-size 16M' "$FAKE_SSH_LOG" || { echo "create cmd wrong"; cat "$FAKE_SSH_LOG"; exit 1; }

printf '/dev/rbd7\n' > "$FAKE_SSH_DIR/rbd map"
d="$(img_map ioperf-data queue_depth=128)"
[ "$d" = "/dev/rbd7" ] || { echo "map dev=$d"; exit 1; }
grep -q -- '-o queue_depth=128' "$FAKE_SSH_LOG" || { echo "map options missing"; exit 1; }

img_unmap /dev/rbd7
grep -q 'rbd unmap /dev/rbd7' "$FAKE_SSH_LOG" || exit 1

img_meta_set ioperf-data conf_rbd_cache false
grep -q 'rbd image-meta set ioperf/ioperf-data conf_rbd_cache false' "$FAKE_SSH_LOG" || exit 1
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-rbdimg.sh`。

- [ ] **Step 3: 實作 lib/rbdimg.sh**

```bash
#!/usr/bin/env bash
# Own-image lifecycle. Every image name MUST start with "ioperf-";
# anything else is refused so the harness can never touch foreign images.
# Requires lib/common.sh.

_img_guard() {
  case "$1" in
    ioperf-*) : ;;
    *) die "拒絕操作非 ioperf- 前綴的 image: $1" ;;
  esac
}

img_create() {
  local name="$1" size="$2"; shift 2
  _img_guard "$name"
  pve_ssh "sudo -n rbd create $POOL/$name --size $size $*"
}

img_rm() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd rm $POOL/$1"
}

img_exists() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd info $POOL/$1 >/dev/null 2>&1 && echo yes || echo no" | grep -q yes
}

img_info() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd info $POOL/$1"
}

img_map() {
  local name="$1" opts="${2:-}"
  _img_guard "$name"
  local cmd="sudo -n rbd map $POOL/$name"
  [ -n "$opts" ] && cmd="$cmd -o $opts"
  pve_ssh "$cmd" | tr -d '[:space:]'
}

img_unmap() {
  case "$1" in
    /dev/rbd*) : ;;
    *) die "img_unmap 需要 /dev/rbdN 路徑: $1" ;;
  esac
  pve_ssh "sudo -n rbd unmap $1"
}

img_meta_set() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd image-meta set $POOL/$1 $2 $3"
}

img_meta_get() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd image-meta get $POOL/$1 $2"
}
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 5 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/lib/rbdimg.sh experiments/rbd-io-perf/tests/test-rbdimg.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/rbdimg.sh experiments/rbd-io-perf/tests/test-rbdimg.sh
git commit --no-gpg-sign -m "rbd-io-perf: own-image lifecycle with ioperf- prefix guard"
```

---

### Task 6: lib/pve.sh（測試 VM 生命週期）

**Files:**
- Create: `lib/pve.sh`、`tests/test-pve.sh`、`tests/fixtures/qm-config-baseline.txt`、`tests/fixtures/qm-agent-ip.json`

**Interfaces:**
- Consumes: `pve_ssh`、`log`、`die`、`VMID`、`qemu_pid`（collect.sh）。
- Produces（VMID 防呆：只允許 1031–1039，否則 die）：
  - `vm_create <cloudimg-path> <sshkey-pub-path-remote>`：`qm create` + import boot 盤到 `ioperf` storage + cloud-init（`--ide2 ioperf:cloudinit --ciuser ubuntu --sshkeys ... --ipconfig0 ip=dhcp --net0 virtio,bridge=vmbr1 --agent 1 --cores 4 --memory 4096 --scsihw virtio-scsi-single`）。
  - `vm_attach_data <spec>`：`qm set --virtio1 <spec>`（spec 例 `ioperf:16` 或 `/dev/rbd7`）。
  - `vm_set <qm set args...>`：透傳（變體切換用）。
  - `vm_cold_restart`：`qm stop` → 等 stopped → `qm start` → 等 `qm agent <vmid> ping` 成功（重試 30 次、每 5 秒）。
  - `vm_config` → stdout `qm config $VMID`；`vm_assert_config <grep-pattern>`：不匹配即 die。
  - `vm_cmdline` → stdout QEMU `/proc/<pid>/cmdline`（tr '\0' ' '）；`vm_assert_cmdline <grep-pattern>`。
  - `vm_guest_ip` → 從 `qm agent network-get-interfaces` JSON 解析 192.168.18.x（python3 stdin 解析）。
  - `vm_destroy`：`qm stop`（容忍已停）+ `qm destroy $VMID --purge`。

- [ ] **Step 1: fixtures + 會失敗的測試**

`tests/fixtures/qm-config-baseline.txt`（qm config 樣式）：

```
agent: 1
cores: 4
ide2: ioperf:vm-1031-cloudinit,media=cdrom
memory: 4096
net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr1
scsi0: ioperf:vm-1031-disk-0,size=10G
scsihw: virtio-scsi-single
virtio1: ioperf:vm-1031-disk-1,size=16G
```

`tests/fixtures/qm-agent-ip.json`（`network-get-interfaces` 精簡樣式）：

```json
{"result":[{"name":"lo","ip-addresses":[{"ip-address":"127.0.0.1","ip-address-type":"ipv4"}]},{"name":"eth0","ip-addresses":[{"ip-address":"192.168.18.77","ip-address-type":"ipv4"},{"ip-address":"fe80::1","ip-address-type":"ipv6"}]}]}
```

`tests/test-pve.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"

# VMID 防呆
if ( VMID=103 vm_destroy ) 2>/dev/null; then echo "vmid guard missing"; exit 1; fi

cp "$here/fixtures/qm-config-baseline.txt" "$FAKE_SSH_DIR/qm config 1031"
vm_assert_config 'scsihw: virtio-scsi-single' || { echo "assert_config false negative"; exit 1; }
if ( vm_assert_config 'aio=native' ) 2>/dev/null; then echo "assert_config false positive"; exit 1; fi

cp "$here/fixtures/qm-agent-ip.json" "$FAKE_SSH_DIR/network-get-interfaces"
ip="$(vm_guest_ip)"
[ "$ip" = "192.168.18.77" ] || { echo "guest ip=$ip"; exit 1; }

vm_set --virtio1 'ioperf:vm-1031-disk-1,aio=native,cache=none'
grep -q "qm set 1031 --virtio1 ioperf:vm-1031-disk-1,aio=native,cache=none" "$FAKE_SSH_LOG" || { echo "vm_set cmd wrong"; exit 1; }

printf '9999\n' > "$FAKE_SSH_DIR/1031.pid"
printf 'x\0y\0z\0' > "$tmp/cmdline.raw"
cp "$tmp/cmdline.raw" "$FAKE_SSH_DIR/proc"
c="$(vm_cmdline)"
echo "$c" | grep -q 'x y z' || { echo "cmdline=$c"; exit 1; }
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-pve.sh`。

- [ ] **Step 3: 實作 lib/pve.sh**

```bash
#!/usr/bin/env bash
# Test-VM lifecycle via qm. Only VMIDs 1031-1039 are allowed.
# Requires lib/common.sh and lib/collect.sh (qemu_pid).

_vmid_guard() {
  case "$VMID" in
    103[1-9]) : ;;
    *) die "VMID $VMID 不在允許範圍 1031-1039" ;;
  esac
}

vm_create() {
  local img="$1" pubkey="$2"
  _vmid_guard
  pve_ssh "sudo -n qm create $VMID --name ioperf-test --cores 4 --memory 4096 \
--net0 virtio,bridge=vmbr1 --scsihw virtio-scsi-single --agent 1 --ostype l26"
  pve_ssh "sudo -n qm set $VMID --scsi0 $POOL:0,import-from=$img"
  pve_ssh "sudo -n qm disk resize $VMID scsi0 10G"
  pve_ssh "sudo -n qm set $VMID --ide2 $POOL:cloudinit --ciuser $GUEST_USER \
--sshkeys $pubkey --ipconfig0 ip=dhcp --boot order=scsi0"
}

vm_attach_data() {
  _vmid_guard
  pve_ssh "sudo -n qm set $VMID --virtio1 $1"
}

vm_set() {
  _vmid_guard
  pve_ssh "sudo -n qm set $VMID $*"
}

vm_cold_restart() {
  _vmid_guard
  pve_ssh "sudo -n qm stop $VMID" || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pve_ssh "sudo -n qm status $VMID" | grep -q stopped && break
    [ "$i" -eq 12 ] && die "VM $VMID 停不下來"
    sleep 5
  done
  pve_ssh "sudo -n qm start $VMID"
  for i in $(seq 1 30); do
    if pve_ssh "sudo -n qm agent $VMID ping >/dev/null 2>&1 && echo up" | grep -q up; then
      return 0
    fi
    sleep 5
  done
  die "VM $VMID 重啟後 guest agent 無回應"
}

vm_config() { _vmid_guard; pve_ssh "sudo -n qm config $VMID"; }

vm_assert_config() {
  vm_config | grep -qE "$1" || die "生效驗證失敗: qm config 缺 '$1'"
}

vm_cmdline() {
  _vmid_guard
  local pid
  pid="$(qemu_pid "$VMID")"
  pve_ssh "sudo -n tr '\\0' ' ' < /proc/$pid/cmdline"
}

vm_assert_cmdline() {
  vm_cmdline | grep -qE "$1" || die "生效驗證失敗: QEMU cmdline 缺 '$1'"
}

vm_guest_ip() {
  _vmid_guard
  pve_ssh "sudo -n qm agent $VMID network-get-interfaces" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for itf in d.get("result", d if isinstance(d, list) else []):
    for a in itf.get("ip-addresses", []):
        ip = a.get("ip-address", "")
        if a.get("ip-address-type") == "ipv4" and ip.startswith("192.168.18."):
            print(ip); raise SystemExit
raise SystemExit("no 192.168.18.x address")'
}

vm_destroy() {
  _vmid_guard
  pve_ssh "sudo -n qm stop $VMID" || true
  pve_ssh "sudo -n qm destroy $VMID --purge" || true
}
```

註：`vm_cmdline` 的 fake 測試以 fixture 檔名 `proc` 匹配 `/proc/<pid>/cmdline` 呼叫；`vm_create` 的 `import-from` 與 `qm disk resize` 語法在 Phase 2 首次真機執行時驗證（PVE 9 支援），失敗屬 runtime 調整範圍。

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 6 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/lib/pve.sh experiments/rbd-io-perf/tests/test-pve.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/pve.sh experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: test-VM lifecycle with VMID guard"
```

---

### Task 7: lib/scenarios.sh（矩陣執行 + A/B 交錯 + verdict 落檔）

**Files:**
- Create: `lib/scenarios.sh`、`tests/test-scenarios.sh`、`tests/fixtures/iostat-host.txt`（任意 iostat 樣式數行）

**Interfaces:**
- Consumes: common/fio/collect/verdict.py。
- Produces:
  - `write_prediction <bundle> <text>`：寫 `<bundle>/prediction.txt`（跑前宣告）。
  - `run_pattern_once <bundle> <round-dir-name> <guest_ip> <dev> <pattern-entry> [host_dev]`：跑一點——pre `ceph -s`、（有 host_dev 時）背景 host iostat、guest fio JSON 落 `<bundle>/<round>/<pattern>.json`、post `ceph -s`、taint 判定（tainted 則檔案改名 `.tainted` 並 return 1）。
  - `run_matrix_rounds <bundle> <label> <guest_ip> <dev> <n> [host_dev]`：整個 `FIO_PATTERNS` × n 輪，輪目錄 `<label>-r<N>`；tainted 該點重試一次。
  - `ab_rounds <bundle> <n> <setup_a_fn> <setup_b_fn> <run_a_fn> <run_b_fn>`：交錯 A/B 執行 n 輪（setup 函式負責 vm_set + restart + 生效驗證）。
  - `emit_verdict <bundle> <pattern> <metric> <expect> <noise_cov> <base-files-csv> <var-files-csv>`：呼叫 verdict.py compare，結果寫 `<bundle>/verdict-<pattern>.json` 且 stdout 一行 verdict JSON。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-scenarios.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"

# fake 回覆：ceph -s 乾淨、guest fio 回 fixture JSON
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name=rr-4k-qd1"

b="$(new_bundle unit)"
write_prediction "$b" "rr-4k-qd1 IOPS 預期不變"
[ -f "$b/prediction.txt" ] || { echo "prediction missing"; exit 1; }

run_pattern_once "$b" r1 192.168.18.77 /dev/vdb "rr-4k-qd1:randread:4k:1" || { echo "pattern run failed"; exit 1; }
[ -s "$b/r1/rr-4k-qd1.json" ] || { echo "fio json missing"; ls -R "$b"; exit 1; }
[ -s "$b/r1/ceph-pre.txt" ] || { echo "ceph pre missing"; exit 1; }

# tainted 路徑：recovery 版 ceph -s → 檔案標記 .tainted 且 return 1
cp "$here/fixtures/ceph-s-recovery.txt" "$FAKE_SSH_DIR/ceph -s"
if run_pattern_once "$b" r2 192.168.18.77 /dev/vdb "rr-4k-qd1:randread:4k:1" 2>/dev/null; then
  echo "tainted not detected"; exit 1
fi
[ -e "$b/r2/rr-4k-qd1.json.tainted" ] || { echo "tainted marker missing"; exit 1; }

# emit_verdict 產出檔案
v="$(emit_verdict "$b" rr-4k-qd1 iops none 0.02 \
     "$here/fixtures/fio-sample-a1.json,$here/fixtures/fio-sample-a2.json" \
     "$here/fixtures/fio-sample-a1.json,$here/fixtures/fio-sample-a2.json")"
echo "$v" | grep -q '"verdict": "confirmed"' || { echo "verdict=$v"; exit 1; }
[ -s "$b/verdict-rr-4k-qd1.json" ] || { echo "verdict file missing"; exit 1; }
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-scenarios.sh`。

- [ ] **Step 3: 實作 lib/scenarios.sh**

```bash
#!/usr/bin/env bash
# Scenario building blocks: single-point run with taint detection,
# matrix rounds, A/B interleaving, machine verdict emission.
# Requires common.sh, fio.sh, collect.sh.

write_prediction() {
  printf '%s\n' "$2" > "$1/prediction.txt"
}

run_pattern_once() {
  local bundle="$1" round="$2" ip="$3" dev="$4" entry="$5" host_dev="${6:-}"
  local name="${entry%%:*}" rd="$bundle/$round"
  mkdir -p "$rd"
  collect_ceph_status "$rd/ceph-pre.txt"
  local iostat_pid=""
  if [ -n "$host_dev" ]; then
    sample_iostat_host "$host_dev" 75 "$rd/iostat-host-$name.txt" &
    iostat_pid=$!
  fi
  guest_ssh "$ip" "sudo $(fio_cmd "$entry" "$dev")" > "$rd/$name.json" || {
    [ -n "$iostat_pid" ] && kill "$iostat_pid" 2>/dev/null
    die "fio $name 執行失敗"
  }
  [ -n "$iostat_pid" ] && wait "$iostat_pid" 2>/dev/null
  collect_ceph_status "$rd/ceph-post.txt"
  if ! taint_check "$rd/ceph-post.txt"; then
    mv "$rd/$name.json" "$rd/$name.json.tainted"
    return 1
  fi
  return 0
}

run_matrix_rounds() {
  local bundle="$1" label="$2" ip="$3" dev="$4" n="$5" host_dev="${6:-}"
  local r entry
  for r in $(seq 1 "$n"); do
    for entry in $FIO_PATTERNS; do
      if ! run_pattern_once "$bundle" "$label-r$r" "$ip" "$dev" "$entry" "$host_dev"; then
        log "tainted，重試一次: $entry ($label-r$r)"
        run_pattern_once "$bundle" "$label-r$r" "$ip" "$dev" "$entry" "$host_dev" ||
          die "連續 tainted，中止（$entry）"
      fi
    done
  done
}

ab_rounds() {
  local bundle="$1" n="$2" setup_a="$3" setup_b="$4" run_a="$5" run_b="$6"
  local r
  for r in $(seq 1 "$n"); do
    log "=== A/B round $r/$n: A ==="
    "$setup_a"; "$run_a" "$r"
    log "=== A/B round $r/$n: B ==="
    "$setup_b"; "$run_b" "$r"
  done
}

emit_verdict() {
  local bundle="$1" pattern="$2" metric="$3" expect="$4" cov="$5" base="$6" var="$7"
  local out
  out="$(python3 "$RBDPERF_ROOT/lib/verdict.py" compare \
    --metric "$metric" --expect "$expect" --noise-cov "$cov" \
    --baseline "$base" --variant "$var")"
  printf '%s\n' "$out" > "$bundle/verdict-$pattern.json"
  printf '%s\n' "$out"
}
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 7 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/lib/scenarios.sh experiments/rbd-io-perf/tests/test-scenarios.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/scenarios.sh experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: scenario building blocks with taint retry and machine verdict"
```

---

### Task 8: run/preflight.sh + run/cleanup.sh

**Files:**
- Create: `run/preflight.sh`、`run/cleanup.sh`、`tests/test-preflight.sh`、`tests/test-cleanup.sh`

**Interfaces:**
- `run/preflight.sh`（**read-only**，不需 inject flag）：收集版本/拓樸/pool/預設/NIC/記憶體/fio 存在性，寫入 `results/preflight/<ts>/snapshot.txt`，stdout 只印 snapshot 路徑。內容各段以 `=== <title> ===` 分隔，依序：`pveversion -v | grep -E 'pve-manager|pve-qemu|ceph:'`、`uname -r`、`ceph -s`、`ceph df`、`ceph osd tree`、`ceph osd pool ls detail`（grep ioperf）、`cat /etc/pve/storage.cfg`、`ceph config get osd osd_op_queue` + `osd_mclock_profile`、`ethtool enp5s0|grep Speed`、`free -g`、`which fio || echo fio-missing`、`qm list`（VMID 1031-1039 佔用檢查——有佔用則 log 警示）。
- `run/cleanup.sh`（需 inject flag）：best-effort 逐步——`vm_destroy`；列出 `rbd ls $POOL` 中 `ioperf-` 前綴 image：先 `rbd showmapped` 找到相應 map 並 unmap，再 `img_rm`；移除測試 storage id `ioperf-krbd`（`pvesm remove ioperf-krbd`，容忍不存在）。每步失敗只 log 不中斷。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-preflight.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"

cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
printf 'pve-manager/9.0.11\n' > "$FAKE_SSH_DIR/pveversion"

out="$(bash "$here/../run/preflight.sh")"
[ -f "$out" ] || { echo "snapshot file missing: $out"; exit 1; }
grep -q '=== ceph -s ===' "$out" || { echo "section missing"; exit 1; }
grep -q 'pve-manager/9.0.11' "$out" || { echo "pveversion missing"; exit 1; }
# read-only：不得出現任何變更動詞
if grep -qE 'qm (create|set|destroy)|rbd (create|rm|map)' "$FAKE_SSH_LOG"; then
  echo "preflight not read-only"; exit 1
fi
echo OK
```

`tests/test-cleanup.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"

# 無旗標必須擋
if bash "$here/../run/cleanup.sh" 2>/dev/null; then echo "inject gate missing"; exit 1; fi

printf 'ioperf-data\nioperf-krbd-a\n' > "$FAKE_SSH_DIR/rbd ls"
printf 'id pool namespace image snap device\n0 ioperf  ioperf-data - /dev/rbd7\n' > "$FAKE_SSH_DIR/showmapped"
bash "$here/../run/cleanup.sh" --yes-really-inject || { echo "cleanup failed"; exit 1; }
grep -q 'qm destroy 1031' "$FAKE_SSH_LOG" || { echo "no vm destroy"; exit 1; }
grep -q 'rbd unmap /dev/rbd7' "$FAKE_SSH_LOG" || { echo "no unmap"; exit 1; }
grep -q 'rbd rm ioperf/ioperf-data' "$FAKE_SSH_LOG" || { echo "no img rm"; exit 1; }
grep -q 'pvesm remove ioperf-krbd' "$FAKE_SSH_LOG" || { echo "no storage remove"; exit 1; }
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → 兩個新測試 FAIL。

- [ ] **Step 3: 實作**

`run/preflight.sh`：

```bash
#!/usr/bin/env bash
# E-00: read-only environment snapshot. stdout prints the snapshot path only.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"

b="$(new_bundle preflight)"
snap="$b/snapshot.txt"

section() { printf '=== %s ===\n' "$1" >> "$snap"; }

section "versions"
pve_ssh "pveversion -v | grep -E 'pve-manager|pve-qemu|^ceph:'; uname -r" >> "$snap"
section "ceph -s"
pve_ssh 'sudo -n ceph -s' >> "$snap"
section "ceph df"
pve_ssh 'sudo -n ceph df' >> "$snap"
section "osd tree"
pve_ssh 'sudo -n ceph osd tree' >> "$snap"
section "pool ioperf"
pve_ssh 'sudo -n ceph osd pool ls detail' | grep -A1 "'$POOL'" >> "$snap" || true
section "storage.cfg"
pve_ssh 'sudo -n cat /etc/pve/storage.cfg' >> "$snap"
section "mclock (read-only)"
pve_ssh 'sudo -n ceph config get osd osd_op_queue; sudo -n ceph config get osd osd_mclock_profile' >> "$snap"
section "mgmt nic speed"
pve_ssh 'sudo -n ethtool enp5s0 | grep Speed' >> "$snap" || true
section "memory"
pve_ssh 'free -g' >> "$snap"
section "fio"
pve_ssh 'which fio || echo fio-missing' >> "$snap"
section "vmid range"
pve_ssh 'sudo -n qm list' | awk '$1 >= 1031 && $1 <= 1039' >> "$snap" || true
if [ -s "$snap" ] && awk '$1 >= 1031 && $1 <= 1039' < /dev/null; then :; fi
if grep -qE '^\s*103[1-9]\s' "$snap"; then log "警示: VMID 1031-1039 範圍有既存 VM"; fi

printf '%s\n' "$snap"
```

`run/cleanup.sh`：

```bash
#!/usr/bin/env bash
# Best-effort cleanup of everything the harness may have created.
# Safe to re-run; each step tolerates absence. Requires --yes-really-inject.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
require_inject_flag "$@"

log "cleanup: destroy test VM $VMID"
vm_destroy || true

log "cleanup: unmap + remove ioperf- images"
mapped="$(pve_ssh 'sudo -n rbd showmapped' 2>/dev/null || true)"
imgs="$(pve_ssh "sudo -n rbd ls $POOL" 2>/dev/null || true)"
for name in $imgs; do
  case "$name" in
    ioperf-*)
      dev="$(printf '%s\n' "$mapped" | awk -v img="$name" '$4 == img {print $6}')"
      [ -n "$dev" ] && { img_unmap "$dev" || true; }
      img_rm "$name" || true
      ;;
  esac
done

log "cleanup: remove test storage id ioperf-krbd"
pve_ssh 'sudo -n pvesm remove ioperf-krbd' 2>/dev/null || true
log "cleanup done"
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 9 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/run/preflight.sh experiments/rbd-io-perf/run/cleanup.sh experiments/rbd-io-perf/tests/test-preflight.sh experiments/rbd-io-perf/tests/test-cleanup.sh` → exit 0。
（若 preflight.sh 中殘留無效的防呆行——`if [ -s "$snap" ] && awk ...` 一行為冗餘，實作時直接刪除，保留 `grep -qE '^\s*103[1-9]\s'` 檢查即可。）

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/run/ experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: read-only preflight and best-effort cleanup"
```

---

### Task 9: run/krbd-check.sh（E-01 三關）

**Files:**
- Create: `run/krbd-check.sh`、`tests/test-krbd-check.sh`

**Interfaces:**
- 需 inject flag。三關依序，任一關失敗 → stdout 印 `krbd: unusable (<關卡>)` 並 exit 1；全過印 `krbd: usable`：
  1. `img_create ioperf-krbdchk 1G` → `img_map` → 遠端 `dd if=/dev/zero of=<dev> bs=4k count=16 oflag=direct` + `dd if=<dev> ... iflag=direct` → `img_unmap` → `img_rm`。
  2. `img_info` 檢視 features 行並寫入 stdout 前的 log（記錄用，不判斷——map 成功即代表相容）。
  3. storage id：`pvesm add rbd ioperf-krbd --pool $POOL --content images --krbd 1` → `pvesm status | grep ioperf-krbd` → `pvesm remove ioperf-krbd`（第三關只驗 storage 定義可建立；掛盤到 VM 留給 E-04 實測）。
- 全程 trap cleanup：失敗也要 unmap/rm/remove。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-krbd-check.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"

if bash "$here/../run/krbd-check.sh" 2>/dev/null; then echo "inject gate missing"; exit 1; fi

printf '/dev/rbd9\n' > "$FAKE_SSH_DIR/rbd map"
printf 'features: layering\n' > "$FAKE_SSH_DIR/rbd info"
printf 'ioperf-krbd rbd active\n' > "$FAKE_SSH_DIR/pvesm status"
out="$(bash "$here/../run/krbd-check.sh" --yes-really-inject)"
[ "$out" = "krbd: usable" ] || { echo "out=$out"; exit 1; }
grep -q 'rbd create ioperf/ioperf-krbdchk' "$FAKE_SSH_LOG" || exit 1
grep -q 'oflag=direct' "$FAKE_SSH_LOG" || { echo "no direct write probe"; exit 1; }
grep -q 'rbd unmap /dev/rbd9' "$FAKE_SSH_LOG" || exit 1
grep -q 'rbd rm ioperf/ioperf-krbdchk' "$FAKE_SSH_LOG" || exit 1
grep -q 'pvesm add rbd ioperf-krbd --pool ioperf --content images --krbd 1' "$FAKE_SSH_LOG" || exit 1
grep -q 'pvesm remove ioperf-krbd' "$FAKE_SSH_LOG" || exit 1
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-krbd-check.sh`。

- [ ] **Step 3: 實作 run/krbd-check.sh**

```bash
#!/usr/bin/env bash
# E-01: three-gate krbd feasibility check. Own resources only.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
require_inject_flag "$@"

CHK_IMG="ioperf-krbdchk"
DEV=""
cleanup() {
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$CHK_IMG" 2>/dev/null || true
  pve_ssh 'sudo -n pvesm remove ioperf-krbd' 2>/dev/null || true
}
trap cleanup EXIT

log "關卡 1: map + direct 讀寫"
img_create "$CHK_IMG" 1G
if ! DEV="$(img_map "$CHK_IMG")" || [ -z "$DEV" ]; then
  echo "krbd: unusable (map)"; exit 1
fi
if ! pve_ssh "sudo -n dd if=/dev/zero of=$DEV bs=4k count=16 oflag=direct 2>/dev/null && sudo -n dd if=$DEV of=/dev/null bs=4k count=16 iflag=direct 2>/dev/null"; then
  echo "krbd: unusable (io)"; exit 1
fi

log "關卡 2: 記錄 image features"
img_info "$CHK_IMG" | grep -i features >&2 || true

img_unmap "$DEV"; DEV=""
img_rm "$CHK_IMG"

log "關卡 3: krbd=1 storage 定義"
if ! pve_ssh "sudo -n pvesm add rbd ioperf-krbd --pool $POOL --content images --krbd 1"; then
  echo "krbd: unusable (storage)"; exit 1
fi
pve_ssh 'sudo -n pvesm status' | grep -q ioperf-krbd || { echo "krbd: unusable (storage)"; exit 1; }
pve_ssh 'sudo -n pvesm remove ioperf-krbd'

echo "krbd: usable"
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 10 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/run/krbd-check.sh experiments/rbd-io-perf/tests/test-krbd-check.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/run/krbd-check.sh experiments/rbd-io-perf/tests/test-krbd-check.sh
git commit --no-gpg-sign -m "rbd-io-perf: E-01 krbd feasibility three-gate check"
```

---

### Task 10: run/exp0-host-ceiling.sh + run/baseline.sh

**Files:**
- Create: `run/exp0-host-ceiling.sh`、`run/baseline.sh`、`tests/test-exp0.sh`、`tests/test-baseline.sh`

**Interfaces:**
- `run/exp0-host-ceiling.sh`（inject flag）：E-02。`img_create ioperf-ceiling 16G` → `img_map` → 遠端 prefill（`prefill_cmd`）→ 對 `FIO_PATTERNS` 各跑 n 輪（`EXP0_ROUNDS`，預設 3）×兩 engine（libaio / io_uring；把 `fio_cmd` 輸出的 `--ioengine=libaio` 以 `sed 's/--ioengine=libaio/--ioengine=io_uring/'` 替換產生第二組）→ JSON 落 bundle `exp0/<ts>/<engine>-r<N>/<pattern>.json` → `img_unmap` + `img_rm`（trap 保證）→ stdout 印 bundle 路徑。fio 在 **node** 上跑（`pve_ssh "sudo -n $(fio_cmd ...)"`）。
- `run/baseline.sh`（inject flag）：E-03。步驟：cloud image 存在檢查（`ls <CLOUDIMG>`，預設 `/mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img`，環境變數 `CLOUDIMG` 可覆寫；不存在則 die 並提示下載指令）→ 公鑰上傳（`~/.ssh/ioperf.pub`：`pve_ssh 'cat > /home/ioperf/ioperf.pub' < "$SSH_KEY.pub"`）→ `vm_create` + `vm_attach_data "ioperf:16"` + `vm_set --virtio1 ...`（保持 PVE 預設，不額外帶 cache/aio 參數）→ `vm_cold_restart` → `vm_guest_ip` → guest 安裝檢查（`guest_ssh $ip 'which fio || sudo apt-get install -y fio'`）→ guest prefill `/dev/vdb` → 記錄 `vm_config`、`vm_cmdline`、guest `ls /sys/block/vdb/mq/` 到 bundle → `run_matrix_rounds <bundle> base <ip> /dev/vdb "$BASELINE_ROUNDS"`（預設 5）→ 對每 pattern 用 verdict.py summarize 算 CoV 寫 `noise.json` → stdout 印 bundle 路徑。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-exp0.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
export EXP0_ROUNDS=1

if bash "$here/../run/exp0-host-ceiling.sh" 2>/dev/null; then echo "gate missing"; exit 1; fi

printf '/dev/rbd5\n' > "$FAKE_SSH_DIR/rbd map"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
out="$(bash "$here/../run/exp0-host-ceiling.sh" --yes-really-inject)"
[ -d "$out" ] || { echo "bundle missing: $out"; exit 1; }
[ -s "$out/libaio-r1/rr-4k-qd1.json" ] || { echo "libaio json missing"; ls -R "$out"; exit 1; }
[ -s "$out/io_uring-r1/rr-4k-qd1.json" ] || { echo "io_uring json missing"; exit 1; }
grep -q -- '--ioengine=io_uring' "$FAKE_SSH_LOG" || { echo "no io_uring run"; exit 1; }
grep -q 'rbd unmap /dev/rbd5' "$FAKE_SSH_LOG" || { echo "no unmap"; exit 1; }
grep -q 'rbd rm ioperf/ioperf-ceiling' "$FAKE_SSH_LOG" || { echo "no rm"; exit 1; }
echo OK
```

`tests/test-baseline.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
export BASELINE_ROUNDS=1
export SSH_KEY="$tmp/key"; : > "$SSH_KEY"; printf 'ssh-ed25519 AAA test\n' > "$SSH_KEY.pub"

if bash "$here/../run/baseline.sh" 2>/dev/null; then echo "gate missing"; exit 1; fi

printf '/mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img\n' > "$FAKE_SSH_DIR/ls /mnt"
cp "$here/fixtures/qm-config-baseline.txt" "$FAKE_SSH_DIR/qm config 1031"
cp "$here/fixtures/qm-agent-ip.json" "$FAKE_SSH_DIR/network-get-interfaces"
printf 'stopped\n' > "$FAKE_SSH_DIR/qm status"
printf 'up\n' > "$FAKE_SSH_DIR/qm agent 1031 ping"
printf '9999\n' > "$FAKE_SSH_DIR/1031.pid"
printf 'qemu x y\n' > "$FAKE_SSH_DIR/proc"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
printf '/usr/bin/fio\n' > "$FAKE_SSH_DIR/which fio"
printf 'mq0 mq1\n' > "$FAKE_SSH_DIR/sys/block"
rm -f "$FAKE_SSH_DIR/sys/block"; printf '0 1 2 3\n' > "$FAKE_SSH_DIR/vdb/mq"

out="$(bash "$here/../run/baseline.sh" --yes-really-inject)"
[ -d "$out" ] || { echo "bundle missing: $out"; exit 1; }
[ -s "$out/base-r1/rr-4k-qd1.json" ] || { echo "matrix json missing"; ls -R "$out"; exit 1; }
[ -s "$out/qm-config.txt" ] || { echo "config record missing"; exit 1; }
[ -s "$out/noise.json" ] || { echo "noise.json missing"; exit 1; }
grep -q 'qm create 1031' "$FAKE_SSH_LOG" || { echo "no vm create"; exit 1; }
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → 兩個新測試 FAIL。

- [ ] **Step 3: 實作**

`run/exp0-host-ceiling.sh`：

```bash
#!/usr/bin/env bash
# E-02: host-level ceiling on /dev/rbdX, libaio vs io_uring. VM not involved.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
require_inject_flag "$@"

ROUNDS="${EXP0_ROUNDS:-3}"
IMG="ioperf-ceiling"
DEV=""
cleanup() {
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

b="$(new_bundle exp0)"
write_prediction() { printf '%s\n' "$1" > "$b/prediction.txt"; }
write_prediction "E-02: 高 QD 下 libaio vs io_uring 差異落噪音帶內；qd1 io_uring 略優。此組數字為 ceph 側天花板。"

img_create "$IMG" 16G
DEV="$(img_map "$IMG")"
[ -n "$DEV" ] || die "map 失敗"
log "prefill $DEV"
pve_ssh "sudo -n $(prefill_cmd "$DEV")" > "$b/prefill.json"

for engine in libaio io_uring; do
  for r in $(seq 1 "$ROUNDS"); do
    rd="$b/$engine-r$r"; mkdir -p "$rd"
    collect_ceph_status "$rd/ceph-pre.txt"
    for entry in $FIO_PATTERNS; do
      name="${entry%%:*}"
      cmd="$(fio_cmd "$entry" "$DEV" | sed "s/--ioengine=libaio/--ioengine=$engine/")"
      pve_ssh "sudo -n $cmd" > "$rd/$name.json" || die "fio $name ($engine) 失敗"
    done
    collect_ceph_status "$rd/ceph-post.txt"
  done
done

printf '%s\n' "$b"
```

`run/baseline.sh`：

```bash
#!/usr/bin/env bash
# E-03: create the test VM with PVE defaults, prefill, run the matrix
# BASELINE_ROUNDS times, emit per-pattern noise (CoV).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${BASELINE_ROUNDS:-5}"
CLOUDIMG="${CLOUDIMG:-/mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img}"

pve_ssh "ls $CLOUDIMG" >/dev/null 2>&1 || die "cloud image 不存在: $CLOUDIMG（下載: wget -O $CLOUDIMG https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img）"

b="$(new_bundle baseline)"
write_prediction "$b" "E-03: 量噪音帶（CoV）與虛擬化稅占比（H-003 無先驗預測）。guest /sys/block/vdb/mq 預期 = vCPU 數（H-026）。"

pve_ssh 'cat > /home/ioperf/ioperf.pub' < "$SSH_KEY.pub"
vm_create "$CLOUDIMG" /home/ioperf/ioperf.pub
vm_attach_data "$POOL:16"
vm_cold_restart
ip="$(vm_guest_ip)"
log "guest ip: $ip"

guest_ssh "$ip" 'which fio >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y -qq fio)' >/dev/null
guest_ssh "$ip" 'which iostat >/dev/null 2>&1 || sudo apt-get install -y -qq sysstat' >/dev/null

vm_config > "$b/qm-config.txt"
vm_cmdline > "$b/qemu-cmdline.txt"
guest_ssh "$ip" 'ls /sys/block/vdb/mq/' > "$b/guest-mq.txt" || true

log "prefill guest /dev/vdb"
guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/prefill.json"

run_matrix_rounds "$b" base "$ip" /dev/vdb "$ROUNDS"

# per-pattern noise
: > "$b/noise.json"
for entry in $FIO_PATTERNS; do
  name="${entry%%:*}"
  files=""
  for r in $(seq 1 "$ROUNDS"); do
    f="$b/base-r$r/$name.json"
    [ -s "$f" ] && files="$files $f"
  done
  # shellcheck disable=SC2086  # word-splitting files list is intended
  s="$(python3 "$RBDPERF_ROOT/lib/verdict.py" summarize $files)"
  printf '{"pattern": "%s", "summary": %s}\n' "$name" "$s" >> "$b/noise.json"
done

printf '%s\n' "$b"
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 12 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/run/exp0-host-ceiling.sh experiments/rbd-io-perf/run/baseline.sh experiments/rbd-io-perf/tests/test-exp0.sh experiments/rbd-io-perf/tests/test-baseline.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/run/ experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: E-02 host ceiling and E-03 baseline runners"
```

---

### Task 11: 變體 scenario 腳本（E-04～E-15）+ run/all.sh

**Files:**
- Create: `run/scenario-exp-axis.sh`、`run/scenario-exp1-cache.sh`、`run/scenario-exp4-aio.sh`、`run/scenario-exp2-iothread.sh`、`run/scenario-exp8-queues.sh`、`run/scenario-exp9-layout.sh`、`run/scenario-exp10-qdepth.sh`、`run/scenario-exp11-sched.sh`、`run/scenario-exp12-allocsize.sh`、`run/scenario-exp13-readahead.sh`、`run/scenario-exp14-rxbounce.sh`、`run/scenario-exp15-rbdcache.sh`、`run/all.sh`、`tests/test-scenario-qmvariant.sh`
- Modify: `lib/scenarios.sh`（新增 `run_qm_variant_scenario`）

**Interfaces:**
- 共用引擎 `run_qm_variant_scenario <scenario-name> <prediction> <baseline-disk-spec> <variant-disk-spec> <verify-pattern> <rounds>`（加入 `lib/scenarios.sh`）：假設測試 VM 已由 baseline.sh 建好——A 設定 = `vm_set --virtio1 <baseline-disk-spec>` + `vm_cold_restart`；B 設定 = 同以 variant spec + `vm_assert_cmdline <verify-pattern>`；`ab_rounds` 交錯跑矩陣（guest ip 每次 restart 後重取）；結束時把 disk 設回 baseline spec。stdout 印 bundle 路徑。
- 12 支 scenario 腳本 = 薄 wrapper：source libs → `require_inject_flag` → 呼叫引擎（或少量自訂步驟）。變體定義如下（disk spec 基底 `DATA_SPEC="${DATA_SPEC:-ioperf:vm-1031-disk-1}"`，qm set 重用既有 volume 只改參數）：
  - `exp1-cache`：三變體迴圈 `cache=none|writethrough|writeback`（baseline= none）；verify `cache=<val>`（cmdline / qm config）。另兩條 buffered job：`--direct=0` 與 `--direct=0 --fsync=1`（對 rw-4k-qd1 pattern 各跑一次/輪，指令由 `fio_cmd` 輸出 sed 掉 `--direct=1`）。
  - `exp4-aio`：`aio=io_uring|native|threads`；native 變體 spec 同時帶 `cache=none`（O_DIRECT 前提）；verify `aio=<val>`。
  - `exp2-iothread`：`iothread=0|1`；verify `iothread`。
  - `exp8-queues`：variant 用 `vm_set --args '-set device.virtio1.num-queues=1'`（強制單 queue）vs baseline 清除 `--args`（`qm set 1031 --delete args`）；verify guest `ls /sys/block/vdb/mq/ | wc -l`＝1 vs >1；額外跑 `fio_cmd_numjobs ... 4`。`--args` 的精確 QEMU 參數格式在 Phase 2 真機驗證（HYPOTHESES H-026 Notes 追蹤），偏差屬 runtime 調整。
  - `exp9-layout`：不用 qm 變體引擎——三顆 image（`img_create ioperf-lay4m 16G --object-size 4M` / `ioperf-lay16m ... 16M` / `ioperf-laystripe ... --object-size 4M --stripe-unit 64K --stripe-count 16`），逐顆 `vm_attach_data`（既有 volume 先 `qm set --delete virtio1`）→ prefill → 矩陣 n 輪 → 卸下 → `img_rm`；焦點 `sr-1m`/`sw-1m`。
  - `exp10-qdepth`：`img_create ioperf-qd 16G` → 對 `queue_depth=64|128|256` 各：`img_map` with option → `vm_attach_data /dev/rbdN` → prefill →矩陣 → 卸下 unmap；記錄 `/sys/block/rbdN/queue/nr_requests` 與 scheduler。
  - `exp11-sched`：guest 內 `echo none | sudo tee /sys/block/vdb/queue/scheduler` vs 預設；不需 restart；verify `cat scheduler` 帶 `[none]`。
  - `exp12-allocsize`：同 exp10 手法，`alloc_size=4096|65536`；記錄 `minimum_io_size`；預期 `none`（expect none）。
  - `exp13-readahead`：guest `read_ahead_kb 0|128|4096`（sysfs，不需 restart）；焦點 `sr-1m`。
  - `exp14-rxbounce`：同 exp10 手法，map options `rxbounce` on/off；全程 `collect_dmesg_marker`/`collect_dmesg_delta`。
  - `exp15-rbdcache`：librbd 軸——`img_meta_set ioperf-data conf_rbd_cache false|true` + `vm_cold_restart`；verify `rbd image-meta get`。
  - `exp-axis`：`img_create ioperf-axis 16G`；A = librbd（`vm_attach_data "ioperf:vm-1031-disk-1..."` 既有盤）、B = krbd（`pvesm add rbd ioperf-krbd --krbd 1` + `vm_attach_data "ioperf-krbd:16"`）… B 側 attach 後 prefill；結束 remove storage id。verify：B 側 `rbd showmapped` 有 device、A 側 cmdline 含 `rbd:`。
- `run/all.sh`：依序呼叫 preflight → krbd-check → exp0 → baseline → exp-axis → exp1 → exp4 → exp2 → exp8 → exp9 → exp10 → exp11 → exp12 → exp13 → exp14 → exp15 → cleanup，全帶 `--yes-really-inject` 透傳；任一步非零即停（cleanup 仍跑，`trap`）。
- 測試：新增 `tests/test-scenario-qmvariant.sh` 驗證引擎（fake 下：A/B 各一輪、qm set 兩 spec、assert cmdline、回設 baseline）；12 支 wrapper 各以「無旗標必擋」+「`bash -n` 語法可過」納入 run-tests（在 test 內迴圈檢查，不逐支寫測試）。

- [ ] **Step 1: 寫會失敗的測試**

`tests/test-scenario-qmvariant.sh`：

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"

cp "$here/fixtures/qm-config-baseline.txt" "$FAKE_SSH_DIR/qm config 1031"
cp "$here/fixtures/qm-agent-ip.json" "$FAKE_SSH_DIR/network-get-interfaces"
printf 'stopped\n' > "$FAKE_SSH_DIR/qm status"
printf 'up\n' > "$FAKE_SSH_DIR/qm agent 1031 ping"
printf '9999\n' > "$FAKE_SSH_DIR/1031.pid"
printf 'qemu aio=native x\n' > "$FAKE_SSH_DIR/proc"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"

out="$(SCEN_ROUNDS=1 run_qm_variant_scenario unitqm "pred" \
  "ioperf:vm-1031-disk-1" "ioperf:vm-1031-disk-1,aio=native,cache=none" "aio=native" 1)"
[ -d "$out" ] || { echo "bundle missing"; exit 1; }
grep -q 'qm set 1031 --virtio1 ioperf:vm-1031-disk-1,aio=native,cache=none' "$FAKE_SSH_LOG" || { echo "variant set missing"; exit 1; }
[ -s "$out/A-r1/rr-4k-qd1.json" ] || { echo "A round missing"; ls -R "$out"; exit 1; }
[ -s "$out/B-r1/rr-4k-qd1.json" ] || { echo "B round missing"; exit 1; }
# 收尾回設 baseline spec（log 最後一次 qm set 是 baseline）
tail -5 "$FAKE_SSH_LOG" | grep -q 'qm set 1031 --virtio1 ioperf:vm-1031-disk-1$' || { echo "no baseline restore"; exit 1; }

# 12 支 wrapper：語法 + inject gate
for s in "$here"/../run/scenario-*.sh; do
  bash -n "$s" || { echo "syntax: $s"; exit 1; }
  if bash "$s" 2>/dev/null; then echo "gate missing: $s"; exit 1; fi
done
echo OK
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `FAIL test-scenario-qmvariant.sh`。

- [ ] **Step 3: 實作**

在 `lib/scenarios.sh` 追加：

```bash
run_qm_variant_scenario() {
  local scen="$1" pred="$2" base_spec="$3" var_spec="$4" verify="$5" rounds="$6"
  local b ip
  b="$(new_bundle "$scen")"
  write_prediction "$b" "$pred"

  _setup_a() {
    vm_set --virtio1 "$base_spec"
    vm_cold_restart
  }
  _setup_b() {
    vm_set --virtio1 "$var_spec"
    vm_cold_restart
    vm_assert_cmdline "$verify"
  }
  _run_a() { ip="$(vm_guest_ip)"; run_matrix_rounds "$b" "A" "$ip" /dev/vdb 1; mv "$b/A-r1" "$b/A-r$1" 2>/dev/null || true; }
  _run_b() { ip="$(vm_guest_ip)"; run_matrix_rounds "$b" "B" "$ip" /dev/vdb 1; mv "$b/B-r1" "$b/B-r$1" 2>/dev/null || true; }

  ab_rounds "$b" "$rounds" _setup_a _setup_b _run_a _run_b
  vm_set --virtio1 "$base_spec"
  printf '%s\n' "$b"
}
```

（實作註：`run_matrix_rounds` 的 label 目錄以 `A-r1` 固定產生後改名到當前輪次，避免函式間傳輪次；若 round 1 目錄已存在改名失敗屬預期，實作時以 `label="A$1"` 直接傳輪次進 `run_matrix_rounds` 更乾淨——擇一，測試斷言的是 `A-r1`/`B-r1` 存在與收尾回設。）

12 支 wrapper 全部同構——以 `run/scenario-exp4-aio.sh` 為完整範本：

```bash
#!/usr/bin/env bash
# E-06 (exp4): aio=io_uring / native / threads, A/B interleaved vs PVE default.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${SCEN_ROUNDS:-3}"
BASE="${DATA_SPEC:-ioperf:vm-1031-disk-1}"

for aio in native threads; do
  spec="$BASE,aio=$aio"
  [ "$aio" = "native" ] && spec="$spec,cache=none"
  run_qm_variant_scenario "exp4-aio-$aio" \
    "E-06: 高 QD 下 threads 落後 native/io_uring；qd1 三者接近（機制推論）" \
    "$BASE" "$spec" "aio=$aio" "$ROUNDS"
done
```

其餘 11 支腳本以同樣骨架撰寫，差異只在變體迴圈與 verify pattern（依本 task Interfaces 節的變體定義逐支實作；exp9/exp10/exp12/exp14 走 image/map 手法而非 `run_qm_variant_scenario`，其步驟：build image →（map）→ attach → prefill → `run_matrix_rounds` → detach →（unmap）→ rm，全部包 `trap` 清理；exp11/exp13 為 guest sysfs 直改，不 restart，用 `run_matrix_rounds` 前後各設定/回設）。每支：`set -eu`、source 同一組 libs、`require_inject_flag "$@"`、stdout 只印 bundle 路徑（多變體則逐行多個路徑）。

`run/all.sh`：

```bash
#!/usr/bin/env bash
# Full automation-safe chain. Gated experiments do not exist in this harness
# (cluster-scope was cut from scope); cleanup always runs at the end.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
require_flag_ok=0
for a in "$@"; do [ "$a" = "--yes-really-inject" ] && require_flag_ok=1; done
[ "$require_flag_ok" -eq 1 ] || { echo "需要 --yes-really-inject" >&2; exit 1; }

trap 'bash "$here/cleanup.sh" --yes-really-inject || true' EXIT
set -e
bash "$here/preflight.sh"
bash "$here/krbd-check.sh" --yes-really-inject
bash "$here/exp0-host-ceiling.sh" --yes-really-inject
bash "$here/baseline.sh" --yes-really-inject
for s in scenario-exp-axis scenario-exp1-cache scenario-exp4-aio scenario-exp2-iothread \
         scenario-exp8-queues scenario-exp9-layout scenario-exp10-qdepth scenario-exp11-sched \
         scenario-exp12-allocsize scenario-exp13-readahead scenario-exp14-rxbounce scenario-exp15-rbdcache; do
  bash "$here/$s.sh" --yes-really-inject
done
```

- [ ] **Step 4: 跑測試確認通過 + shellcheck**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → `tests: 13 passed, 0 failed`。
Run: `shellcheck experiments/rbd-io-perf/lib/scenarios.sh experiments/rbd-io-perf/run/*.sh experiments/rbd-io-perf/tests/test-scenario-qmvariant.sh` → exit 0。

- [ ] **Step 5: Commit**

```bash
git add experiments/rbd-io-perf/lib/scenarios.sh experiments/rbd-io-perf/run/ experiments/rbd-io-perf/tests/
git commit --no-gpg-sign -m "rbd-io-perf: variant scenarios E-04..E-15 and all.sh chain"
```

---

### Task 12: README + 全量 gate

**Files:**
- Create: `experiments/rbd-io-perf/README.md`

**Interfaces:** README 為 Phase 2/3 的 runbook 入口，段落：安全界線（三條底線 + guardrails + 只動自有資源）、前置（帳號/fio 安裝指令 `apt install fio`/cloud image 下載指令）、執行順序（preflight → krbd-check → exp0 → baseline → 各 scenario → cleanup；逐支指令）、本機驗證 gate（run-tests / shellcheck / make validate 三行）、環境變數一覽（PVE_HOST/VMID/POOL/ROUNDS/DATA_SPEC/CLOUDIMG）、結果去向（bundle 結構、EVIDENCE-SUMMARY 慣例、頁面回填規範連結）、Gate 2/3 說明（每個真機階段先等使用者 go；Gate 3 依 HYPOTHESES.md）。

- [ ] **Step 1: 寫 README.md**（依上述段落，指令逐字可複製；此為文件 task，無失敗測試）
- [ ] **Step 2: 全量 gate**

Run: `bash experiments/rbd-io-perf/tests/run-tests.sh` → 全綠。
Run: `shellcheck experiments/rbd-io-perf/lib/*.sh experiments/rbd-io-perf/run/*.sh experiments/rbd-io-perf/tests/*.sh experiments/rbd-io-perf/tests/fakes/ssh` → exit 0。
Run: `make validate` → All checks passed。

- [ ] **Step 3: Commit**

```bash
git add experiments/rbd-io-perf/README.md
git commit --no-gpg-sign -m "rbd-io-perf: runbook README and full local gate"
```

---

### Task 13: 批次 1 — rbd-io-tuning-catalog 修正（H-001 / H-026）

**Files:**
- Modify: `next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx`

三處 Edit（old_string 取自現檔，逐字）：

- [ ] **Step 1: cache 條目補「留空即 none」**

old_string（① 層 cache 條目的風險/前提行）：
```
- **風險 / 前提**：對 RBD block device，`cache=none` 是最常見且語意最乾淨的選擇；改成 writeback 會把 correctness 賭在 host page cache 與 flush 行為上，與下面 `io` 的 auto 推導交互（見第 ② 層 `SetOptimalIOMode`）。
```
new_string：
```
- **風險 / 前提**：對 RBD block device，`cache=none` 是最常見且語意最乾淨的選擇；改成 writeback 會把 correctness 賭在 host page cache 與 flush 行為上，與下面 `io` 的 auto 推導交互（見第 ② 層 `SetOptimalIOMode`）。**注意：此欄位留空不等於「無 cache 意圖」**——converter 的 `SetDriverCacheMode` 對支援 direct IO 的 block device 會自動補成 `none`（`File: kubevirt/pkg/virt-launcher/virtwrap/converter/converter.go` 約 L371-429，`manager.go` 約 L838-842 對每顆 disk 無條件執行），所以「全留空」在 RBD 上實際得到 `cache=none` + `io=native`。
```

- [ ] **Step 2: ② 層自動推導條目補全鏈**

old_string：
```
- **風險 / 前提**：推導只在「使用者沒指定 `io`」時發生；一旦手填 `io`，這條 auto 路徑就被跳過。註解也明說目前對 sparse file 不主動設 `io=threads`，所以非 block / 非 preallocated 後端可能留空。
```
new_string：
```
- **風險 / 前提**：推導只在「使用者沒指定 `io`」時發生；一旦手填 `io`，這條 auto 路徑就被跳過。註解也明說目前對 sparse file 不主動設 `io=threads`，所以非 block / 非 preallocated 後端可能留空。另外這條推導的上游還有一層：`cache` 留空時 `SetDriverCacheMode` 會先把它補成 `none`（block device 支援 direct IO 時），兩層自動化疊起來就是「什麼都不寫，最後跑 `cache=none` + `io=native`」——實驗計畫頁 v1 的 baseline 幻覺正是沒看到這條鏈。
```

- [ ] **Step 3: blockMultiQueue 條目修正（H-026）**

old_string（blockMultiQueue 條目的作用機制行內起頭）：
```
- **作用機制**：開啟後 converter 把 disk 的 `driver.queues` 設成 vCPU 數，讓 guest virtio-blk 協商出多條 virtqueue（datapath §① guest 把 request 放進 vring、§② 每條 queue 各自 kick）。多 queue 讓不同 vCPU 各走一條 vring，減少 §② kick 路徑的鎖爭用。converter 只對 `Bus == virtio` 的 disk 設 `Driver.Queues`。
```
new_string：
```
- **作用機制**：開啟後 converter 把 disk 的 `driver.queues` 設成 vCPU 數，讓 guest virtio-blk 協商出多條 virtqueue（datapath §① guest 把 request 放進 vring、§② 每條 queue 各自 kick）。converter 只對 `Bus == virtio` 的 disk 設 `Driver.Queues`。**但注意：不開它也不是單 queue**——QEMU ≥5.2 的 virtio-blk `num-queues` 預設是 AUTO、realize 時解析成 vCPU 數（`File: qemu/hw/block/virtio-blk.c` 約 L1997-1998、`qemu/hw/virtio/virtio-blk-pci.c` 約 L56-58），且 libvirt 在 queues 未設時不輸出該屬性（`File: libvirt/src/qemu/qemu_command.c` 約 L1692 的 `p:` 修飾詞）、預設直通。所以此旋鈕在新 QEMU 上是「把 queues 明確設成與 auto 相同的值」，機制上傾向 no-op——實際差異待實驗反向對照（強制 queues=1 vs auto）驗證。
```

- [ ] **Step 4: 驗證 + commit**

Run: `make validate` → All checks passed。

```bash
git add next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx
git commit --no-gpg-sign -m "vm-storage-perf: catalog batch-1 fixes for H-001/H-026 baseline illusions"
```

---

## Self-Review 紀錄

- **Spec coverage**：spec §4 六原則 → Task 4（taint/guard）、Task 7（A/B、prediction、verdict）、Task 10（pre-fill、噪音帶、生效驗證記錄）；§5 實驗表 → Task 8-11 全對應（gated 實驗已於 charter v2 剪除，無對應 task 為正確）；§6 檔案樹全建；§8 批次 1 → Task 13（experiment-plan 頁已於 c3efb71 重寫，catalog 三處在此補）。Phase 2/3 執行不屬本計畫（README runbook 承接）。
- **Placeholder scan**：Task 11 的 11 支同構 wrapper 以完整範本 + 逐支變體定義表呈現（變體迴圈/verify pattern 均已具體給出），無 TBD。
- **型別/命名一致性**：`pve_ssh`/`guest_ssh`/`img_*`/`vm_*`/`run_matrix_rounds`/`emit_verdict` 各 task Interfaces 與程式碼一致；`FIO_PATTERNS` entry 格式 `name:rw:bs:qd` 貫穿 Task 3/7/10/11。
- **已知 runtime 驗證點**（非 placeholder，屬 Phase 2 首跑調整範圍，全部記錄於 HYPOTHESES.md 或本檔）：`qm set --args` 強制 num-queues 的精確語法（E-08）、`import-from` 與 `qm disk resize` 在 PVE 9 的回傳格式、`qm monitor` QMP blockstats 收集（v2 追加，未列入本輪 collect.sh——E-03 只靠 fio JSON + iostat 已足以出噪音帶與虛擬化稅）。
