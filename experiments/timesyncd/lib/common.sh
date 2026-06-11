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
  : "${CLIENT_IFACE:=}"
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
  local off
  # 容差 1ms：exp2 靠 399/401ms 的 1ms 邊際設計，殘留 4ms 就會把 slew 推成 step（L3 實測教訓）
  for _ in 1 2 3 4 5 6 7 8; do
    off="$(ntp_offset_ms)" || { log "ERROR reset_clock_state: 量不到 server offset"; return 1; }
    # off = server - client；把 client 撥 +off 就對齊 server
    if $PY -c "import sys; sys.exit(0 if abs(float('$off')) < 1 else 1)"; then
      log "reset_clock_state 完成（|offset| = ${off}ms < 1ms）"
      return 0
    fi
    $PY "$LIB_DIR/clock_inject.py" set-offset --ms "$off"
    sleep 1
  done
  log "ERROR reset_clock_state: 8 次校正後仍未進 1ms（最後 offset=${off}ms）"; return 1
}

# ---------- 背景監視器 ----------
start_probe() {  # $1 = csv 路徑；pid 落同目錄 probe.pid
  $PY "$LIB_DIR/ntp_probe.py" run --server "$SERVER_IP" --port "$NTP_PORT" --csv "$1" &
  echo $! > "$(dirname "$1")/probe.pid"
}
stop_probe() {  # $1 = csv 路徑；冪等且永遠回 0（會在 trap 內被二次呼叫，回 1 會引爆 set -e）
  local pidfile; pidfile="$(dirname "$1")/probe.pid"
  [[ -f "$pidfile" ]] || return 0
  kill "$(cat "$pidfile")" 2>/dev/null || true
  rm -f "$pidfile"
}
start_step_detector() {  # $1 = csv
  $PY "$LIB_DIR/step_detector.py" --csv "$1" &
  echo $! > "$(dirname "$1")/steps.pid"
}
stop_step_detector() {  # 同 stop_probe：冪等、永遠回 0
  local pidfile; pidfile="$(dirname "$1")/steps.pid"
  [[ -f "$pidfile" ]] || return 0
  kill "$(cat "$pidfile")" 2>/dev/null || true
  rm -f "$pidfile"
}

# ---------- 注入 ----------
inject_ppm() {  # $1 = ppm（整數；可 0；±100 倍數走 tick，其餘走 freq）
  local ppm=$1
  [[ "$ppm" == 0 ]] && return 0
  if (( ppm % 100 == 0 )); then
    $PY "$LIB_DIR/clock_inject.py" set-tick --ppm "$ppm"
  else
    $PY "$LIB_DIR/clock_inject.py" set-freq --ppm "$ppm"
  fi
}

# ---------- 收斂等待 ----------
wait_convergence() {  # $1=probe.csv $2=t0_raw $3=timeout_s [$4=hold_s 預設60]；stdout=analyze JSON；rc 0/3
  local csv=$1 t0=$2 timeout=$3 hold=${4:-60} t_start elapsed out rc
  t_start=$(raw_now)
  while true; do
    sleep 15
    set +e
    out="$($PY "$LIB_DIR/analyze.py" convergence --csv "$csv" --t0-raw "$t0" --hold-s "$hold" 2>/dev/null)"
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
  local thr=${1:-5} max=${2:-300} off
  systemctl start systemd-timesyncd
  for _ in $(seq 1 $((max / 5))); do
    sleep 5
    off="$(ntp_offset_ms)" || continue
    if $PY -c "import sys; sys.exit(0 if abs(float('$off')) < $thr else 1)"; then
      log "已收斂（offset=${off}ms < ${thr}ms）"
      return 0
    fi
  done
  log "ERROR wait_synced: ${max}s 內未收斂到 ${thr}ms"
  return 1
}

# ---------- exp1/exp2 共用：單一 recovery cell ----------
# run_recovery_cell <outdir> <offset_ms> <ppm> <timeout_s> [hold_s 預設60]
# hold_s 拉長 = 收斂後的穩定窗（exp1 用 660：超過 MAXFREQ 的 cell 在 poll 爬升後鋸齒破界，
# 60s hold 會被 32s poll 下 < 50ms 的鋸齒騙過——L4 實測教訓）
# 需要時 export WITH_STEP_DETECTOR=1。產出 outdir/{probe.csv,convergence.json,result.json}
run_recovery_cell() {
  local outdir=$1 offset_ms=$2 ppm=$3 timeout_s=$4 hold_s=${5:-60} rc=0 t0
  mkdir -p "$outdir"
  # trap：不管成功失敗都復原（恢復連線、清暫存器、停監視器）
  trap 'stop_probe "$outdir/probe.csv"; [[ "${WITH_STEP_DETECTOR:-0}" == 1 ]] && stop_step_detector "$outdir/steps.csv"; reset_clock_state || log "WARN: cell 清理時 reset 失敗，續跑下一 cell"' RETURN
  reset_clock_state || { log "ERROR: cell 前置 reset 失敗，略過此 cell"; return 4; }
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
  wait_convergence "$outdir/probe.csv" "$t0" "$timeout_s" "$hold_s" > "$outdir/convergence.json"
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
