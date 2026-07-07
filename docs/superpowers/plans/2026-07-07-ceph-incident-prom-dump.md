# Ceph Incident Bundle — Prometheus Metrics Dump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `collect.sh` 新增選用的 `--prom-url`，把執行當下往回 `--since` 窗內、job 名稱符合 ceph/node 的所有 Prometheus metrics 逐一 `query_range` dump 成 `.json.gz`，收進同一個 incident bundle。

**Architecture:** 新 collector `lib/collect-prometheus.sh`（工作機本機 curl 打 Prometheus HTTP API：buildinfo 探測 → job 列舉過濾 → 逐 job 列 metric 名 → 逐 metric query_range），由 `run/collect.sh` 在 `collect_clusters` 之後呼叫。metric dump 排除在 redaction 之外；manifest 每 job 一筆。

**Tech Stack:** bash 3.2、curl、python3（僅解析 label-values JSON）、既有 common.sh helpers（`write_skip_artifact`/`manifest_add`/`progress`/`ssh_debug_safe_name`）。

**Spec:** `docs/superpowers/specs/2026-07-07-ceph-incident-prom-dump-design.md`

## Global Constraints

- bash 3.2 相容：無 `mapfile`/nameref；`set -u` 下空陣列展開要用 `"${arr[@]+"${arr[@]}"}"` 保護；regex 一律放變數再 `[[ $x =~ $re ]]`（不可加引號）。
- stdout 合約：`collect.sh` stdout 只有最後的 `bundle:` 行；log/progress 一律 stderr。
- 對目標系統 read-only；本 feature 只有 HTTP GET。
- `shellcheck lib/*.sh run/*.sh tests/*.sh` 必須 0（含 info 級）；誤報才可用附註解的 disable。已知可能的誤報：測試裡刻意用 subshell 限縮 PATH 若觸發 SC2030/SC2031，屬 by-design，加註解 disable。
- 每個 task 的 commit 前三個 gate 全綠：`bash experiments/ceph-incident-bundle/tests/run-tests.sh`、`shellcheck`（上行 glob）、repo root `make validate`。
- commit 用 `git commit --no-gpg-sign`，訊息結尾加：

  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01BiVRqBqUuAN7QFZw1xUMwb
  ```
- 不 push（使用者未要求）。
- 文件 zh-TW 台灣用語；never-translate 清單的技術名詞保留英文；程式碼註解英文。
- 測試裡對 function 呼叫帶環境變數時**不要**用 `VAR=x func` 前綴（舊 bash 有殘留疑慮），一律 `( export VAR=x; func )` subshell 形式。

**工作目錄**：下面所有相對路徑以 `experiments/ceph-incident-bundle/` 為準；git 指令在 repo root（`/Users/ikaros/Documents/code/learning-k8s`）跑。

---

### Task 1: 純 helper 函式（duration/step/mask/deps）+ 測試檔骨架 + run-tests 註冊

**Files:**
- Create: `experiments/ceph-incident-bundle/lib/collect-prometheus.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-prom-collector.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`（檔案清單 + 執行區塊）

**Interfaces:**
- Consumes: `lib/common.sh` 的 `log`。
- Produces（後續 task 依賴，簽名固定）:
  - `prom_duration_seconds DURATION` → stdout 秒數；接受 `N`/`Ns`/`Nm`/`Nh`/`Nd`/`Nw`（N ≥ 1）；其他（含 `0`、空字串）→ return 1。
  - `prom_auto_step WINDOW_SECONDS` → stdout `max(15, ceil(window/10000))`。
  - `prom_mask_url URL` → stdout；`scheme://user:pass@rest` → `scheme://user:***@rest`，無 credential 原樣返回。
  - `prom_require_cmds` → 全齊 return 0 無輸出；缺 `curl` 或 `python3` → stdout `<name> not found on this workstation`、return 1。

- [ ] **Step 1: 寫會紅的測試檔**

建立 `tests/test-prom-collector.sh`（`chmod +x`）：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/bundle.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/collect-prometheus.sh"

test_duration_parser() {
  [[ "$(prom_duration_seconds 90)" == "90" ]] || fail "90 -> 90"
  [[ "$(prom_duration_seconds 45s)" == "45" ]] || fail "45s -> 45"
  [[ "$(prom_duration_seconds 30m)" == "1800" ]] || fail "30m -> 1800"
  [[ "$(prom_duration_seconds 24h)" == "86400" ]] || fail "24h -> 86400"
  [[ "$(prom_duration_seconds 7d)" == "604800" ]] || fail "7d -> 604800"
  [[ "$(prom_duration_seconds 2w)" == "1209600" ]] || fail "2w -> 1209600"
  prom_duration_seconds yesterday >/dev/null 2>&1 && fail "'yesterday' should be rejected" || true
  prom_duration_seconds 5x >/dev/null 2>&1 && fail "'5x' should be rejected" || true
  prom_duration_seconds '' >/dev/null 2>&1 && fail "empty should be rejected" || true
  prom_duration_seconds 0 >/dev/null 2>&1 && fail "'0' should be rejected" || true
}

test_auto_step() {
  [[ "$(prom_auto_step 86400)" == "15" ]] || fail "24h window -> 15s floor"
  [[ "$(prom_auto_step 604800)" == "61" ]] || fail "7d window -> ceil(604800/10000)=61"
  [[ "$(prom_auto_step 60)" == "15" ]] || fail "tiny window -> 15s floor"
}

test_mask_url() {
  [[ "$(prom_mask_url 'http://u:sekrit@h:9090')" == 'http://u:***@h:9090' ]] || fail "credentials should be masked"
  [[ "$(prom_mask_url 'http://h:9090/sub')" == 'http://h:9090/sub' ]] || fail "no-credential URL should pass through"
}

test_require_cmds() {
  local onlycurl="$tmpdir/onlycurl" out
  mkdir -p "$onlycurl"
  printf '#!/bin/sh\nexit 0\n' >"$onlycurl/curl"
  chmod +x "$onlycurl/curl"
  # command -v is a builtin, so a bare restricted PATH is enough here.
  out="$(PATH="$onlycurl" prom_require_cmds 2>&1)" && fail "should fail when python3 is missing" || true
  [[ "$out" == *python3* ]] || fail "reason should name python3, got '$out'"
}

test_duration_parser
test_auto_step
test_mask_url
test_require_cmds

printf 'ok: prom collector\n'
```

- [ ] **Step 2: 執行測試，確認紅**

```bash
bash experiments/ceph-incident-bundle/tests/test-prom-collector.sh
```
預期：FAIL — `source .../lib/collect-prometheus.sh` 找不到檔案（exit 非 0）。

- [ ] **Step 3: 建立 lib/collect-prometheus.sh（只含本 task 的 helpers）**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Collect Prometheus metrics evidence (optional layer). Runs curl on the
# workstation against a user-supplied Prometheus base URL, dumping every
# metric of the matching scrape jobs over the --since window.

PROM_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$PROM_COLLECTOR_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: collect-prometheus.sh --out DIR --manifest PATH --url URL
       [--job-regex RE] [--step SECONDS] [--since DURATION]
       [--timeout SECONDS] [--budget SECONDS]
EOF
}

# Parse a --since style duration into seconds: N (seconds) or N{s,m,h,d,w}.
# Rejects 0 and anything non-matching.
prom_duration_seconds() {
  local value=$1 n unit
  local re='^([0-9]+)([smhdw]?)$'
  [[ $value =~ $re ]] || return 1
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  [[ "$n" -gt 0 ]] || return 1
  case "$unit" in
    ''|s) : ;;
    m) n=$((n * 60)) ;;
    h) n=$((n * 3600)) ;;
    d) n=$((n * 86400)) ;;
    w) n=$((n * 604800)) ;;
  esac
  printf '%s' "$n"
}

# Auto query_range step: smallest step >= 15s that keeps points per series
# under Prometheus's 11,000-point query_range limit (ceil(window/10000)).
prom_auto_step() {
  local window=$1 step
  step=$(((window + 9999) / 10000))
  [[ $step -ge 15 ]] || step=15
  printf '%s' "$step"
}

# Mask embedded basic-auth credentials in a URL before it lands in artifacts.
prom_mask_url() {
  local url=$1
  local re='^([A-Za-z][A-Za-z0-9+.-]*://)([^/@]+)@(.*)$'
  if [[ $url =~ $re ]]; then
    local cred=${BASH_REMATCH[2]}
    printf '%s%s:***@%s' "${BASH_REMATCH[1]}" "${cred%%:*}" "${BASH_REMATCH[3]}"
  else
    printf '%s' "$url"
  fi
}

# Workstation dependencies for this layer. Prints the missing dependency
# (used verbatim as the SKIPPED reason) and returns 1.
prom_require_cmds() {
  local c
  for c in curl python3; do
    if ! command -v "$c" >/dev/null 2>&1; then
      printf '%s not found on this workstation' "$c"
      return 1
    fi
  done
}
```

- [ ] **Step 4: 執行測試，確認綠**

```bash
bash experiments/ceph-incident-bundle/tests/test-prom-collector.sh
```
預期：`ok: prom collector`、exit 0。

- [ ] **Step 5: 註冊進 run-tests.sh**

`tests/run-tests.sh` 兩處修改。

檔案清單（第 18-31 行的 for 迴圈）：在 `"$ROOT/lib/verify-bundle.sh" \` 之前加：

```bash
  "$ROOT/lib/collect-prometheus.sh" \
```

在 `"$ROOT/tests/test-rook-collector.sh" \` 之後（`test-verify-bundle.sh` 前）加：

```bash
  "$ROOT/tests/test-prom-collector.sh" \
```

執行區塊：在 `rook_collector_args` 區塊之後、`collect_args` 區塊之前插入：

```bash
prom_collector_args="$(run_and_capture "$ROOT/tests/test-prom-collector.sh")"
prom_collector_status="${prom_collector_args%%$'\n'*}"
prom_collector_output="${prom_collector_args#*$'\n'}"
[[ "$prom_collector_status" == "0" ]] || fail "test-prom-collector.sh failed: $prom_collector_output"
```

- [ ] **Step 6: 三 gate + commit**

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
shellcheck experiments/ceph-incident-bundle/lib/*.sh experiments/ceph-incident-bundle/run/*.sh experiments/ceph-incident-bundle/tests/*.sh
make validate
```
預期：`ok: required files exist`、shellcheck 無輸出 exit 0、validate All checks passed。

```bash
git add experiments/ceph-incident-bundle/lib/collect-prometheus.sh \
  experiments/ceph-incident-bundle/tests/test-prom-collector.sh \
  experiments/ceph-incident-bundle/tests/run-tests.sh
git commit --no-gpg-sign -m "ceph-incident-bundle: prom dump helpers (duration/step/mask/deps)"
```
（commit 訊息尾端照 Global Constraints 加 footer，下同。）

---

### Task 2: fake curl fixture + `collect_prometheus` 完整行為（happy path 與所有失敗模式）

**Files:**
- Create: `experiments/ceph-incident-bundle/tests/fixtures/bin/curl`
- Modify: `experiments/ceph-incident-bundle/lib/collect-prometheus.sh`（追加主函式）
- Modify: `experiments/ceph-incident-bundle/tests/test-prom-collector.sh`（追加測試）

**Interfaces:**
- Consumes: Task 1 全部 helpers；common.sh 的 `ensure_dir`/`write_skip_artifact`/`manifest_add`/`progress`/`ssh_debug_safe_name`。
- Produces:
  - `collect_prometheus --out DIR --manifest PATH --url URL [--job-regex RE] [--step SECONDS|''] [--since DURATION] [--timeout SECONDS] [--budget SECONDS]` → return 0 全收成功；2 skip/partial；1 usage error 或 `--since` 不可解析。`--step` 傳空字串 = 自動計算（Task 4 的 collect.sh 靠這點無條件傳 `--step "$prom_step"`）。
  - artifacts：`DIR/cluster/prometheus/{dump-info.txt,buildinfo.json,targets.json,<job>/index.txt,<job>/<metric>.json.gz}`；`DIR/environment.txt` 追加 `prom_url=`/`prom_jobs=`；錯誤寫 `DIR/errors.log`。
  - `index.txt` 列型：`ok <metric> <file>.gz`、`failed <metric> -`、`TRUNCATED: budget <N>s exceeded`、`FAILED: metric listing for job <job>`。
  - fake curl 的環境 knobs：`FAKE_CURL_LOG`（必填）、`FAKE_CURL_DOWN=1`、`FAKE_CURL_FAIL_METRICS="m1 m2"`、`FAKE_CURL_JOBS_JSON='<body>'`。

- [ ] **Step 1: 建 fake curl fixture**

建立 `tests/fixtures/bin/curl`（`chmod +x`）：

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fake curl for tests. Emulates exactly the argv shape prom_curl produces:
#   curl -fsS -G --connect-timeout T --max-time T -o OUT URL [--data-urlencode P]...
# Knobs (env):
#   FAKE_CURL_LOG           append each invocation's argv here (required)
#   FAKE_CURL_DOWN=1        every request fails as a connect error (exit 7)
#   FAKE_CURL_FAIL_METRICS  space-separated metrics whose query_range 500s
#   FAKE_CURL_JOBS_JSON     override the /label/job/values response body

printf '%s\n' "$*" >>"${FAKE_CURL_LOG:?}"

out=''
url=''
params=()
args=("$@")
n=${#args[@]}
j=0
while [[ $j -lt $n ]]; do
  case "${args[$j]}" in
    -o) out="${args[$((j + 1))]}"; j=$((j + 2)) ;;
    --data-urlencode) params+=("${args[$((j + 1))]}"); j=$((j + 2)) ;;
    --connect-timeout|--max-time) j=$((j + 2)) ;;
    -*) j=$((j + 1)) ;;
    *) url="${args[$j]}"; j=$((j + 1)) ;;
  esac
done

if [[ "${FAKE_CURL_DOWN:-}" == "1" ]]; then
  printf 'curl: (7) Failed to connect to prometheus\n' >&2
  exit 7
fi

param_for() {
  local key=$1 p
  for p in "${params[@]+"${params[@]}"}"; do
    case "$p" in "$key="*) printf '%s' "${p#"$key"=}" ;; esac
  done
}

case "$url" in
  */api/v1/status/buildinfo)
    printf '{"status":"success","data":{"version":"2.51.0","revision":"fake"}}' >"$out"
    ;;
  */api/v1/targets)
    printf '{"status":"success","data":{"activeTargets":[{"labels":{"job":"ceph"}}]}}' >"$out"
    ;;
  */api/v1/label/job/values)
    if [[ -n "${FAKE_CURL_JOBS_JSON:-}" ]]; then
      printf '%s' "$FAKE_CURL_JOBS_JSON" >"$out"
    else
      printf '{"status":"success","data":["ceph","node-exporter","grafana"]}' >"$out"
    fi
    ;;
  */api/v1/label/__name__/values)
    m="$(param_for 'match[]')"
    case "$m" in
      *'job="ceph"'*) printf '{"status":"success","data":["ceph_health_status","ceph_osd_up"]}' >"$out" ;;
      *'job="node-exporter"'*) printf '{"status":"success","data":["node_load1"]}' >"$out" ;;
      *) printf '{"status":"success","data":[]}' >"$out" ;;
    esac
    ;;
  */api/v1/query_range)
    q="$(param_for query)"
    metric="${q#*__name__=\"}"
    metric="${metric%%\"*}"
    for fm in ${FAKE_CURL_FAIL_METRICS:-}; do
      if [[ "$metric" == "$fm" ]]; then
        printf 'curl: (22) The requested URL returned error: 500\n' >&2
        exit 22
      fi
    done
    start="$(param_for start)"
    printf '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"__name__":"%s"},"values":[[%s,"1"]]}]}}' \
      "$metric" "${start:-0}" >"$out"
    ;;
  *)
    printf 'fake curl: unexpected url %s\n' "$url" >&2
    exit 99
    ;;
esac
```

- [ ] **Step 2: 追加會紅的測試**

`tests/test-prom-collector.sh`：在三行 `source` 之後加共用設定；在 `test_require_cmds` 定義之後追加測試函式；呼叫區在 `test_require_cmds` 呼叫行之後追加呼叫。

共用設定：

```bash
fakebin="$tmpdir/fakebin"
mkdir -p "$fakebin"
cp "$ROOT/tests/fixtures/bin/curl" "$fakebin/curl"
export FAKE_CURL_LOG="$tmpdir/curl.log"

# Invoke collect_prometheus against a fresh fake workdir. Runs in a subshell
# so the PATH override and knob exports never leak between test cases.
run_prom() {
  local wd=$1
  shift
  mkdir -p "$wd"
  : >"$wd/manifest.jsonl"
  : >"$wd/errors.log"
  : >"$wd/environment.txt"
  (
    PATH="$fakebin:$PATH"
    collect_prometheus --out "$wd" --manifest "$wd/manifest.jsonl" \
      --url http://prom.example:9090 "$@"
  )
}
```

測試函式：

```bash
test_happy_path() {
  local wd="$tmpdir/wd-happy" p s e rows
  : >"$FAKE_CURL_LOG"
  run_prom "$wd" --since 24h --timeout 5 || fail "happy path should return 0"
  p="$wd/cluster/prometheus"
  [[ -f "$p/buildinfo.json" ]] || fail "missing buildinfo.json"
  [[ -f "$p/targets.json" ]] || fail "missing targets.json"
  [[ -f "$p/dump-info.txt" ]] || fail "missing dump-info.txt"
  [[ -f "$p/ceph/index.txt" ]] || fail "missing ceph index.txt"
  [[ -f "$p/ceph/ceph_health_status.json.gz" ]] || fail "missing ceph_health_status dump"
  [[ -f "$p/ceph/ceph_osd_up.json.gz" ]] || fail "missing ceph_osd_up dump"
  [[ -f "$p/node-exporter/node_load1.json.gz" ]] || fail "missing node_load1 dump"
  [[ ! -d "$p/grafana" ]] || fail "grafana job must not be collected"
  gzip -dc "$p/ceph/ceph_health_status.json.gz" | grep -qF '"status":"success"' \
    || fail "metric dump is not a success response"
  grep -qF 'step=15' "$FAKE_CURL_LOG" || fail "24h window should query with step=15"
  grep -qF 'ok ceph_health_status ceph_health_status.json.gz' "$p/ceph/index.txt" \
    || fail "index missing ok row"
  s="$(sed -n 's/^window_start_epoch=//p' "$p/dump-info.txt")"
  e="$(sed -n 's/^window_end_epoch=//p' "$p/dump-info.txt")"
  [[ "$((e - s))" == "86400" ]] || fail "window should span 86400s, got $((e - s))"
  rows="$(grep -c '"collector":"collect-prometheus"' "$wd/manifest.jsonl")"
  [[ "$rows" == "4" ]] || fail "expected 4 manifest rows (buildinfo/targets/2 jobs), got $rows"
  grep -qF 'prom_url=http://prom.example:9090' "$wd/environment.txt" \
    || fail "environment.txt missing prom_url"
  grep -qF 'prom_jobs=ceph node-exporter' "$wd/environment.txt" \
    || fail "environment.txt missing prom_jobs"
}

test_unreachable() {
  local wd="$tmpdir/wd-down" rc=0
  ( export FAKE_CURL_DOWN=1; run_prom "$wd" --since 24h ) || rc=$?
  [[ "$rc" == "2" ]] || fail "unreachable prometheus should return 2, got $rc"
  grep -qF 'not reachable' "$wd/cluster/prometheus/SKIPPED.txt" || fail "SKIPPED should say not reachable"
  grep -qF 'prometheus' "$wd/errors.log" || fail "errors.log should record the skip"
}

test_no_matching_jobs() {
  local wd="$tmpdir/wd-nojobs" rc=0
  run_prom "$wd" --since 24h --job-regex 'zzz' || rc=$?
  [[ "$rc" == "2" ]] || fail "no matching jobs should return 2, got $rc"
  grep -qF 'no scrape job matched' "$wd/cluster/prometheus/SKIPPED.txt" || fail "SKIPPED reason wrong"
  grep -qF 'grafana' "$wd/cluster/prometheus/SKIPPED.txt" || fail "SKIPPED should list the jobs seen"
}

test_missing_python3() {
  # Restricted PATH that still provides what the pre-check code path needs
  # (mkdir/date/dirname for prom_skip + errors.log), but no python3.
  local wd="$tmpdir/wd-nopy" bin="$tmpdir/nopybin" rc=0 c
  mkdir -p "$bin" "$wd"
  : >"$wd/manifest.jsonl"
  : >"$wd/errors.log"
  printf '#!/bin/sh\nexit 0\n' >"$bin/curl"
  chmod +x "$bin/curl"
  for c in mkdir date dirname; do
    ln -s "$(command -v "$c")" "$bin/$c"
  done
  ( PATH="$bin"
    collect_prometheus --out "$wd" --manifest "$wd/manifest.jsonl" \
      --url http://prom.example:9090 --since 24h ) || rc=$?
  [[ "$rc" == "2" ]] || fail "missing python3 should return 2, got $rc"
  grep -qF 'python3 not found' "$wd/cluster/prometheus/SKIPPED.txt" || fail "SKIPPED should name python3"
}

test_single_metric_failure() {
  local wd="$tmpdir/wd-onefail" rc=0 p
  ( export FAKE_CURL_FAIL_METRICS='ceph_osd_up'; run_prom "$wd" --since 24h ) || rc=$?
  [[ "$rc" == "2" ]] || fail "metric failure should return 2, got $rc"
  p="$wd/cluster/prometheus"
  [[ -f "$p/ceph/ceph_health_status.json.gz" ]] || fail "other metrics should still be dumped"
  [[ ! -f "$p/ceph/ceph_osd_up.json.gz" ]] || fail "failed metric must not leave a dump"
  grep -qF 'failed ceph_osd_up' "$p/ceph/index.txt" || fail "index should mark the failure"
  grep -qF 'ceph_osd_up' "$wd/errors.log" || fail "errors.log should record the metric failure"
}

test_budget_truncation() {
  local wd="$tmpdir/wd-budget" rc=0
  run_prom "$wd" --since 24h --budget 0 || rc=$?
  [[ "$rc" == "2" ]] || fail "budget truncation should return 2, got $rc"
  grep -qF 'TRUNCATED' "$wd/cluster/prometheus/ceph/index.txt" || fail "index should mark TRUNCATED"
  grep -qF 'truncated=1' "$wd/cluster/prometheus/dump-info.txt" || fail "dump-info should mark truncated"
  grep -qF 'truncated' "$wd/errors.log" || fail "errors.log should record the truncation"
}

test_unsafe_job_name() {
  local wd="$tmpdir/wd-badjob" rc=0
  ( export FAKE_CURL_JOBS_JSON='{"status":"success","data":["ceph","node\"x"]}'
    run_prom "$wd" --since 24h ) || rc=$?
  [[ "$rc" == "2" ]] || fail "unsafe job name should be partial (2), got $rc"
  grep -qF 'unsafe name' "$wd/errors.log" || fail "errors.log should record the unsafe job"
  [[ -f "$wd/cluster/prometheus/ceph/index.txt" ]] || fail "safe job should still be collected"
}

test_long_window_step() {
  local wd="$tmpdir/wd-7d"
  : >"$FAKE_CURL_LOG"
  run_prom "$wd" --since 7d || fail "7d dump should succeed"
  grep -qF 'step=61' "$FAKE_CURL_LOG" || fail "7d window should query with step=61"
}
```

呼叫區追加：

```bash
test_happy_path
test_unreachable
test_no_matching_jobs
test_missing_python3
test_single_metric_failure
test_budget_truncation
test_unsafe_job_name
test_long_window_step
```

- [ ] **Step 3: 執行測試，確認紅**

```bash
bash experiments/ceph-incident-bundle/tests/test-prom-collector.sh
```
預期：FAIL — `collect_prometheus: command not found`（全部新測試同一原因紅）。

- [ ] **Step 4: 實作 collect_prometheus**

`lib/collect-prometheus.sh` 檔尾追加：

```bash
# Epoch -> UTC ISO timestamp. BSD date takes -r EPOCH; GNU date's -r means
# file-mtime (fails on a bare number) so it falls through to -d @EPOCH.
prom_epoch_utc() {
  date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ
}

# GET BASE+PATH into OUTFILE. Extra args become --data-urlencode params (so
# PromQL matchers never need manual URL-encoding). Caller captures stderr.
prom_curl() {
  local base=$1 path=$2 outfile=$3 timeout=$4
  shift 4
  local -a cmd
  local p
  cmd=(curl -fsS -G --connect-timeout "$timeout" --max-time "$timeout" -o "$outfile" "$base$path")
  for p in "$@"; do
    cmd+=(--data-urlencode "$p")
  done
  "${cmd[@]}"
}

# Print each string in a Prometheus label-values response's data[] array,
# one per line. Fails if the file is not parseable status=success JSON.
prom_json_data_values() {
  local file=$1
  python3 - "$file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
if doc.get("status") != "success":
    sys.exit(1)
for value in doc.get("data", []):
    print(value)
PYEOF
}

prom_error() {
  local outdir=$1 message=$2
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$outdir/errors.log"
}

prom_skip() {
  local outdir=$1 reason=$2
  write_skip_artifact "$outdir/cluster/prometheus/SKIPPED.txt" "$reason"
  prom_error "$outdir" "prometheus dump skipped: $reason"
}

collect_prometheus() {
  local outdir='' manifest='' url='' job_regex='ceph|node' step='' since=24h timeout=20 budget=600

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) outdir=${2-}; shift 2 ;;
      --manifest) manifest=${2-}; shift 2 ;;
      --url) url=${2-}; shift 2 ;;
      --job-regex) job_regex=${2-}; shift 2 ;;
      --step) step=${2-}; shift 2 ;;
      --since) since=${2-}; shift 2 ;;
      --timeout) timeout=${2-}; shift 2 ;;
      --budget) budget=${2-}; shift 2 ;;
      --help|-h) usage; return 0 ;;
      *) usage >&2; return 1 ;;
    esac
  done
  [[ -n "$outdir" && -n "$manifest" && -n "$url" ]] || { usage >&2; return 1; }

  local promdir="$outdir/cluster/prometheus"
  local masked_url window start_epoch end_epoch deadline missing
  masked_url="$(prom_mask_url "$url")"

  if ! window="$(prom_duration_seconds "$since")"; then
    log "invalid --since for prometheus dump (want N/Ns/Nm/Nh/Nd/Nw): $since"
    return 1
  fi

  if ! missing="$(prom_require_cmds)"; then
    prom_skip "$outdir" "$missing"
    return 2
  fi

  ensure_dir "$promdir"
  end_epoch="$(date -u +%s)"
  start_epoch=$((end_epoch - window))
  [[ -n "$step" ]] || step="$(prom_auto_step "$window")"
  deadline=$((SECONDS + budget))

  # Raw JSON artifacts are written by curl -o directly — NOT via run_capture,
  # whose "# host:" header lines would corrupt the JSON — so each phase does
  # its own manifest_add.
  local started ended detail rc failed=0

  # buildinfo doubles as the connectivity probe.
  started="$(date -u +%FT%TZ)"
  detail="$(prom_curl "$url" /api/v1/status/buildinfo "$promdir/buildinfo.json" "$timeout" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$promdir/buildinfo.json"
    prom_skip "$outdir" "prometheus not reachable: $masked_url (curl exit $rc: $detail)"
    return 2
  fi
  ended="$(date -u +%FT%TZ)"
  manifest_add "$manifest" prometheus collect-prometheus "$promdir/buildinfo.json" \
    "GET $masked_url/api/v1/status/buildinfo" 0 "$started" "$ended"

  started="$(date -u +%FT%TZ)"
  detail="$(prom_curl "$url" /api/v1/targets "$promdir/targets.json" "$timeout" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    prom_error "$outdir" "prometheus targets fetch failed (curl exit $rc): $detail"
    failed=1
  fi
  ended="$(date -u +%FT%TZ)"
  manifest_add "$manifest" prometheus collect-prometheus "$promdir/targets.json" \
    "GET $masked_url/api/v1/targets" "$rc" "$started" "$ended"

  # Enumerate scrape jobs; the user-facing contract is "find metrics by
  # exporter (job) name", so filtering happens on job labels, not metric names.
  local jobs_file="$promdir/.jobs.json" job_list job
  local jobs_seen_str='' jobs_matched_str=''
  local -a jobs_matched
  jobs_matched=()
  detail="$(prom_curl "$url" /api/v1/label/job/values "$jobs_file" "$timeout" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 ]] || ! job_list="$(prom_json_data_values "$jobs_file")"; then
    rm -f -- "$jobs_file"
    prom_skip "$outdir" "prometheus job listing failed (curl exit $rc): ${detail:-unparseable JSON}"
    return 2
  fi
  rm -f -- "$jobs_file"
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    jobs_seen_str="${jobs_seen_str:+$jobs_seen_str }$job"
    if printf '%s' "$job" | grep -qiE "$job_regex"; then
      case "$job" in
        *'"'*|*'\'*)
          # cannot be interpolated into a PromQL matcher safely
          prom_error "$outdir" "prometheus job skipped (unsafe name): $job"
          failed=1
          ;;
        *)
          jobs_matched+=("$job")
          jobs_matched_str="${jobs_matched_str:+$jobs_matched_str }$job"
          ;;
      esac
    fi
  done <<<"$job_list"

  if [[ ${#jobs_matched[@]} -eq 0 ]]; then
    prom_skip "$outdir" "no scrape job matched regex '$job_regex' (jobs seen: ${jobs_seen_str:-<none>})"
    return 2
  fi

  local truncated=0 metrics_ok=0 metrics_failed=0
  local metric_re='^[a-zA-Z_:][a-zA-Z0-9_:]*$'
  local safe_job jobdir index names_file name_list metric file job_rc n_metrics
  for job in "${jobs_matched[@]+"${jobs_matched[@]}"}"; do
    if [[ $truncated -eq 1 ]]; then
      break
    fi
    safe_job="$(ssh_debug_safe_name "$job")"
    jobdir="$promdir/$safe_job"
    ensure_dir "$jobdir"
    index="$jobdir/index.txt"
    : >"$index"
    job_rc=0
    started="$(date -u +%FT%TZ)"

    names_file="$jobdir/.names.json"
    detail="$(prom_curl "$url" /api/v1/label/__name__/values "$names_file" "$timeout" \
      "match[]={job=\"$job\"}" "start=$start_epoch" "end=$end_epoch" 2>&1)" && rc=0 || rc=$?
    if [[ $rc -ne 0 ]] || ! name_list="$(prom_json_data_values "$names_file")"; then
      rm -f -- "$names_file"
      printf 'FAILED: metric listing for job %s\n' "$job" >>"$index"
      prom_error "$outdir" "prometheus metric listing failed for job $job (curl exit $rc): ${detail:-unparseable JSON}"
      failed=1
      ended="$(date -u +%FT%TZ)"
      manifest_add "$manifest" prometheus collect-prometheus "$index" \
        "GET $masked_url/api/v1/label/__name__/values match[]={job=\"$job\"}" 2 "$started" "$ended"
      continue
    fi
    rm -f -- "$names_file"

    n_metrics="$(printf '%s\n' "$name_list" | grep -c . || true)"
    progress "prometheus: job $job — $n_metrics metrics, step ${step}s…"

    while IFS= read -r metric; do
      [[ -n "$metric" ]] || continue
      if [[ $SECONDS -ge $deadline ]]; then
        truncated=1
        printf 'TRUNCATED: budget %ss exceeded\n' "$budget" >>"$index"
        prom_error "$outdir" "prometheus dump truncated: budget ${budget}s exceeded at job $job"
        job_rc=2
        failed=1
        break
      fi
      if ! [[ $metric =~ $metric_re ]]; then
        printf 'skipped %s unsafe-name\n' "$metric" >>"$index"
        prom_error "$outdir" "prometheus metric skipped (unsafe name) job=$job metric=$metric"
        job_rc=2
        failed=1
        continue
      fi
      file="${metric//:/__}.json"
      detail="$(prom_curl "$url" /api/v1/query_range "$jobdir/$file" "$timeout" \
        "query={__name__=\"$metric\",job=\"$job\"}" \
        "start=$start_epoch" "end=$end_epoch" "step=$step" 2>&1)" && rc=0 || rc=$?
      if [[ $rc -ne 0 ]] || ! head -c 512 "$jobdir/$file" 2>/dev/null | grep -qF '"status":"success"'; then
        rm -f -- "$jobdir/$file"
        printf 'failed %s -\n' "$metric" >>"$index"
        prom_error "$outdir" "prometheus query_range failed job=$job metric=$metric (curl exit $rc): $detail"
        metrics_failed=$((metrics_failed + 1))
        job_rc=2
        failed=1
        continue
      fi
      gzip -f -- "$jobdir/$file"
      printf 'ok %s %s.gz\n' "$metric" "$file" >>"$index"
      metrics_ok=$((metrics_ok + 1))
    done <<<"$name_list"

    ended="$(date -u +%FT%TZ)"
    manifest_add "$manifest" prometheus collect-prometheus "$index" \
      "GET $masked_url/api/v1/query_range query={__name__=\"<metric>\",job=\"$job\"} start=$start_epoch end=$end_epoch step=$step ($n_metrics metrics)" \
      "$job_rc" "$started" "$ended"
  done

  {
    printf 'url=%s\n' "$masked_url"
    printf 'since=%s\n' "$since"
    printf 'window_start_epoch=%s\n' "$start_epoch"
    printf 'window_start_utc=%s\n' "$(prom_epoch_utc "$start_epoch")"
    printf 'window_end_epoch=%s\n' "$end_epoch"
    printf 'window_end_utc=%s\n' "$(prom_epoch_utc "$end_epoch")"
    printf 'step_seconds=%s\n' "$step"
    printf 'job_regex=%s\n' "$job_regex"
    printf 'jobs_seen=%s\n' "${jobs_seen_str:-<none>}"
    printf 'jobs_matched=%s\n' "${jobs_matched_str:-<none>}"
    printf 'metrics_ok=%s\n' "$metrics_ok"
    printf 'metrics_failed=%s\n' "$metrics_failed"
    printf 'truncated=%s\n' "$truncated"
  } >"$promdir/dump-info.txt"

  {
    printf 'prom_url=%s\n' "$masked_url"
    printf 'prom_jobs=%s\n' "${jobs_matched_str:-<none>}"
  } >>"$outdir/environment.txt"

  [[ $failed -eq 0 ]] || return 2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  collect_prometheus "$@"
fi
```

- [ ] **Step 5: 執行測試，確認綠**

```bash
bash experiments/ceph-incident-bundle/tests/test-prom-collector.sh
```
預期：`ok: prom collector`、exit 0。

- [ ] **Step 6: 三 gate + commit**

同 Task 1 Step 6 的三個指令，全綠後：

```bash
git add experiments/ceph-incident-bundle/lib/collect-prometheus.sh \
  experiments/ceph-incident-bundle/tests/test-prom-collector.sh \
  experiments/ceph-incident-bundle/tests/fixtures/bin/curl
git commit --no-gpg-sign -m "ceph-incident-bundle: collect_prometheus with full failure-mode coverage"
```

---

### Task 3: metric dump 排除在 redaction 之外

**Files:**
- Modify: `experiments/ceph-incident-bundle/lib/bundle.sh`（`redact_bundle_text` 的 find，約 164-175 行）
- Modify: `experiments/ceph-incident-bundle/tests/test-prom-collector.sh`（追加 1 個測試）

**Interfaces:**
- Consumes: `lib/bundle.sh` 的 `redact_bundle_text`（測試檔已在 Task 1 source）。
- Produces: `cluster/prometheus/<job>/*.json.gz` 不被 redact；`cluster/prometheus/` 其餘檔案照常 redact。

- [ ] **Step 1: 追加會紅的測試**

`tests/test-prom-collector.sh` 追加測試函式與呼叫（呼叫加在 `test_long_window_step` 之後）：

```bash
test_redaction_excludes_metric_dumps() {
  local wd="$tmpdir/wd-redact"
  local pdir="$wd/cluster/prometheus/ceph"
  mkdir -p "$pdir" "$wd/nodes"
  # this line WOULD be redacted (key = base64-ish) if the redactor visited it
  printf 'key = AQBSOMETHINGLONGENOUGHTOTRIGGERBASE64REDACTIONXX==\n' | gzip -c >"$pdir/ceph_fake.json.gz"
  printf 'password = hunter2\n' >"$wd/cluster/prometheus/dump-info.txt"
  redact_bundle_text "$wd"
  gzip -dc "$pdir/ceph_fake.json.gz" | grep -qF 'AQBSOMETHING' \
    || fail "per-metric dump must NOT be redacted"
  grep -qF '[REDACTED]' "$wd/cluster/prometheus/dump-info.txt" \
    || fail "dump-info.txt must still be redacted"
}
```

- [ ] **Step 2: 執行測試，確認紅**

```bash
bash experiments/ceph-incident-bundle/tests/test-prom-collector.sh
```
預期：`FAIL: per-metric dump must NOT be redacted`。

- [ ] **Step 3: 修改 redact_bundle_text**

`lib/bundle.sh` 的 `redact_bundle_text`，`while` 迴圈本體不變，換掉註解與 find：

```bash
  # Per-metric Prometheus dumps (cluster/prometheus/<job>/*.json.gz) are
  # numeric time series in single multi-MB JSON lines: line-based redaction is
  # pathologically slow there and one regex false-positive would blank the
  # whole file. They are excluded; dump-info/index/buildinfo/targets in
  # cluster/prometheus/ still go through redaction like everything else.
  while IFS= read -r path; do
    case "$path" in
      *.gz) redact_gz_file "$path" "$redaction_log" ;;
      *) redact_file "$path" "$redaction_log" ;;
    esac
  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \
    -not -path '*/cluster/prometheus/*/*.json.gz' \
    \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
```

- [ ] **Step 4: 執行測試，確認綠**

```bash
bash experiments/ceph-incident-bundle/tests/test-prom-collector.sh
```
預期：`ok: prom collector`。

- [ ] **Step 5: 三 gate + commit**

```bash
git add experiments/ceph-incident-bundle/lib/bundle.sh \
  experiments/ceph-incident-bundle/tests/test-prom-collector.sh
git commit --no-gpg-sign -m "ceph-incident-bundle: exclude per-metric prom dumps from redaction"
```

---

### Task 4: collect.sh 整合（旗標、驗證、呼叫、e2e）

**Files:**
- Modify: `experiments/ceph-incident-bundle/run/collect.sh`（source、usage、parse、驗證、呼叫）
- Modify: `experiments/ceph-incident-bundle/tests/test-collect.sh`（help 斷言、arg 驗證、e2e、無旗標回歸）

**Interfaces:**
- Consumes: `collect_prometheus`（Task 2 簽名）、`prom_duration_seconds`、`prom_mask_url`、fake curl fixture。
- Produces: `collect.sh` 新旗標 `--prom-url URL`、`--prom-job-regex RE`（預設 `ceph|node`）、`--prom-step SECONDS`（預設空 = 自動）、`--prom-timeout SECONDS`（預設 600）。

- [ ] **Step 1: 追加會紅的測試**

`tests/test-collect.sh` 修改四處：

(1) help 斷言區（`--no-redact` 斷言後）加：

```bash
[[ "$help_output" == *"--prom-url"* ]] || fail "help should document --prom-url"
```

(2) 現有 auto case 的 CONTENTS 斷言之後加無旗標回歸：

```bash
# no --prom-url: the bundle must not contain any prometheus layer at all
tar -tzf "$bundle_auto" | grep -q 'cluster/prometheus' && fail "prometheus dir must not exist without --prom-url" || true
```

(3) `--kube-mode bogus` 測試區塊之後加參數驗證案例：

```bash
# --prom-url with an unparseable --since is rejected up front (exit 1)
prom_bad_since="$(run_and_capture "$ROOT/run/collect.sh" --prom-url http://prom.example:9090 --since yesterday --inventory "$inventory" --ssh-key "$ssh_key")"
prom_bad_since_status="${prom_bad_since%%$'\n'*}"
prom_bad_since_out="${prom_bad_since#*$'\n'}"
[[ "$prom_bad_since_status" == "1" ]] || fail "--prom-url with bad --since should exit 1, got $prom_bad_since_status"
[[ "$prom_bad_since_out" == *"--since must be"* ]] || fail "bad since should explain the failure"

prom_bad_timeout="$(run_and_capture "$ROOT/run/collect.sh" --prom-url http://prom.example:9090 --prom-timeout abc --inventory "$inventory" --ssh-key "$ssh_key")"
prom_bad_timeout_status="${prom_bad_timeout%%$'\n'*}"
[[ "$prom_bad_timeout_status" == "1" ]] || fail "non-numeric --prom-timeout should exit 1, got $prom_bad_timeout_status"
```

(4) 同一位置接著加 e2e（cephadm seed 情境 + fake curl）：

```bash
# ---------------------------------------------------------------------------
# --prom-url: metrics dump lands inside the bundle; only matching jobs dumped
# ---------------------------------------------------------------------------
cp "$ROOT/tests/fixtures/bin/curl" "$fakebin/curl"
export FAKE_CURL_LOG="$tmpdir/curl.log"
out_prom="$tmpdir/out-prom"
: >"$FAKE_CURL_LOG"
FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="" \
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --seed tester@10.0.0.1 --mode cephadm --out "$out_prom" --since 24h --timeout 5 \
  --prom-url http://prom.example:9090
bundle_prom="$(find_bundle "$out_prom")"
assert_archive_contains "$bundle_prom" "cluster/prometheus/dump-info.txt"
assert_archive_contains "$bundle_prom" "cluster/prometheus/buildinfo.json"
assert_archive_contains "$bundle_prom" "cluster/prometheus/ceph/ceph_health_status.json.gz"
assert_archive_contains "$bundle_prom" "cluster/prometheus/node-exporter/node_load1.json.gz"
tar -tzf "$bundle_prom" | grep -q 'cluster/prometheus/grafana/' && fail "non-matching job must not be dumped" || true
assert_archive_file_contains "$bundle_prom" "environment.txt" "prom_url=http://prom.example:9090"
grep -qF 'step=15' "$FAKE_CURL_LOG" || fail "24h window should query with step=15"
```

（e2e 直接跑在 `set -e` 下，collect.sh exit 非 0 會讓測試檔整個失敗 — 這就是 happy path 的 exit 0 斷言；同時整包有過 verify 才會有 bundle 檔，涵蓋 spec 測試 11 的 verify PASS。）

- [ ] **Step 2: 執行測試，確認紅**

```bash
bash experiments/ceph-incident-bundle/tests/test-collect.sh
```
預期：`FAIL: help should document --prom-url`。

- [ ] **Step 3: 實作 collect.sh 整合**

六處修改：

(1) source 區（`source "$COLLECT_ROOT/lib/collect-cluster-rook.sh"` 之後）加：

```bash
# shellcheck disable=SC1091
source "$COLLECT_ROOT/lib/collect-prometheus.sh"
```

(2) usage() 的 Options 段，`--since DURATION` 那行之後加：

```
  --prom-url URL         optional Prometheus base URL; dump metrics of scrape
                         jobs matching --prom-job-regex over the --since window
  --prom-job-regex RE    scrape-job filter for the dump (default: ceph|node)
  --prom-step SECONDS    query_range step (default: max(15, window/10000))
  --prom-timeout SECONDS overall time budget for the metrics dump (default: 600)
```

(3) main() 的 locals（`local trust_ssh_host_key=1 redact_enabled=1` 那行之後）加：

```bash
  local prom_url='' prom_job_regex='ceph|node' prom_step='' prom_timeout=600
```

(4) 參數 parse 迴圈，`--since` 分支之後加四個分支（沿用既有多行風格）：

```bash
      --prom-url)
        prom_url=${2-}
        shift 2
        ;;
      --prom-job-regex)
        prom_job_regex=${2-}
        shift 2
        ;;
      --prom-step)
        prom_step=${2-}
        shift 2
        ;;
      --prom-timeout)
        prom_timeout=${2-}
        shift 2
        ;;
```

(5) 驗證區（`[[ "$kube_mode" == ... ]] || die ...` 之後、inventory 檢查之前）加：

```bash
  if [[ -n "$prom_url" ]]; then
    local num_re='^[0-9]+$'
    prom_duration_seconds "$since" >/dev/null \
      || die "--since must be N/Ns/Nm/Nh/Nd/Nw when using --prom-url: $since"
    [[ -z "$prom_step" || "$prom_step" =~ $num_re ]] || die "invalid --prom-step (seconds): $prom_step"
    [[ "$prom_timeout" =~ $num_re ]] || die "invalid --prom-timeout (seconds): $prom_timeout"
  fi
```

(6) 呼叫點：`collect_clusters` 的 `if [[ $cluster_rc -ne 0 ]] ... fi` 區塊之後、`local i alias target node_rc ntotal` 之前加：

```bash
  local prom_rc=0
  if [[ -n "$prom_url" ]]; then
    progress "collecting prometheus metrics from $(prom_mask_url "$prom_url")…"
    set +e
    collect_prometheus --out "$workdir" --manifest "$manifest" --url "$prom_url" \
      --job-regex "$prom_job_regex" --step "$prom_step" --since "$since" \
      --timeout "$timeout" --budget "$prom_timeout"
    prom_rc=$?
    set -e
    if [[ $prom_rc -ne 0 ]]; then
      append_error "$workdir" "prometheus collection exited $prom_rc"
      rc=2
    fi
  fi
```

- [ ] **Step 4: 執行測試，確認綠**

```bash
bash experiments/ceph-incident-bundle/tests/test-collect.sh
```
預期：`ok: collect orchestration`。

- [ ] **Step 5: 三 gate + commit**

```bash
git add experiments/ceph-incident-bundle/run/collect.sh \
  experiments/ceph-incident-bundle/tests/test-collect.sh
git commit --no-gpg-sign -m "ceph-incident-bundle: wire --prom-url metrics dump into collect.sh"
```

---

### Task 5: README 文件 + 最終全綠確認

**Files:**
- Modify: `experiments/ceph-incident-bundle/README.md`

**Interfaces:**
- Consumes: 前四個 task 的最終行為。
- Produces: 使用者文件；無程式碼變更。

- [ ] **Step 1: README 加新章節**

在「## 只收單層（覆寫）」章節之後插入下列內容（`[bash]` 圍籬佔位符寫入時換成一般三反引號 code fence）：

```text
## Prometheus metrics dump（選用）

給 `--prom-url` 時，會在收 cluster 證據後，從該 Prometheus 把「執行當下往回
`--since`」窗內、job 名稱符合 `ceph|node`（`--prom-job-regex` 可覆寫）的每個
metric 各打一次 `query_range`，原始 JSON 逐一 gzip 存進
`cluster/prometheus/<job>/<metric>.json.gz`。不給 `--prom-url` 則完全不碰
Prometheus。

[bash]
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  --ssh-key .ssh/id_ed25519 --mode cephadm --since 24h \
  --prom-url http://192.168.18.166:9095
[/bash]

- 前置：工作機要有 `curl` 與 `python3`，且 URL 從工作機直接可達（不走 ssh
  tunnel）。缺任一 → `cluster/prometheus/SKIPPED.txt` + exit 2。
- step 預設 `max(15, ceil(window/10000))` 秒（避開 Prometheus 每 series 11,000
  點上限；`--prom-step` 可覆寫）。整段 dump 的時間預算 `--prom-timeout`（預設
  600s），超時會截斷並在 `dump-info.txt`／`index.txt` 標 `TRUNCATED`。
- exit code 語意不變：dump 失敗／截斷 → exit 2（partial），bundle 照樣產出。
- 安全界線：`<job>/<metric>.json.gz` 是數值 time series，**不做** redaction
  （單行大 JSON 逐行 redact 極慢，且 regex 誤中會讓整檔變 `[REDACTED]`）；
  `dump-info.txt`、`index.txt`、`buildinfo.json`、`targets.json` 照常 redact。
  URL 內嵌的 `user:pass@` 寫進任何 artifact 前會遮蔽為 `user:***@`。
- 尚未對真 Prometheus 驗證（lab 機器備妥後補跑）；目前行為以測試 + Prometheus
  HTTP API 官方文件交叉驗證。
```

「## bundle 內有什麼」章節的清單加一行：

```markdown
- `cluster/prometheus/` — 選用的 metrics dump（有給 `--prom-url` 才存在）
```

- [ ] **Step 2: 最終三 gate**

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
shellcheck experiments/ceph-incident-bundle/lib/*.sh experiments/ceph-incident-bundle/run/*.sh experiments/ceph-incident-bundle/tests/*.sh
make validate
```
預期：全綠。

- [ ] **Step 3: commit**

```bash
git add experiments/ceph-incident-bundle/README.md
git commit --no-gpg-sign -m "ceph-incident-bundle: document --prom-url metrics dump"
```

---

## 完成後（不在本 plan 內執行）

- 真機驗證 deferred：使用者備妥開著 Prometheus 的 lab 後，實跑 `--prom-url`，確認 dump 大小／耗時／與 Grafana 對照一致（spec「真機驗證」節）。
- push 需使用者同意；push 指令見 CLAUDE.md（repo 內 key + `GIT_SSH_COMMAND`）。
