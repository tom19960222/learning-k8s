#!/usr/bin/env bash
# lib/common.sh — shared helpers for slow-ops detection scenarios.
# bash 3.2 compatible; stdout is reserved for machine-readable verdict lines,
# everything else goes to stderr.

set -u

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$(dirname "${LIB_DIR}")"
REPO_ROOT="$(cd "${EXP_DIR}/../.." && pwd)"

SSH_KEY="${REPO_ROOT}/.ssh/id_ed25519"
ADMIN_HOST="192.168.18.166"
PROM_URL="http://192.168.18.166:9095"
FSID="0c9bf37e-514a-11f1-b72a-bc24113f1375"
BENCH_POOL="slowops-bench"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

lab_ssh() {
  local host="$1"
  shift
  ssh -i "${SSH_KEY}" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o ConnectTimeout=10 -o BatchMode=yes "ikaros@${host}" "$@"
}

# Run a ceph CLI command on the admin node. Args are passed as one remote
# command string; caller is responsible for quoting.
ceph_admin() { lab_ssh "${ADMIN_HOST}" "sudo $*"; }

remote_epoch() { lab_ssh "$1" 'date +%s'; }

# --- Prometheus -------------------------------------------------------------

# prom_range QUERY START END STEP OUTFILE — dump query_range JSON.
prom_range() {
  local query="$1" start="$2" end="$3" step="$4" out="$5"
  curl -sG -m 20 "${PROM_URL}/api/v1/query_range" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" \
    --data-urlencode "step=${step}" > "${out}" \
    || die "prom_range failed: ${query}"
}

# prom_instant QUERY OUTFILE
prom_instant() {
  local query="$1" out="$2"
  curl -sG -m 20 "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=${query}" > "${out}" \
    || die "prom_instant failed: ${query}"
}

pj() { python3 "${LIB_DIR}/promjson.py" "$@"; }

# max_or_zero FILE — pj max, but an absent series reads as 0 ("signal never
# appeared" must count as a pass for never-appears predictions).
max_or_zero() {
  local v
  v=$(pj max "$1")
  [ "${v}" = "none" ] && v=0
  printf '%s' "${v}"
}

# R2 expression (must stay identical to rules/ceph-slow-ops-fast.yml)
r2_expr() {
  printf 'count by (instance) (%s > 0)' "$(slow_sum_expr 2m)"
}

# collect_std START END — dump the standard signal set for the window.
collect_std() {
  local s="$1" e="$2"
  prom_range "$(slow_raw_expr)" "${s}" "${e}" 5 "${BUNDLE}/raw-slow-counters.json"
  prom_range "$(slow_raw_expr ',ceph_daemon="osd.0"')" "${s}" "${e}" 5 "${BUNDLE}/raw-slow-osd0.json"
  prom_range "$(slow_sum_expr 1m)" "${s}" "${e}" 5 "${BUNDLE}/r1-all.json"
  prom_range "$(slow_sum_expr 1m '{ceph_daemon="osd.0"}')" "${s}" "${e}" 5 "${BUNDLE}/r1-osd0.json"
  prom_range "$(r2_expr)" "${s}" "${e}" 5 "${BUNDLE}/r2.json"
  prom_range 'ceph_daemon_health_metrics{type="SLOW_OPS"}' "${s}" "${e}" 5 "${BUNDLE}/slowops-daemon.json"
  prom_range 'ceph_health_detail{name="SLOW_OPS"}' "${s}" "${e}" 5 "${BUNDLE}/slowops-health.json"
  prom_range 'ceph_health_detail{name="BLUESTORE_SLOW_OP_ALERT"}' "${s}" "${e}" 5 "${BUNDLE}/bluestore-alert.json"
  prom_range 'ceph_osd_commit_latency_ms{ceph_daemon="osd.0"}' "${s}" "${e}" 5 "${BUNDLE}/commit-latency-osd0.json"
  prom_range 'rate(ceph_osd_op_w_latency_sum{ceph_daemon="osd.0"}[1m]) / rate(ceph_osd_op_w_latency_count{ceph_daemon="osd.0"}[1m])' \
    "${s}" "${e}" 5 "${BUNDLE}/opw-mean-osd0.json"
  prom_range 'rate(node_disk_io_time_weighted_seconds_total{instance="ceph-lab-osd-01"}[1m])' \
    "${s}" "${e}" 5 "${BUNDLE}/node-disk-osd01.json"
}

SLOW_NAME_RE='__name__=~"ceph_bluestore_slow_(aio_wait|committed_kv|read_onode_meta|read_wait_aio)_count"'

# PromQL: per-OSD sum of the 4 BlueStore slow counters' increase — must stay
# structurally identical to R1 in rules/ceph-slow-ops-fast.yml：顯式 4 項相加。
# 不能用 __name__ regex + increase：increase 丟 __name__ 後同 OSD 的 4 個 counter
# 變成重複 labelset，真 Prometheus 回錯（E-00 實測）。inner-join 在此安全：4 個
# counter 由同一次 exporter scrape 原子性產生。
# $1 = range (e.g. 1m), $2 = 完整 label matcher 含大括號（e.g. '{ceph_daemon="osd.0"}'）
slow_sum_expr() {
  local win="$1" m="${2:-}"
  printf 'sum by (ceph_daemon, instance) (increase(ceph_bluestore_slow_aio_wait_count%s[%s]) + increase(ceph_bluestore_slow_committed_kv_count%s[%s]) + increase(ceph_bluestore_slow_read_onode_meta_count%s[%s]) + increase(ceph_bluestore_slow_read_wait_aio_count%s[%s]))' \
    "${m}" "${win}" "${m}" "${win}" "${m}" "${win}" "${m}" "${win}"
}

# PromQL: raw (non-rate) per-OSD sum of the 4 slow counters, for before/after
# delta checks. 這裡 regex 選擇器安全（沒有 increase、__name__ 保留到聚合前，
# sum 聚合重複 labelset 是合法操作）。$1 = extra matcher incl. leading comma.
slow_raw_expr() {
  printf 'sum by (ceph_daemon) ({%s%s})' "${SLOW_NAME_RE}" "${1:-}"
}

# --- Bundle -----------------------------------------------------------------

BUNDLE=""
VERDICT_FILE=""
SCENARIO_NAME=""
SCENARIO_FAILED=0

bundle_init() {
  SCENARIO_NAME="$1"
  BUNDLE="${EXP_DIR}/results/$(date +%Y%m%d-%H%M%S)-${SCENARIO_NAME}"
  mkdir -p "${BUNDLE}"
  VERDICT_FILE="${BUNDLE}/verdict.txt"
  : > "${VERDICT_FILE}"
  log "bundle: ${BUNDLE}"
}

bundle_note() { printf '%s\n' "$*" >> "${BUNDLE}/notes.txt"; }

# record clock offsets of lab hosts vs admin host (evidence for timing claims)
bundle_clock_skew() {
  local host t_admin t_host
  for host in "$@"; do
    t_admin=$(remote_epoch "${ADMIN_HOST}")
    t_host=$(remote_epoch "${host}")
    printf '%s admin=%s host=%s skew=%s\n' \
      "${host}" "${t_admin}" "${t_host}" "$((t_host - t_admin))" \
      >> "${BUNDLE}/clock-skew.txt"
  done
}

# --- Verdict ----------------------------------------------------------------
# Each prediction check appends PASS/FAIL; scenario verdict is confirmed only
# if every check passed. Comparison is scripted (no eyeballing).

check() {
  # check LABEL OP A B  — OP in: ge le eq ne lt gt
  local label="$1" op="$2" a="$3" b="$4" ok=1
  # pj 失敗時可能回空字串——視同 none，記 FAIL 而不是讓 python 崩潰
  [ -z "${a}" ] && a=none
  [ -z "${b}" ] && b=none
  if [ "${a}" = "none" ] || [ "${b}" = "none" ]; then
    ok=0
    [ "${op}" = "eq" ] && [ "${a}" = "${b}" ] && ok=1
    [ "${op}" = "ne" ] && [ "${a}" != "${b}" ] && ok=1
  else
    case "${op}" in
      ge) ok=$(python3 -c "print(1 if float('${a}') >= float('${b}') else 0)") ;;
      le) ok=$(python3 -c "print(1 if float('${a}') <= float('${b}') else 0)") ;;
      gt) ok=$(python3 -c "print(1 if float('${a}') >  float('${b}') else 0)") ;;
      lt) ok=$(python3 -c "print(1 if float('${a}') <  float('${b}') else 0)") ;;
      eq) ok=$(python3 -c "print(1 if float('${a}') == float('${b}') else 0)") ;;
      ne) ok=$(python3 -c "print(1 if float('${a}') != float('${b}') else 0)") ;;
      *) die "check: bad op ${op}" ;;
    esac
  fi
  if [ "${ok}" = "1" ]; then
    printf 'PASS %s: %s %s %s\n' "${label}" "${a}" "${op}" "${b}" >> "${VERDICT_FILE}"
    log "PASS ${label}: ${a} ${op} ${b}"
  else
    printf 'FAIL %s: %s %s %s\n' "${label}" "${a}" "${op}" "${b}" >> "${VERDICT_FILE}"
    log "FAIL ${label}: ${a} ${op} ${b}"
    SCENARIO_FAILED=1
  fi
}

emit_verdict() {
  local v="confirmed"
  [ "${SCENARIO_FAILED}" = "1" ] && v="violated"
  printf '%s\n' "${v}" > "${BUNDLE}/VERDICT"
  # the one machine-readable stdout line:
  printf 'VERDICT %s %s\n' "${SCENARIO_NAME}" "${v}"
}

# --- Cluster state helpers ---------------------------------------------------

# pre_check [exempt_regex] — abort unless cluster is healthy (or only carries
# health codes matching exempt_regex, e.g. the latched BLUESTORE_SLOW_OP_ALERT).
pre_check() {
  local exempt="${1:-^\$}" status detail
  status=$(ceph_admin ceph health | head -1)
  if printf '%s' "${status}" | grep -q HEALTH_OK; then
    log "pre-check: HEALTH_OK"
  else
    detail=$(ceph_admin ceph health detail | grep '^\[' | grep -Ev "${exempt}" || true)
    if [ -n "${detail}" ]; then
      log "pre-check failed, non-exempt health issues:"
      printf '%s\n' "${detail}" >&2
      die "cluster not healthy"
    fi
    log "pre-check: WARN but all codes exempt (${exempt})"
  fi
  local up
  up=$(ceph_admin ceph osd stat | grep -o '[0-9]* up' | grep -o '[0-9]*')
  [ "${up}" = "9" ] || die "expected 9 osds up, got ${up}"
}

baseline_capture() {
  ceph_admin ceph -s > "${BUNDLE}/baseline-ceph-s.txt" 2>&1
  ceph_admin ceph health detail > "${BUNDLE}/baseline-health-detail.txt" 2>&1
  prom_instant "$(slow_raw_expr)" "${BUNDLE}/baseline-slow-counters.json"
}

# assert_health [exempt_regex] — post-rollback health assertion.
assert_health() {
  local exempt="${1:-^\$}" tries=0 detail
  while [ "${tries}" -lt 30 ]; do
    if ceph_admin ceph health | grep -q HEALTH_OK; then
      log "assert: HEALTH_OK"
      return 0
    fi
    detail=$(ceph_admin ceph health detail | grep '^\[' | grep -Ev "${exempt}" || true)
    if [ -z "${detail}" ]; then
      log "assert: WARN but all codes exempt"
      return 0
    fi
    tries=$((tries + 1))
    sleep 10
  done
  ceph_admin ceph health detail >&2
  die "assert_health: cluster did not return to baseline"
}

# --- OSD device / process helpers -------------------------------------------

# osd_dm HOST OSDID → prints /dev/dm-N
osd_dm() {
  lab_ssh "$1" "sudo readlink -f /var/lib/ceph/${FSID}/osd.$2/block"
}

# osd_pid HOST OSDID → real ceph-osd pid (not conmon / podman-init)
osd_pid() {
  lab_ssh "$1" "pgrep -f '^/usr/bin/ceph-osd -n osd.$2 ' | head -1"
}

# dm_state HOST DEV → ACTIVE | SUSPENDED
dm_state() {
  lab_ssh "$1" "sudo dmsetup info $2 | awk '/^State/ {print \$2}'"
}

# ensure_dm_active HOST DEV — rollback helper, idempotent, verified by state.
ensure_dm_active() {
  local host="$1" dev="$2" state
  state=$(dm_state "${host}" "${dev}")
  if [ "${state}" != "ACTIVE" ]; then
    lab_ssh "${host}" "sudo dmsetup resume ${dev}"
  fi
  state=$(dm_state "${host}" "${dev}")
  [ "${state}" = "ACTIVE" ] || die "rollback failed: ${dev} on ${host} is ${state}"
  log "rollback verified: ${dev} ACTIVE"
}

# osd_cgroup_path OSDID → systemd service cgroup dir for the osd (on osd host)
osd_cgroup() {
  printf '/sys/fs/cgroup/system.slice/system-ceph\\x2d%s.slice/ceph-%s@osd.%s.service' \
    "$(printf '%s' "${FSID}" | sed 's/-/\\x2d/g')" "${FSID}" "$1"
}

# io_max_set HOST OSDID MAJMIN SPEC — SPEC like "wiops=8" or "max".
# The cgroup path contains literal backslashes (systemd \x2d escapes), so it
# must be single-quoted in the remote command or the remote shell eats them.
io_max_set() {
  local host="$1" osd="$2" majmin="$3" spec="$4" cg
  cg=$(osd_cgroup "${osd}")
  lab_ssh "${host}" "printf '%s %s\n' '${majmin}' '${spec}' | sudo tee '${cg}/io.max' >/dev/null"
}

io_max_get() {
  local host="$1" osd="$2" cg
  cg=$(osd_cgroup "${osd}")
  lab_ssh "${host}" "sudo cat '${cg}/io.max'"
}

# ensure_io_unlimited HOST OSDID MAJMIN — rollback helper, verified by state.
ensure_io_unlimited() {
  local host="$1" osd="$2" majmin="$3" cur
  io_max_set "${host}" "${osd}" "${majmin}" "max" || true
  cur=$(io_max_get "${host}" "${osd}")
  if printf '%s' "${cur}" | grep -q "${majmin}"; then
    die "rollback failed: io.max still limited: ${cur}"
  fi
  log "rollback verified: io.max unlimited"
}

# --- Bench pool --------------------------------------------------------------

ensure_bench_pool() {
  if ! ceph_admin ceph osd pool ls | grep -qx "${BENCH_POOL}"; then
    ceph_admin ceph osd pool create "${BENCH_POOL}" 32 32 >&2
    ceph_admin ceph osd pool application enable "${BENCH_POOL}" rbd >&2
  fi
}

# bench_write SECONDS THREADS [SIZE] — background rados bench on admin host.
# Data kept (--no-cleanup) so seq reads can follow. SIZE defaults to 1M:
# E-00 showed this lab's virtio disks hit 44s max latency under 16×4MB load
# with NO injection — 4M objects would contaminate injection attribution.
bench_write() {
  local size="${3:-1M}"
  lab_ssh "${ADMIN_HOST}" \
    "nohup sudo rados bench -p ${BENCH_POOL} $1 write -b ${size} -t $2 --no-cleanup >/tmp/bench-write.log 2>&1 &" \
    </dev/null
}

bench_seq() {
  lab_ssh "${ADMIN_HOST}" \
    "nohup sudo rados bench -p ${BENCH_POOL} $1 seq -t $2 >/tmp/bench-seq.log 2>&1 &" \
    </dev/null
}

# NOTE: must be pgrep -x (exact process name). A remote `pgrep -f "rados
# bench"` matches the very shell that wraps the pgrep call (its cmdline
# contains the pattern) — the wait never terminates.
bench_wait_done() {
  local tries=0
  while lab_ssh "${ADMIN_HOST}" 'pgrep -x rados >/dev/null'; do
    tries=$((tries + 1))
    [ "${tries}" -gt 120 ] && die "rados bench did not finish"
    sleep 5
  done
}

bench_collect_logs() {
  lab_ssh "${ADMIN_HOST}" 'cat /tmp/bench-write.log 2>/dev/null' > "${BUNDLE}/bench-write.log" || true
  lab_ssh "${ADMIN_HOST}" 'cat /tmp/bench-seq.log 2>/dev/null' > "${BUNDLE}/bench-seq.log" || true
}
