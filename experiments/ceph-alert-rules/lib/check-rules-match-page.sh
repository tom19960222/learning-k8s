#!/usr/bin/env bash
# 防漂移 guard：被測 rules（rules/*.yml）的 load-bearing expr 必須與設計頁逐字一致。
# 任一 invariant 在「頁面」或「抽出的 rules」缺失即 FAIL——提醒兩邊重新同步。
# spec §6（source-first）：頁面是 single source of truth，測的就是它。
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
DESIGN_PAGE="$ROOT/next-site/content/ceph/features/ceph-alert-policy-current.mdx"
FINDINGS_PAGE="$ROOT/next-site/content/ceph/features/ceph-alert-policy-current.mdx"
RULES_DIR="$ROOT/experiments/ceph-alert-rules/rules"

[ -f "$DESIGN_PAGE" ] || { echo "FATAL: page not found: $DESIGN_PAGE"; exit 2; }
[ -f "$FINDINGS_PAGE" ] || { echo "FATAL: page not found: $FINDINGS_PAGE"; exit 2; }

# load-bearing invariants（出現在頁面 YAML 與 rules 兩邊）
invariants=(
  'ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL"} == 1'
  'PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL|OSD_DOWN|OSD_HOST_DOWN|MON_DOWN|HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSD_FLAGS|OSDMAP_FLAGS|POOL_APP_NOT_ENABLED|POOL_NEARFULL|OSD_SLOW_PING_TIME_BACK|OSD_SLOW_PING_TIME_FRONT|MON_CLOCK_SKEW|RECENT_CRASH|OSD_NEARFULL|OSD_BACKFILLFULL|MON_DISK_LOW|MON_DISK_CRIT|PG_DAMAGED|OSD_SCRUB_ERRORS|OBJECT_UNFOUND'
  '(count(ceph_mon_quorum_status == 1) or vector(0)) < 2'
  '(count(up{job="ceph"} == 1) or vector(0)) == 0'
  'up{job="ceph"} == 0'
  'HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSD_FLAGS|OSDMAP_FLAGS|POOL_APP_NOT_ENABLED|POOL_NEARFULL'
  'group_left(hostname) ceph_osd_metadata'
  'count by (hostname) (ceph:osd_up:with_hostname == 0)'
  'unless on (hostname) ceph:osd_host_down:scoped'
  '(1 - ceph_mon_quorum_status)'
  'group_left(hostname) ceph_mon_metadata'
  'source=~"ceph_stability|ceph_scoped|ceph_coverage|ceph_external"'
  'absent(ceph_health_status)'
  'vector(1)'
  'ceph_health_detail{name=~"OSD_SLOW_PING_TIME_BACK|OSD_SLOW_PING_TIME_FRONT"} == 1'
  'changes(ceph_osd_up[15m])'
  'ceph_osd_commit_latency_ms > 3 * scalar(quantile(0.5, ceph_osd_commit_latency_ms))'
  'max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m]) > 0'
  '(count(ceph_mgr_status) or vector(0)) < 2'
  'ceph_pool_bytes_used > 0.8 * ceph_pool_quota_bytes'
  'predict_linear(ceph_cluster_total_used_bytes[1h], 259200)'
  'max_over_time(ceph_health_detail{name=~"PG_DAMAGED|OSD_SCRUB_ERRORS"}[5m]) > 0'
  'max_over_time(ceph_health_detail{name="OBJECT_UNFOUND"}[5m]) > 0'
  'ceph_pg_down + ceph_pg_incomplete + ceph_pg_unknown + ceph_pg_stale + ceph_pg_peered'
)

rules_blob="$(cat "$RULES_DIR"/*.yml)"
pages_blob="$(cat "$DESIGN_PAGE" "$FINDINGS_PAGE")"
fail=0
for inv in "${invariants[@]}"; do
  in_page=0; in_rules=0
  grep -qF -- "$inv" <<<"$pages_blob" && in_page=1
  grep -qF -- "$inv" <<<"$rules_blob" && in_rules=1
  if [ "$in_page" = 1 ] && [ "$in_rules" = 1 ]; then
    printf 'ok    %s\n' "${inv:0:60}"
  else
    printf 'FAIL  page=%s rules=%s :: %s\n' "$in_page" "$in_rules" "$inv"; fail=1
  fi
done

# 進一步檢查 for: 時長漂移（Analyzer I1）：抽每條 alert 的 for: 值，頁面與 rules 須一致
for_check="$(python3 - "$DESIGN_PAGE" "$FINDINGS_PAGE" "$RULES_DIR/ceph-stability-first.yml" "$RULES_DIR/ceph-scoped-availability.yml" "$RULES_DIR/ceph-production-coverage.yml" <<'PY'
import re, sys
pagefiles = sys.argv[1:3]
rulefiles = sys.argv[3:]

def extract(text):
    m = {}
    name = None
    for line in text.splitlines():
        am = re.search(r'-?\s*alert:\s*"?([A-Za-z0-9_]+)"?', line)
        if am:
            name = am.group(1); continue
        fm = re.search(r'^\s*for:\s*"?([0-9a-z]+)"?', line)
        if fm and name:
            m.setdefault(name, fm.group(1))
    return m

page_for = {}
for page in pagefiles:
    page_for.update(extract(open(page).read()))
rules_for = {}
for rf in rulefiles:
    rules_for.update(extract(open(rf).read()))

# 只比對「應同時出現在頁面與 rules，且有 for:」的 alert
of_interest = [
    'CephClientBlocked','CephClientRisk','CephMonQuorumLost',
    'CephExporterAllDown','CephExporterTargetDown','CephLowPriorityNotice',
    'CephOSDHostDownScoped','CephOSDDaemonDownScoped','CephMonDownScoped',
    'CephMetricsAbsent','CephOSDSlowHeartbeat','CephMonClockSkew',
    'CephOSDLatencyOutlier','CephDaemonSlowOps','CephDaemonRecentCrash',
    'CephMgrNoStandby','CephOSDNearFull','CephOSDBackfillFull',
    'CephMonDiskLow','CephMonDiskCritical','CephPoolNearQuota',
    'CephCapacityForecast','CephDataDamage','CephObjectUnfound',
    'CephPGUnhealthyStates',
]
bad = 0
for n in of_interest:
    pv, rv = page_for.get(n), rules_for.get(n)
    if pv is None or rv is None or pv != rv:
        print(f"FORFAIL {n}: page={pv} rules={rv}"); bad = 1
    else:
        print(f"forok {n}={rv}")
sys.exit(bad)
PY
)"
for_rc=$?
echo "$for_check"
[ "$for_rc" != 0 ] && fail=1

if [ "$fail" = 0 ]; then echo "rules match page (exprs + for: durations consistent both sides)"; fi
exit $fail
