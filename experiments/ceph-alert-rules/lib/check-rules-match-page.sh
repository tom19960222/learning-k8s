#!/usr/bin/env bash
# 防漂移 guard：被測 rules（rules/*.yml）的 load-bearing expr 必須與設計頁逐字一致。
# 任一 invariant 在「頁面」或「抽出的 rules」缺失即 FAIL——提醒兩邊重新同步。
# spec §6（source-first）：頁面是 single source of truth，測的就是它。
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PAGE="$ROOT/next-site/content/ceph/features/prometheus-alert-design.mdx"
RULES_DIR="$ROOT/experiments/ceph-alert-rules/rules"

[ -f "$PAGE" ] || { echo "FATAL: page not found: $PAGE"; exit 2; }

# load-bearing invariants（出現在頁面 YAML 與 rules 兩邊）
invariants=(
  'ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS"} == 1'
  'PG_AVAILABILITY|SLOW_OPS|OSD_DOWN|OSD_HOST_DOWN|MON_DOWN|HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSD_FLAGS|OSDMAP_FLAGS'
  '(count(ceph_mon_quorum_status == 1) or vector(0)) < 2'
  'up{job="ceph"} == 0'
  'HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSD_FLAGS|OSDMAP_FLAGS'
  'group_left(hostname) ceph_osd_metadata'
  'count by (hostname) (ceph:osd_up:with_hostname == 0)'
  'unless on (hostname) ceph:osd_host_down:scoped'
  '(1 - ceph_mon_quorum_status)'
  'group_left(hostname) ceph_mon_metadata'
  'alertname=~"CephClientBlocked|CephClientRisk|CephMonQuorumLost|CephExporterDown|CephOSDHostDownScoped|CephOSDDaemonDownScoped|CephMonDownScoped|CephMonQuorumLostExternal"'
)

rules_blob="$(cat "$RULES_DIR"/*.yml)"
fail=0
for inv in "${invariants[@]}"; do
  in_page=0; in_rules=0
  grep -qF -- "$inv" "$PAGE" && in_page=1
  printf '%s' "$rules_blob" | grep -qF -- "$inv" && in_rules=1
  if [ "$in_page" = 1 ] && [ "$in_rules" = 1 ]; then
    printf 'ok    %s\n' "${inv:0:60}"
  else
    printf 'FAIL  page=%s rules=%s :: %s\n' "$in_page" "$in_rules" "$inv"; fail=1
  fi
done

# 進一步檢查 for: 時長漂移（Analyzer I1）：抽每條 alert 的 for: 值，頁面與 rules 須一致
for_check="$(python3 - "$PAGE" "$RULES_DIR/ceph-stability-first.yml" "$RULES_DIR/ceph-scoped-availability.yml" <<'PY'
import re, sys
page, *rulefiles = sys.argv[1:]

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

page_for = extract(open(page).read())
rules_for = {}
for rf in rulefiles:
    rules_for.update(extract(open(rf).read()))

# 只比對「應同時出現在頁面與 rules」的 8 條 alert
of_interest = ['CephClientBlocked','CephClientRisk','CephMonQuorumLost','CephExporterDown',
               'CephLowPriorityNotice','CephOSDHostDownScoped','CephOSDDaemonDownScoped','CephMonDownScoped']
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
