# Ceph Alert Production Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `prometheus-alert-design` 的 alert 層擴充到工廠級 0-downtime 覆蓋（+18 條 rule、routing v2、inhibit），並讓**每一條 rule 都有真機故障注入的 firing 證據**。

**Architecture:** 三份 rules 拷貝（MDX 頁面 = SoT、`ceph-alert-rules/rules/` = promtool 被測物、real-lab render = 部署物）中，把 real-lab render 改為**直接讀取 `ceph-alert-rules/rules/*.yml`**，消掉第三份拷貝。新增 `scenario-framework.sh` 收斂場景樣板，16 個新場景腳本每個只寫 inject/rollback/verify。真機執行由 orchestrator session 直接控制（不交給背景 subagent）。

**Tech Stack:** bash 3.2 相容 shell、promtool、kubectl（`~/.kube/ceph-lab-k8s.kubeconfig`）、cephadm shell、Prometheus v3.2.1 / Alertmanager v0.28.1（lab in k0s）。

## Global Constraints

- 每次 commit 前：`bash experiments/ceph-alert-real-lab/tests/run-tests.sh` + `shellcheck -x experiments/ceph-alert-real-lab/{lib,run,tests}/*.sh` + `make validate` 全綠（涉及 ceph-alert-rules 時再加 `bash experiments/ceph-alert-rules/run/tierA.sh` 與該 experiment 的 shellcheck）。
- commit 用 `git commit --no-gpg-sign`；push 用 `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push`。
- bash 3.2：無 `mapfile`；`set -u` 下空陣列用 `"${arr[@]+"${arr[@]}"}"`；stdout 只放機器要抓的那行，log 走 stderr。
- MDX：繁體中文台灣用語；never-translate 清單詞彙保留英文；不在 MDX import 元件；程式碼註解英文。
- 真機注入只由 orchestrator 直接跑；場景腳本必須 `--yes-really-inject`、trap rollback、前後 HEALTH_OK gate。
- 破壞性網路/磁碟注入前先武裝 timed 自動回退（nohup sleep + 還原指令）。
- rules 三處一致性由 `check-rules-match-page.sh` 把關：**改 rules 的任務必須同步改頁面 YAML 區塊與 checker invariants**。

---

## Phase 0 — 共用基礎

### Task 1: scenario framework 與負向斷言 helpers

**Files:**
- Create: `experiments/ceph-alert-real-lab/lib/scenario-framework.sh`
- Modify: `experiments/ceph-alert-real-lab/lib/monitoring.sh`（新增 3 個 helper，追加在檔尾）
- Create: `experiments/ceph-alert-real-lab/tests/test-scenario-framework.sh`

**Interfaces:**
- Produces: `scenario_main <name> "$@"` — caller 需定義 `scenario_inject`、`scenario_rollback`、`scenario_verify`，可選 `scenario_setup`（在 sink checkpoint 前跑，放 pool 建立類 prep）。globals：`RESULT_DIR`、`SINK_CHECKPOINT`。
- Produces: `assert_prometheus_alert_not_firing <alertname> <label_name> <label_value> <result_dir>`（單發，firing 則 return 1）。
- Produces: `assert_sink_absent <receiver> <alertname> <label_name> <label_value> <result_dir> <checkpoint_file>`（單發，sink 自 checkpoint 後無該 alert 則 0）。
- Produces: `wait_alertmanager_inhibited <alertname> <result_dir>`（poll AM `/api/v2/alerts`，該 alertname 有非空 `status.inhibitedBy` 則 PASS）。
- Consumes: `lib/common.sh` 的 `require_destructive_ack`/`new_result_dir`/`log`；`lib/evidence.sh` 的 `collect_baseline`/`assert_lab_ready`/`assert_lab_recovered`/`collect_postcheck`；`lib/monitoring.sh` 的 `record_sink_checkpoint`/`prometheus_alert_is_firing`。

- [ ] **Step 1: 寫會紅的測試**

`tests/test-scenario-framework.sh`（跟隨既有 test-*.sh 的 fake-PATH 模式；run-tests.sh 會自動撿）。測試案例：
1. `scenario_main` 無 `--yes-really-inject` → exit 2，且 inject 未被呼叫（trace file 無 `inject` 行）。
2. 正常路徑：inject → verify → rollback 依序出現在 trace，stdout 最後一行 `result: <dir>`。
3. verify 失敗（return 1）→ rollback 仍被呼叫、exit 非 0。
4. rollback 冪等：verify 成功路徑 rollback 只跑一次（trace 只一行 `rollback`）。
5. `assert_prometheus_alert_not_firing`：fake kubectl 回 firing JSON → return 1；回空 alerts → return 0。
6. `assert_sink_absent`：sink log 自 checkpoint 後含該 alertname → return 1；不含 → return 0。
7. `wait_alertmanager_inhibited`：fake kubectl 對 `wget -qO- http://127.0.0.1:9093/api/v2/alerts` 回 `[{"labels":{"alertname":"CephMonDownScoped"},"status":{"inhibitedBy":["abc"]}}]` → PASS。

- [ ] **Step 2: 跑測試確認紅**：`bash experiments/ceph-alert-real-lab/tests/run-tests.sh`，新檔案 FAIL（framework 不存在）。

- [ ] **Step 3: 實作 `lib/scenario-framework.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# scenario_main <scenario-name> "$@"
# Caller must define: scenario_inject, scenario_rollback, scenario_verify.
# Optional: scenario_setup (runs before sink checkpoint; put pool creation here).
_SCENARIO_CLEANED=0

_scenario_cleanup() {
  local rc=0
  if [[ "$_SCENARIO_CLEANED" -eq 1 ]]; then
    return 0
  fi
  log "rollback: $_SCENARIO_NAME"
  scenario_rollback || rc=1
  collect_postcheck "$RESULT_DIR/postcheck" || true
  assert_lab_recovered "$RESULT_DIR/recovery" || rc=1
  _SCENARIO_CLEANED=1
  return "$rc"
}

_scenario_cleanup_on_exit() {
  local rc=$?
  _scenario_cleanup || true
  exit "$rc"
}

scenario_main() {
  _SCENARIO_NAME=$1
  shift
  require_destructive_ack "$_SCENARIO_NAME" "$@"
  require_cmd jq
  RESULT_DIR="$(new_result_dir "$_SCENARIO_NAME")"
  SINK_CHECKPOINT="$RESULT_DIR/sink-checkpoint-lines.txt"
  trap _scenario_cleanup_on_exit EXIT
  collect_baseline "$RESULT_DIR/baseline"
  assert_lab_ready "$RESULT_DIR/ready-before-injection"
  if declare -F scenario_setup >/dev/null; then
    scenario_setup
  fi
  record_sink_checkpoint "$RESULT_DIR"
  scenario_inject
  scenario_verify
  trap - EXIT
  _scenario_cleanup || exit 1
  printf 'result: %s\n' "$RESULT_DIR"
}
```

- [ ] **Step 4: 實作三個 helper（追加到 `lib/monitoring.sh`）**

```bash
assert_prometheus_alert_not_firing() {
  local alertname=$1 label_name=$2 label_value=$3 result_dir=$4
  if prometheus_alert_is_firing "$alertname" "$label_name" "$label_value" "$result_dir"; then
    log "FAIL: alert $alertname unexpectedly firing"
    return 1
  fi
  log "PASS: alert $alertname not firing"
  return 0
}

alertmanager_alert_is_inhibited() {
  local alertname=$1 result_dir=$2 pod out
  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=alertmanager -o jsonpath='{.items[0].metadata.name}')"
  out="$(kubectl_lab -n "$LAB_NAMESPACE" exec "$pod" -- wget -qO- http://127.0.0.1:9093/api/v2/alerts)"
  printf '%s\n' "$out" >"$result_dir/alertmanager-alerts-${alertname}.json"
  printf '%s\n' "$out" | jq -e --arg an "$alertname" \
    '.[] | select(.labels.alertname==$an) | select((.status.inhibitedBy | length) > 0)' >/dev/null
}

wait_alertmanager_inhibited() {
  local alertname=$1 result_dir=$2
  poll_until "Alertmanager alert $alertname inhibited" "${ALERTMANAGER_WAIT_ATTEMPTS:-60}" "${ALERTMANAGER_WAIT_SLEEP:-5}" \
    alertmanager_alert_is_inhibited "$alertname" "$result_dir"
}

assert_sink_absent() {
  local receiver=$1 alertname=$2 label_name=$3 label_value=$4 result_dir=$5 checkpoint_file="${6:-}"
  local start=0
  kubectl_lab -n "$LAB_NAMESPACE" logs deploy/alert-sink >"$result_dir/sink-absent-check.log"
  if [[ -n "$checkpoint_file" && -f "$checkpoint_file" ]]; then
    start="$(cat "$checkpoint_file")"
  fi
  awk -v start="$start" 'NR > start' "$result_dir/sink-absent-check.log" >"$result_dir/sink-absent-since-checkpoint.log"
  if jq -r . "$result_dir/sink-absent-since-checkpoint.log" 2>/dev/null \
    | jq -e --arg r "$receiver" --arg an "$alertname" --arg ln "$label_name" --arg lv "$label_value" \
      'select(.receiver==$r) | select(.alertname==$an) | select(($ln=="") or (.labels[$ln]==$lv))' >/dev/null; then
    log "FAIL: sink $receiver unexpectedly received $alertname"
    return 1
  fi
  log "PASS: sink $receiver did not receive $alertname"
  return 0
}
```

- [ ] **Step 5: 跑測試綠**：`bash experiments/ceph-alert-real-lab/tests/run-tests.sh` 全 PASS。
- [ ] **Step 6: shellcheck 0**：`shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/tests/*.sh`
- [ ] **Step 7: Commit** `git commit --no-gpg-sign -m "Add scenario framework and negative assertion helpers"`

### Task 2: 既有三個場景遷移到 framework

**Files:**
- Modify: `experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh`、`run/scenario-mon-quorum-lost.sh`、`run/scenario-slow-ops.sh`
- Modify: 對應 `tests/test-scenario-*.sh`（只在行為斷言需要時最小幅調整；行為不得變）

**Interfaces:**
- Consumes: Task 1 的 `scenario_main` 合約。
- Produces: 三個腳本語意不變（相同注入、相同斷言、相同 rollback），樣板碼移入 framework。

- [ ] **Step 1:** 逐一改寫：把 `require_destructive_ack`/`new_result_dir`/trap/cleanup/baseline/ready/checkpoint 樣板刪除，改為定義 `scenario_setup`（pool 建立）、`scenario_inject`（停 OSD/mon、限速）、`scenario_rollback`（原 cleanup 內容減去 postcheck/recovered——那兩個 framework 會呼叫）、`scenario_verify`（原 wait_* 斷言），檔尾 `scenario_main <name> "$@"`。
- [ ] **Step 2:** 每改一個腳本就跑 `bash experiments/ceph-alert-real-lab/tests/run-tests.sh`，既有測試必須維持綠（fake 測試斷言的是行為 trace，不是樣板實作）。
- [ ] **Step 3:** shellcheck 0。
- [ ] **Step 4: Commit** `"Migrate existing scenarios onto scenario framework"`

### Task 3: rules v2（stability-first 修訂 + 新 coverage group）+ tierA + 頁面 YAML 同步

**Files:**
- Modify: `experiments/ceph-alert-rules/rules/ceph-stability-first.yml`
- Create: `experiments/ceph-alert-rules/rules/ceph-production-coverage.yml`
- Modify: `experiments/ceph-alert-rules/lib/check-rules-match-page.sh`（invariants + for: 對照表）
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`（僅 YAML 區塊與其直述文字；新 rule 的完整說明留給 Task 23 的新頁面）
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/coverage-*.test.yml`（每條新 rule 一檔）
- Modify: 既有 `tierA-promtool/client-blocked.test.yml`、`client-risk.test.yml`、`exporter-down.test.yml`、`low-priority-notice.test.yml`（regex 變更）

**Interfaces:**
- Produces: 下列 rules 全文（後續任務與頁面逐字引用）。

`ceph-stability-first.yml` 修訂後四條變更點：

```yaml
      - alert: CephClientBlocked
        expr: ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL"} == 1
        for: 1m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "Ceph client I/O blocked: {{ $labels.name }}"

      - alert: CephClientRisk
        expr: |
          ceph_health_detail{
            name!~"PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL|OSD_DOWN|OSD_HOST_DOWN|MON_DOWN|HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSDMAP_FLAGS|POOL_APP_NOT_ENABLED|POOL_NEARFULL|OSD_SLOW_PING_TIME_BACK|OSD_SLOW_PING_TIME_FRONT|MON_CLOCK_SKEW|RECENT_CRASH|OSD_NEARFULL|OSD_BACKFILLFULL|MON_DISK_LOW|MON_DISK_CRIT|PG_DAMAGED|OSD_SCRUB_ERRORS|OBJECT_UNFOUND"
          } == 1
        for: 5m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "Ceph client-risk check active: {{ $labels.name }}"

      - alert: CephExporterAllDown
        expr: (count(up{job="ceph"} == 1) or vector(0)) == 0
        for: 5m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "All Ceph Prometheus exporter targets are down"

      - alert: CephExporterTargetDown
        expr: up{job="ceph"} == 0
        for: 15m
        labels:
          severity: warning
          source: ceph_stability
        annotations:
          summary: "Ceph exporter target {{ $labels.instance }} is down"

      - alert: CephLowPriorityNotice
        expr: |
          ceph_health_detail{
            name=~"HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSDMAP_FLAGS|POOL_APP_NOT_ENABLED|POOL_NEARFULL"
          } == 1
        for: 30m
        labels:
          severity: info
          source: ceph_stability
        annotations:
          summary: "Ceph low-priority notice: {{ $labels.name }}"
```

（`CephClientBlocked`/`CephMonQuorumLost` 其餘欄位不變；原 `CephExporterDown` 刪除，由上面兩條取代。）

`ceph-production-coverage.yml` 全文：

```yaml
groups:
  - name: ceph-production-coverage
    rules:
      - alert: CephMetricsAbsent
        expr: absent(ceph_health_status)
        for: 5m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph metrics absent from Prometheus (blind monitoring)"

      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
          source: ceph_coverage
        annotations:
          summary: "Always-firing heartbeat; wire to external dead-man switch"

      - alert: CephOSDSlowHeartbeat
        expr: ceph_health_detail{name=~"OSD_SLOW_PING_TIME_BACK|OSD_SLOW_PING_TIME_FRONT"} == 1
        for: 2m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD heartbeat pings are slow: {{ $labels.name }}"

      - alert: CephOSDFlapping
        expr: |
          (changes(ceph_osd_up[15m]) * on (ceph_daemon) group_left(hostname) ceph_osd_metadata) >= 4
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD flapping: {{ $labels.ceph_daemon }} on {{ $labels.hostname }}"

      - alert: CephMonClockSkew
        expr: ceph_health_detail{name="MON_CLOCK_SKEW"} == 1
        for: 2m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph MON clock skew detected"

      - alert: CephOSDLatencyOutlier
        expr: |
          (
            ceph_osd_commit_latency_ms > 100
            and
            ceph_osd_commit_latency_ms > 3 * scalar(quantile(0.5, ceph_osd_commit_latency_ms))
          ) * on (ceph_daemon) group_left(hostname) ceph_osd_metadata
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD commit latency outlier: {{ $labels.ceph_daemon }} on {{ $labels.hostname }}"

      - alert: CephDaemonSlowOps
        expr: ceph_daemon_health_metrics{type="SLOW_OPS"} > 0
        for: 3m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph daemon has slow ops: {{ $labels.ceph_daemon }}"

      - alert: CephDaemonRecentCrash
        expr: ceph_health_detail{name="RECENT_CRASH"} == 1
        for: 5m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph daemon crash reported in the last two weeks"

      - alert: CephMgrNoStandby
        expr: (count(ceph_mgr_status) or vector(0)) < 2
        for: 5m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph mgr has no standby (failover capacity lost)"

      - alert: CephOSDNearFull
        expr: ceph_health_detail{name="OSD_NEARFULL"} == 1
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD(s) near full"

      - alert: CephOSDBackfillFull
        expr: ceph_health_detail{name="OSD_BACKFILLFULL"} == 1
        for: 5m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD(s) backfill-full: recovery is blocked"

      - alert: CephMonDiskLow
        expr: ceph_health_detail{name="MON_DISK_LOW"} == 1
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph MON data disk space low"

      - alert: CephMonDiskCritical
        expr: ceph_health_detail{name="MON_DISK_CRIT"} == 1
        for: 1m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph MON data disk space critically low"

      - alert: CephPoolNearQuota
        expr: |
          (
            ceph_pool_bytes_used > 0.8 * ceph_pool_quota_bytes
            and
            ceph_pool_quota_bytes > 0
          ) * on (pool_id) group_left(name) ceph_pool_metadata
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph pool {{ $labels.name }} above 80% of quota"

      - alert: CephCapacityForecast
        expr: |
          max(predict_linear(ceph_cluster_total_used_bytes[1h], 259200))
          > 0.85 * max(ceph_cluster_total_bytes)
        for: 30m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph raw capacity projected to exceed 85% within 3 days"

      - alert: CephDataDamage
        expr: ceph_health_detail{name=~"PG_DAMAGED|OSD_SCRUB_ERRORS"} == 1
        for: 1m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph data damage detected: {{ $labels.name }} — identify bad replica before repair"

      - alert: CephObjectUnfound
        expr: ceph_health_detail{name="OBJECT_UNFOUND"} == 1
        for: 1m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph objects unfound: latest replica unavailable"

      - alert: CephPGUnhealthyStates
        expr: |
          (
            (ceph_pg_down + ceph_pg_incomplete + ceph_pg_unknown + ceph_pg_stale + ceph_pg_peered)
            * on (pool_id) group_left(name) ceph_pool_metadata
          ) > 0
        for: 3m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph pool {{ $labels.name }} has PGs in unhealthy states"
```

- [ ] **Step 0（先做）: 對真叢集驗證 metric label 形狀**（read-only）：
  `ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none ikaros@192.168.18.166 'curl -s http://192.168.18.166:9283/metrics | grep -E "^ceph_daemon_health_metrics|^ceph_pool_metadata|^ceph_pg_down|^ceph_pool_quota"' | head -20`
  確認 `ceph_daemon_health_metrics` 有 `{ceph_daemon,type}`、pool 系列 metric 的 join key 是 `pool_id`、`ceph_pool_metadata` 有 `name`。若形狀不同 → 修正上面 expr（rules 檔、tierA、頁面三處同改），並在 commit message 記載。
- [ ] **Step 1: 先寫 tierA 測試（紅）**。每條新 rule 一個 `coverage-<kebab>.test.yml`，用既有檔案的格式（`rule_files` 指到 `../../rules/...`，`evaluation_interval: 1m`）。必測向量：
  - `CephMetricsAbsent`：(a) 無任何 `ceph_health_status` series → 6m 時 firing；(b) `ceph_health_status 0x10` → 不 firing。
  - `CephOSDFlapping`：(a) `ceph_osd_up{ceph_daemon="osd.1"}` 值序列 `1 0 1 0 1`（5 個 1m 間隔樣本 = 4 changes）+ `ceph_osd_metadata{ceph_daemon="osd.1",hostname="h1"} 1x20` → firing 且 label `hostname=h1`；(b) 單次重啟 `1 0 1 1 1` → 不 firing。
  - `CephOSDLatencyOutlier`：(a) 9 顆 OSD，8 顆 latency 10ms、1 顆 400ms（皆有 metadata join）→ 11m 時只有那顆 firing；(b) 全部 90ms（低於絕對地板 100）→ 不 firing；(c) 全部 400ms（中位數也 400，3×median 不成立）→ 不 firing。
  - `CephMgrNoStandby`：(a) 只有一個 `ceph_mgr_status` series → firing；(b) 兩個 → 不 firing；(c) **零個** series → firing（`or vector(0)` 生效）。
  - `CephPoolNearQuota`：(a) used 90、quota 100、metadata name=p1 → firing 帶 `name=p1`；(b) quota 0（未設）→ 不 firing。
  - `CephCapacityForecast`：(a) `ceph_cluster_total_bytes 1000x120`、`ceph_cluster_total_used_bytes 0+10x120`（每分鐘 +10，72h 投影遠超 850）→ 40m 時 firing；(b) used 恆定 100 → 不 firing。
  - `CephPGUnhealthyStates`：(a) `ceph_pg_down{pool_id="2"} 1`、其餘 pg 系列 0、metadata name=p2 → 4m firing；(b) 全 0 → 不 firing。
  - health-detail 名稱類（SlowHeartbeat/ClockSkew/RecentCrash/NearFull/BackfillFull/MonDiskLow/MonDiskCritical/DataDamage/ObjectUnfound/DaemonSlowOps）：各一 firing + 一不 firing 向量，直接以 `ceph_health_detail{name="..."} 1` / `0` 或 `ceph_daemon_health_metrics{ceph_daemon="osd.3",type="SLOW_OPS"} 5` 餵。
  - 修訂類：`client-blocked.test.yml` 加 OSD_FULL/POOL_FULL firing 向量；`client-risk.test.yml` 改用 `OSD_NO_DOWN_OUT_INTERVAL` 當 firing 向量、加「RECENT_CRASH 不再觸發 ClientRisk」向量；`exporter-down.test.yml` 改為 AllDown（雙 target 全 0 → firing；一 up 一 down → AllDown 不 firing、TargetDown 該 instance firing）；`low-priority-notice.test.yml` 加 POOL_APP_NOT_ENABLED、POOL_NEARFULL 向量。
- [ ] **Step 2: 跑紅**：`bash experiments/ceph-alert-rules/run/tierA.sh` → 新測試 FAIL。
- [ ] **Step 3: 寫 rules**（上面全文照抄進兩個 rules 檔）。
- [ ] **Step 4: 跑綠**：tierA 全 PASS。
- [ ] **Step 5: 同步頁面與 checker**：`prometheus-alert-design.mdx` 的 `ceph-stability-first` YAML 區塊改成與 rules 檔一致（含新排除清單與 Exporter 拆分），routing 區塊改為 label 導向 v2（見 Task 4 全文），並在文字段落補一句指向新頁面。`check-rules-match-page.sh`：invariants 陣列更新（舊 `up{job="ceph"} == 0` 保留——TargetDown 仍用；新增 ClientBlocked 新 regex、ClientRisk 新排除串、`(count(up{job="ceph"} == 1) or vector(0)) == 0`；移除舊 pager route alertname regex invariant，改為 `source=~"ceph_stability|ceph_scoped|ceph_coverage"`）；for: 對照表的 `CephExporterDown` 改為 `CephExporterAllDown`+`CephExporterTargetDown`。
- [ ] **Step 6: 跑 checker + tierB**：`bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh` PASS；`bash experiments/ceph-alert-rules/run/tierB.sh`（routing 測試若引用舊 alertname regex 需同步改——tierB 的 amtool routing 測試改為對 label 的斷言：critical+source→pager、warning/info+source→slack、Watchdog→watchdog-ceph、ceph_default 維持）。
- [ ] **Step 7: `make validate`** 綠（MDX 改動）。
- [ ] **Step 8: Commit** `"Extend alert rules to production coverage v2"`

### Task 4: real-lab 監控 stack v2（單一 rules 來源、multi-mgr scrape、routing v2、watchdog receiver）

**Files:**
- Modify: `experiments/ceph-alert-real-lab/lib/monitoring.sh`（`render_monitoring_manifest`）
- Modify: `experiments/ceph-alert-real-lab/lib/common.sh`（`LAB_MGR_ENDPOINTS`）
- Modify: `experiments/ceph-alert-real-lab/lib/evidence.sh`（curl 兩個 mgr）
- Modify: `experiments/ceph-alert-real-lab/tests/test-monitoring-render.sh`

**Interfaces:**
- Produces: rendered ConfigMap `ceph-alert-rules` 內含四個檔案，**由 render 時直接讀取**：`ceph-stability-first.yml`、`ceph-production-coverage.yml`、`ceph-scoped-availability.yml`（皆讀自 `experiments/ceph-alert-rules/rules/`）與 `default-mixin.yml`（讀自 `experiments/ceph-alert-rules/rules/_default-mixin.yml`）。render 函式用 `sed 's/^/    /'` 縮排嵌入，不再手抄 YAML。
- Produces: prometheus scrape `job_name: ceph` 的 targets = `192.168.18.166:9283` + `192.168.18.167:9283`。
- Produces: alertmanager config v2：

```yaml
    route:
      receiver: slack-ceph
      group_by: ['alertname', 'name', 'hostname', 'ceph_daemon']
      group_wait: 0s
      group_interval: 5s
      repeat_interval: 30m
      routes:
        - receiver: watchdog-ceph
          matchers:
            - alertname="Watchdog"
          group_wait: 0s
          repeat_interval: 1m
        - receiver: pager-ceph
          group_wait: 0s
          matchers:
            - severity="critical"
            - source=~"ceph_stability|ceph_scoped|ceph_coverage"
        - receiver: pager-ceph
          group_wait: 0s
          matchers:
            - type="ceph_default"
            - alertname="CephHealthError"
        - receiver: slack-ceph
          matchers:
            - source=~"ceph_stability|ceph_scoped|ceph_coverage"
        - receiver: slack-ceph
          matchers:
            - type="ceph_default"
    inhibit_rules:
      - source_matchers:
          - alertname="CephMonQuorumLost"
        target_matchers:
          - alertname="CephMonDownScoped"
    receivers:
      - name: slack-ceph
        webhook_configs:
          - url: http://alert-sink.ceph-alert-lab.svc.cluster.local:8080/slack
      - name: pager-ceph
        webhook_configs:
          - url: http://alert-sink.ceph-alert-lab.svc.cluster.local:8080/pager
      - name: watchdog-ceph
        webhook_configs:
          - url: http://alert-sink.ceph-alert-lab.svc.cluster.local:8080/watchdog
```

- Produces: `LAB_MGR_ENDPOINTS="http://192.168.18.166:9283 http://192.168.18.167:9283"`（空白分隔；evidence 以 for 迴圈 curl 兩個，輸出 `mgr-metrics-<ip>.txt`；舊 `LAB_MGR_ENDPOINT` 刪除、所有引用同步改）。
- Prometheus `rule_files` 列出四個 rules 檔路徑。

- [ ] **Step 1: 改 render 測試（紅）**：斷言 rendered yaml 含 (a) 兩個 scrape target、(b) `ceph-production-coverage.yml` 與 `default-mixin.yml` 的 key、(c) `source=~"ceph_stability|ceph_scoped|ceph_coverage"` matcher、(d) inhibit_rules 區塊、(e) watchdog receiver、(f) 來自 rules 檔的哨兵字串（如 `CephPGUnhealthyStates`、mixin 的 `CephHealthError`）。
- [ ] **Step 2: 跑紅** → **Step 3: 實作 render v2**（讀檔嵌入 + 上面 alertmanager 全文）→ **Step 4: 跑綠**。
- [ ] **Step 5:** shellcheck 0 + `bash experiments/ceph-alert-real-lab/tests/run-tests.sh` 全綠。
- [ ] **Step 6: Commit** `"Render lab monitoring from shared rules with multi-mgr scrape and routing v2"`

---

## Phase 1 — 場景腳本（每個 = 腳本 + fake 測試；全部遵守 Task 1 合約）

**共通規格（每個場景任務都適用，不再重複）：**
- 腳本放 `experiments/ceph-alert-real-lab/run/scenario-<name>.sh`，測試放 `tests/test-scenario-<name>.sh`。
- 腳本結構：source 四個 lib + scenario-framework → 定義 `scenario_setup`（可選）/`scenario_inject`/`scenario_rollback`/`scenario_verify` → `scenario_main <name> "$@"`。
- 遠端 ceph 指令一律 `ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- <cmd>"`；輸出用 `run_capture "$RESULT_DIR/<label>.txt" ...` 留證據。
- fake 測試遵循 `test-scenario-pg-availability.sh` 模式：fake `ssh`/`kubectl`/`jq` 進 PATH + trace file；斷言 (a) 無 ack → exit 2 且無注入 trace、(b) 注入指令序列出現且順序正確、(c) rollback 指令出現（含 verify 失敗路徑）、(d) stdout 末行 `result: `。fake ssh 需為該場景的查詢指令回傳最小 JSON/文字（在任務中列出）。
- 完成即跑 `run-tests.sh` + shellcheck，綠了才 commit；commit message 用 `"Add <name> alert scenario"`。

### Task 5: S4 scenario-osd-daemon-down

**Interfaces:** Consumes `wait_prometheus_alert`/`wait_sink_alert`/`assert_prometheus_alert_not_firing`。

注入/斷言（`OSD_DOWN_HOST` 預設 `ceph-lab-osd-01`，`OSD_DOWN_ID` 預設自動選：`ceph osd ls-tree <host>` 第一顆）：
- inject：`sudo systemctl stop "$(osd_service_name "$LAB_FSID" "$osd")"`（在該 host）。
- verify：`wait_ceph_health_check OSD_DOWN`；`wait_prometheus_alert CephOSDDaemonDownScoped ceph_daemon "osd.$osd"`；`assert_prometheus_alert_not_firing CephOSDHostDownScoped hostname "$OSD_DOWN_HOST"`（在 daemon alert firing 後單發檢查）；`wait_sink_alert pager CephOSDDaemonDownScoped ceph_daemon "osd.$osd"`；`wait_sink_alert slack CephOSDDown "" ""`（mixin 預設 rule 進 slack 的證據）。
- rollback：`systemctl start` 同 service。
- fake ssh 需回：`ceph osd ls-tree ceph-lab-osd-01` → `0`；health detail 含 `OSD_DOWN`。fake kubectl alerts API 回 `CephOSDDaemonDownScoped`（`ceph_daemon=osd.0`，state firing）；sink log 回 pager `CephOSDDaemonDownScoped` + slack `CephOSDDown`。
- 完整腳本骨架（後續場景同構，不再印）：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"; source "$ROOT/lib/monitoring.sh"
source "$ROOT/lib/evidence.sh"; source "$ROOT/lib/scenarios.sh"
source "$ROOT/lib/scenario-framework.sh"

OSD_DOWN_HOST="${OSD_DOWN_HOST:-ceph-lab-osd-01}"
OSD_DOWN_ID="${OSD_DOWN_ID:-}"
_host_ip=""; _service=""

scenario_setup() {
  _host_ip="$(lab_osd_host_ip "$OSD_DOWN_HOST")"
  if [[ -z "$OSD_DOWN_ID" ]]; then
    OSD_DOWN_ID="$(ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd ls-tree $OSD_DOWN_HOST" | head -1 | tr -d '[:space:]')"
  fi
  [[ -n "$OSD_DOWN_ID" ]] || die "no OSD found on $OSD_DOWN_HOST"
  _service="$(osd_service_name "$LAB_FSID" "$OSD_DOWN_ID")"
}

scenario_inject() {
  run_capture "$RESULT_DIR/stop-osd.txt" ssh_lab "$_host_ip" "sudo systemctl stop $_service"
}

scenario_rollback() {
  run_capture "$RESULT_DIR/rollback-start-osd.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service" || return 1
}

scenario_verify() {
  wait_ceph_health_check OSD_DOWN "$RESULT_DIR"
  wait_prometheus_alert CephOSDDaemonDownScoped ceph_daemon "osd.$OSD_DOWN_ID" "$RESULT_DIR"
  assert_prometheus_alert_not_firing CephOSDHostDownScoped hostname "$OSD_DOWN_HOST" "$RESULT_DIR"
  wait_sink_alert pager CephOSDDaemonDownScoped ceph_daemon "osd.$OSD_DOWN_ID" "$RESULT_DIR" "$SINK_CHECKPOINT"
  wait_sink_alert slack CephOSDDown "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_main osd-daemon-down "$@"
```

### Task 6: S5 scenario-osd-host-down

同構。`OSD_HOST_DOWN_HOST` 預設 `ceph-lab-osd-02`。
- setup：`ceph osd ls-tree` 取得該 host 全部 OSD id 存檔。
- inject：對每顆 `systemctl stop`。
- verify：`wait_prometheus_alert CephOSDHostDownScoped hostname <host>`；對每顆 `assert_prometheus_alert_not_firing CephOSDDaemonDownScoped ceph_daemon osd.N`（`unless` 去重證據）；`wait_sink_alert pager CephOSDHostDownScoped hostname <host>`。
- rollback：逐顆 `systemctl start`（讀檔逆序無所謂）。
- fake ssh：ls-tree 回 `3 4 5` 三行。

### Task 7: S6 scenario-mon-down-single

`MON_DOWN_NAME` 預設 `ceph-lab-mon-03`（避開 active mgr 與 seed）。
- inject：該 host `systemctl stop "$(mon_service_name "$LAB_FSID" "$MON_DOWN_NAME")"`。
- verify：`wait_ceph_health_check MON_DOWN`；`wait_prometheus_alert CephMonDownScoped ceph_daemon "mon.$MON_DOWN_NAME"`；`assert_prometheus_alert_not_firing CephMonQuorumLost "" ""`；`wait_sink_alert pager CephMonDownScoped ceph_daemon "mon.$MON_DOWN_NAME"`。
- rollback：`systemctl start`。

### Task 8: S7 scenario-exporter-blind

- inject：`ceph mgr module disable prometheus`。
- verify：`wait_prometheus_alert CephMetricsAbsent "" ""`；`wait_prometheus_alert CephExporterAllDown "" ""`；`wait_sink_alert pager CephMetricsAbsent "" ""`；`wait_sink_alert pager CephExporterAllDown "" ""`。
- rollback：`ceph mgr module enable prometheus`（recovery gate 會等 target 回 up）。
- 腳本註解記載：blind 期間 `CephMonQuorumLost` 依設計也會 fire（`or vector(0)` 的已文件化 trade-off），不做斷言。
- 注意 `PROMETHEUS_WAIT_ATTEMPTS` 需 ≥ 90（absent 5m for + 傳遞），在腳本內 export 覆寫。

### Task 9: S8 scenario-mgr-failover

兩段式：
- inject（a）：`ceph mgr fail`（現任 active 讓位）→ verify（a）：poll `prometheus_query 'ceph_health_status'` 直到 result 非空且 timestamp 新（斷言 multi-target 讓 metrics 不中斷超過 60s）；`assert_prometheus_alert_not_firing CephMetricsAbsent "" ""`。
- inject（b）：查 `ceph mgr dump | jq -r '.standbys[0].name'`（或 `ceph mgr metadata`）找 standby 所在 host，`systemctl stop ceph-<fsid>@mgr.<name>.service`。
- verify（b）：`wait_prometheus_alert CephMgrNoStandby "" ""`；`wait_sink_alert slack CephMgrNoStandby "" ""`；`assert_sink_absent pager CephMgrNoStandby "" ""`（warning 不得進 pager）。
- rollback：`systemctl start` 該 mgr service。
- fake ssh：`ceph mgr dump` 回 `{"active_name":"a","standbys":[{"name":"ceph-lab-mon-02.wmkpax"}]}`；mgr metadata 查 hostname 回 `ceph-lab-mon-02`；`lab_mon_host_ip` 解析。

### Task 10: S9 scenario-catch-all-risk

- inject：`ceph config set mon mon_osd_down_out_interval 0`。
- verify：`wait_ceph_health_check OSD_NO_DOWN_OUT_INTERVAL`；`wait_prometheus_alert CephClientRisk name OSD_NO_DOWN_OUT_INTERVAL`；`wait_sink_alert pager CephClientRisk name OSD_NO_DOWN_OUT_INTERVAL`。
- rollback：`ceph config rm mon mon_osd_down_out_interval`。
- `PROMETHEUS_WAIT_ATTEMPTS` ≥ 90（for: 5m）。

### Task 11: S10 scenario-low-priority-notice

- inject：`ceph osd set noout`。
- verify：`wait_ceph_health_check OSDMAP_FLAGS`；`wait_prometheus_alert CephLowPriorityNotice name OSDMAP_FLAGS`（`PROMETHEUS_WAIT_ATTEMPTS=450`、sleep 5 → 上限 37.5m，蓋 for: 30m）；`wait_sink_alert slack CephLowPriorityNotice name OSDMAP_FLAGS`；`assert_sink_absent pager CephLowPriorityNotice "" ""`。
- rollback：`ceph osd unset noout`。
- README 註明此場景 wall-clock >30m。

### Task 12: S11 scenario-latency-outlier

重用 slow-ops 的 cgroup 機制（`cgroup_io_max_path_command`/`io_throttle_command`），但限速較寬（預設 `LATENCY_BPS=4194304` 4MB/s，不至於觸發 SLOW_OPS）+ 背景 `rados bench 300 write` 打 setup 建的測試 pool。
- setup：建 pool `alert-latency-outlier`（`pool_create_commands`）；選 OSD：沿用 slow-ops 的自動選擇邏輯（acting set 第一顆 + `ceph-volume` 找 backing device）。
- inject：套 io.max 限速 → 於 seed host 用 `nohup ... rados bench ... >/dev/null 2>&1 &` 起 5 分鐘寫入。
- verify：`wait_prometheus_alert CephOSDLatencyOutlier ceph_daemon "osd.$id"`（for: 10m → attempts ≥ 200）；`wait_sink_alert slack CephOSDLatencyOutlier ceph_daemon "osd.$id"`；`assert_sink_absent pager CephOSDLatencyOutlier "" ""`。
- rollback：解除 io.max（`io_unthrottle_command`）、`pkill -f "rados bench"`（`|| true`）、刪 pool。
- 若 10m 內 latency 未達 3×中位數（bench 壓力不足），fallback：調 `LATENCY_BPS=1048576` 重跑一次（腳本內建一次 retry，log 記載）。

### Task 13: S12 scenario-net-slow-heartbeat

- setup：目標 host 預設 `ceph-lab-osd-03`；探測 iface：`ip route get 192.168.18.166 | sed -n 's/.* dev \([^ ]*\).*/\1/p'`。
- inject：**先武裝自動回退**：`nohup sh -c 'sleep 900; tc qdisc del dev IF root' >/dev/null 2>&1 &`（sudo；記 PID 檔）→ `sudo tc qdisc add dev IF root netem delay 1200ms`。
- verify：`wait_ceph_health_check OSD_SLOW_PING_TIME`（match 子字串，BACK/FRONT 皆可）；`wait_prometheus_alert CephOSDSlowHeartbeat "" ""`；`wait_sink_alert pager CephOSDSlowHeartbeat "" ""`。
- rollback：`sudo tc qdisc del dev IF root || true` + kill 武裝的 sleeper（`sudo pkill -f 'sleep 900'`，`|| true`）。
- fake ssh：`ip route get` 回 `... dev eth0 ...`；tc 指令 append trace。

### Task 14: S13 scenario-mon-clock-skew

目標 `ceph-lab-mon-03`（.164；非 seed、非 active mgr）。
- setup：偵測時間同步服務：`systemctl is-active systemd-timesyncd chrony chronyd 2>/dev/null | grep -n active` 存變數（fake 測試兩種都覆蓋）。
- inject：停該服務 → `sudo date -s '+2 seconds'`。
- verify：`wait_ceph_health_check MON_CLOCK_SKEW`（mon timecheck 週期最長 300s → `CEPH_HEALTH_CHECK_ATTEMPTS=120`）；`wait_prometheus_alert CephMonClockSkew "" ""`；`wait_sink_alert pager CephMonClockSkew "" ""`。
- rollback：`sudo date -s '-2 seconds'` → 啟動時間同步服務 →（health 清除由 recovery gate 等）。
- 註解記載：±2s 在 quorum 容忍內，只觸發 warn 級 skew 檢查。

### Task 15: S14 scenario-daemon-crash

- setup：選 `ceph-lab-osd-01` 第一顆 OSD；`systemctl show -p MainPID --value <service>` 取 PID。
- inject：`sudo kill -SEGV <pid>`。
- verify：`wait_ceph_health_check RECENT_CRASH`（crash post 需時 → attempts 120）；`wait_prometheus_alert CephDaemonRecentCrash "" ""`；`wait_sink_alert slack CephDaemonRecentCrash "" ""`；`assert_sink_absent pager CephDaemonRecentCrash "" ""`。
- rollback：`ceph crash archive-all`；確認 OSD 已被 systemd 拉回（`systemctl is-active` poll，未回來則 `systemctl start`）。

### Task 16: S15 scenario-osd-flapping

- setup：選 `ceph-lab-osd-01` 上「第二顆」OSD（`ls-tree | sed -n 2p`，避開 S4 慣用目標以隔離 changes() 窗）。
- inject：`systemctl stop` → poll `ceph osd tree down` 確認 → `systemctl start` → poll up → 再 stop → start（= 4 transitions；每步 `run_capture`）。
- verify：`wait_prometheus_alert CephOSDFlapping ceph_daemon "osd.$id"`；`wait_sink_alert pager CephOSDFlapping ceph_daemon "osd.$id"`。
- rollback：確保最終 `systemctl start`（冪等）。
- 註解：firing 會殘留至 15m 窗滑出；all.sh 排序讓後續場景不對同 daemon 做 up/down 斷言。

### Task 17: S16 scenario-capacity-ladder

- setup：建 pool `alert-capacity`（1 PG、size 3）；`rados bench -p alert-capacity 30 write --no-cleanup` 迴圈直到 `ceph df --format json` 的 raw used ≥ 27GiB（~3%，上限 10 輪防呆）。記錄目前 ratios（`ceph osd dump --format json | jq '.nearfull_ratio,.backfillfull_ratio,.full_ratio'`）存檔供 rollback。
- inject + verify 交錯（階梯）：
  1. `ceph osd set-nearfull-ratio 0.02` → `wait_ceph_health_check OSD_NEARFULL` → `wait_prometheus_alert CephOSDNearFull ""` → `wait_sink_alert slack CephOSDNearFull` + `assert_sink_absent pager CephOSDNearFull`。
  2. `ceph osd set-backfillfull-ratio 0.022` → `wait_prometheus_alert CephOSDBackfillFull` → `wait_sink_alert pager CephOSDBackfillFull`。
  3. `ceph osd set-full-ratio 0.025` → `wait_ceph_health_check OSD_FULL` → `wait_prometheus_alert CephClientBlocked name OSD_FULL` → `wait_sink_alert pager CephClientBlocked name OSD_FULL` → `wait_sink_alert pager CephHealthError ""`（mixin 預設，HEALTH_ERR 5m）。
- rollback（反序還原 + 刪 pool）：`set-full-ratio 0.95` → `set-backfillfull-ratio 0.90` → `set-nearfull-ratio 0.85` → `pool_delete_command alert-capacity`。
- 各階梯的 for/傳遞：nearfull 10m、backfillfull 5m、HealthError 5m → 階段性 attempts 分別 ≥ 200/120/150。

### Task 18: S17 scenario-pool-quota

- setup：建 pool `alert-quota`（size 3）+ `ceph osd pool set-quota alert-quota max_bytes 33554432`（32MiB）。
- inject：`rados -p alert-quota bench 10 write -b 4194304 --no-cleanup` 寫到 ~28MiB（>80% quota；bench 秒數/塊數在腳本內以迴圈+df 檢查控制）。
- verify（1）：`wait_prometheus_alert CephPoolNearQuota name alert-quota`（for 10m → attempts 200）；`wait_sink_alert slack CephPoolNearQuota name alert-quota`。
- inject（2）：續寫超過 quota → `wait_ceph_health_check POOL_FULL` → `wait_prometheus_alert CephClientBlocked name POOL_FULL` → `wait_sink_alert pager CephClientBlocked name POOL_FULL`。
- rollback：刪 pool（quota 隨 pool 消失）。

### Task 19: S18 scenario-capacity-forecast

- setup：建 pool `alert-forecast`（size 3）。
- inject：背景 `nohup` 迴圈 `rados bench 60 write --no-cleanup` 連續 ~40 分鐘（迴圈次數上限 45；PID 檔記錄）。
- verify：`wait_prometheus_alert CephCapacityForecast "" ""`（for: 30m → `PROMETHEUS_WAIT_ATTEMPTS=540`）；`wait_sink_alert slack CephCapacityForecast "" ""`；`assert_sink_absent pager CephCapacityForecast "" ""`。
- rollback：kill bench 迴圈、刪 pool。
- README 註明 wall-clock ~45m、寫入量 ~數十 GiB（900GiB lab 安全）。

### Task 20: S19 scenario-data-damage

- setup：建 pool `alert-damage`（1 PG、size 3、min_size 2）、`rados put victim /etc/hosts`；`ceph osd map alert-damage victim --format json` 取 pgid 與 acting；選 acting 的**非 primary**（`.acting[1]`）。
- inject：stop 該 OSD → `sudo cephadm shell --name osd.N -- ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-N --pgid <pgid> victim remove`（`run_capture` 留證據）→ start 該 OSD → 等 `ceph pg <pgid> query` 出現（poll active）→ `ceph pg deep-scrub <pgid>`。
- verify：`wait_ceph_health_check OSD_SCRUB_ERRORS`（deep-scrub 排程延遲 → attempts 120）；`wait_prometheus_alert CephDataDamage "" ""`；`wait_sink_alert pager CephDataDamage "" ""`；`wait_sink_alert pager CephHealthError "" ""`（PG_DAMAGED = HEALTH_ERR）。
- rollback：`ceph pg repair <pgid>` → poll health 清除 OSD_SCRUB_ERRORS/PG_DAMAGED → 刪 pool。
- 安全備註（腳本頂部註解）：只碰測試 pool 的單一 object 副本；repair 方向天然正確（兩好一壞）。

### Task 21: S20 scenario-object-unfound

- setup：建 pool `alert-unfound`（1 PG、size 2、min_size 1）；`rados put victim /etc/hosts`；取 acting [A,B]（A=primary）。
- inject（determinstic unfound 流程，逐步 run_capture）：
  1. stop OSD A → poll osd down。
  2. `rados -p alert-unfound put victim /etc/os-release`（新版本只落在 B）。
  3. `ceph osd set norecover`（凍結 recovery，消除 race）。
  4. start OSD A → poll up。
  5. stop OSD B → poll down。
  6. `ceph osd unset norecover`。
- verify：`wait_ceph_health_check OBJECT_UNFOUND`；`wait_prometheus_alert CephObjectUnfound "" ""`；`wait_sink_alert pager CephObjectUnfound "" ""`。
- rollback：start OSD B → poll unfound 清除（`ceph health detail` 無 OBJECT_UNFOUND）→ 確認 `ceph osd dump | grep -c norecover` 為 0（防禦性 unset `|| true`）→ 刪 pool。
- fake ssh 覆蓋 6 步注入序列 + unfound health 輸出。

### Task 22: S21/S22 + 既有場景斷言擴充 + all.sh v2

**Files:** Create `run/scenario-mon-disk-low.sh` + test；Modify `run/baseline.sh`、`run/scenario-slow-ops.sh`、`run/scenario-pg-availability.sh`、`run/scenario-mon-quorum-lost.sh`、`run/all.sh`、`README.md` + 對應 tests。

- S21 scenario-mon-disk-low：
  - setup：`df --output=pcent /var/lib/ceph` on mon-01 → 算 free%（fake 測試回 `18%` used → free 82）。
  - inject（1）：`ceph config set mon mon_data_avail_warn <free+3>`（=85）→ `wait_ceph_health_check MON_DISK_LOW` → `wait_prometheus_alert CephMonDiskLow`（for 10m → attempts 200）→ `wait_sink_alert slack CephMonDiskLow` + `assert_sink_absent pager CephMonDiskLow`。
  - inject（2）：`ceph config set mon mon_data_avail_crit <free+1>`（=83）→ `wait_ceph_health_check MON_DISK_CRIT` → `wait_prometheus_alert CephMonDiskCritical` → `wait_sink_alert pager CephMonDiskCritical`。
  - rollback：`ceph config rm mon mon_data_avail_crit; ceph config rm mon mon_data_avail_warn`。
- S22 watchdog：`baseline.sh` 加一段：`record_sink_checkpoint` 後 `wait_sink_alert watchdog Watchdog "" ""`——部署後 watchdog 心跳必達。
- S1 slow-ops 擴充：verify 追加 `wait_prometheus_alert CephDaemonSlowOps ceph_daemon "osd.$id"` 與 `wait_sink_alert slack CephDaemonSlowOps ceph_daemon "osd.$id"`。
- S2 pg-availability 擴充：verify 追加 `wait_prometheus_alert CephPGUnhealthyStates name alert-pg-availability` 與 `wait_sink_alert pager CephPGUnhealthyStates name alert-pg-availability`。
- S3 mon-quorum-lost 擴充：verify 追加 `wait_alertmanager_inhibited CephMonDownScoped`（inhibit 真機證據）。
- all.sh v2 順序（附註解說明隔離原因）：baseline(+watchdog) → catch-all-risk → mon-disk-low → mon-clock-skew → mgr-failover → exporter-blind → osd-daemon-down → mon-down-single → osd-host-down → daemon-crash → osd-flapping → slow-ops → latency-outlier → net-slow-heartbeat → pg-availability → pool-quota → capacity-ladder → capacity-forecast → data-damage → object-unfound → low-priority-notice → mon-quorum-lost → cleanup。
- README：新場景一覽表（名稱、注入手法、預期 alert、wall-clock、特殊參數）。

---

## Phase 2 — 真機執行（orchestrator 直接控制，不派給背景 subagent）

- [ ] R1: `run/deploy-monitoring.sh` → `run/baseline.sh`（watchdog 證據）。
- [ ] R2: 依 all.sh v2 順序**逐一**執行場景（直接跑各 `run/scenario-*.sh --yes-really-inject`，不用 all.sh 一次跑完——每個場景之間人工檢視 result dir 與 `ceph -s`）。
- [ ] R3: 任一場景失敗 → 保留 result dir → 先確認叢集已回 HEALTH_OK → 派 fix subagent（附 result dir 證據）→ 修正（tierA/fake 測試先紅後綠）→ `deploy-monitoring.sh` 重佈 → 重跑該場景。
- [ ] R4: 全部通過後 `run/cleanup.sh`，`ceph -s` 確認 HEALTH_OK、`ceph osd dump | grep -E 'flags|ratio'` 確認 ratios/flags 還原、`ceph config dump | grep -E 'mon_data_avail|down_out'` 確認 config 清空、`ceph crash ls` 無未 archive。
- [ ] R5: 彙整每場景的證據（sink JSON 行、prometheus alerts JSON）到 `results/` 對應目錄，供 MDX 引用。

## Phase 3 — 文件與收尾

### Task 23: MDX 頁面

**Files:**
- Create: `next-site/content/ceph/features/prometheus-alert-production-coverage.mdx`
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`（互鏈 + 「接下來」）
- Modify: `next-site/content/ceph/features/prometheus-alert-testing.mdx`（tierA 新增測試段落 + 真機頁互鏈）
- Modify: `next-site/lib/projects.ts` / `next-site/content/ceph/feature-map.json`（新 slug 註冊，依 repo 既有模式）
- Modify: `next-site/content/ceph/quiz.json`（新頁 3-4 題，id 續號、answer 0-indexed）
- Modify: `experiments/ceph-alert-rules/lib/check-rules-match-page.sh`（coverage rules 的 invariants 指向新頁面；`for:` 對照表加入全部 coverage alerts）

新頁面結構（zh-TW，遵守 never-translate；緣起→來龍去脈→過程→結論的自包含報告體）：
1. 場景（工廠 0-downtime、掉 2 ping 要被問）
2. 故障模式分類表（spec 的 A-F 六類，含「現況→缺口→決定」）
3. 偵察發現：standby mgr 200+空 body 的全盲事故（附實測輸出）
4. 新 rules 全文（兩個 YAML 區塊，與 rules 檔逐字一致）
5. routing v2 + inhibit（label 導向的理由：alertname regex 會漂移）
6. 真機驗證證據表：每條 rule × 注入手法 × firing 證據（sink JSON 摘錄）× 回退
7. 邊界與取捨（RECENT_CRASH 降級理由、election metric 缺席、node-exporter/ceph-exporter future work、multi-target 短暫重疊的 count 語意、單機 AM）
8. 相關頁面互鏈

- [ ] Steps：寫頁面 → 註冊 slug → quiz → checker v2 → `bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh` PASS → `make validate` 綠 → commit `"Add Ceph production alert coverage page"`。

### Task 24: 最終 gate 與 push

- [ ] `bash experiments/ceph-alert-real-lab/tests/run-tests.sh` 全綠。
- [ ] `bash experiments/ceph-alert-rules/run/tierA.sh` + `tierB.sh` + `check-rules-match-page.sh` 全綠。
- [ ] `shellcheck -x` 兩個 experiment 的 lib/run/tests 全 0。
- [ ] `make validate` exit 0。
- [ ] `git log --oneline` 檢視 commit 序列 → push（`GIT_SSH_COMMAND=...`）。

## Self-Review 紀錄

- Spec 覆蓋：18 條新/改 rule ↔ S1-S22 場景一一對應（spec 總表 = Task 3 rules + Task 5-22 場景）；routing v2/inhibit/watchdog = Task 4；三處拷貝一致性 = Task 3 Step 5 + Task 23 checker v2；「lab render 讀共用 rules 檔」把三份拷貝減為兩份（頁面 + rules 檔）。
- 型別/名稱一致：`scenario_main`/`scenario_inject`/`scenario_rollback`/`scenario_verify`/`scenario_setup`、`assert_prometheus_alert_not_firing`、`assert_sink_absent`、`wait_alertmanager_inhibited`、`LAB_MGR_ENDPOINTS` 在各任務引用一致。
- 已知風險與緩解：(1) `ceph_daemon_health_metrics`/`pool_id` label 形狀 → Task 3 Step 0 先實測；(2) flapping 15m 窗跨場景污染 → all.sh 順序 + 不同目標 OSD；(3) S7 期間 QuorumLost 誤鳴為已文件化 trade-off → 註解記載不斷言；(4) netem/ratio 類注入 → 預武裝回退 + 反序還原。
