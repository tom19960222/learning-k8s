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

cleanup_side_effects() {  # TERM/EXIT 兜底：清掉所有持久副作用（冪等）
  unblock_ntp || true
  ntp_counter_del || true
  [[ -n "${CLIENT_IFACE:-}" ]] && tc qdisc del dev "$CLIENT_IFACE" root 2>/dev/null || true
  set_poll_max default || true
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
  wait_synced 50 600 || { log "ERROR: baseline 收斂失敗，中止此情境（環境異常，請檢查 server）"; return 1; }
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
      soak "$outdir" "$((HOURS * 3600))" \
        || { log "WARN: scenario $name 中止，未寫 verdict（重跑會自動重試）"; return 0; } ;;
    soak-256)
      set_poll_max 256
      soak "$outdir" "$((HOURS * 3600))" \
        || { log "WARN: scenario $name 中止，未寫 verdict（重跑會自動重試）"; return 0; } ;;
    restart)
      set_poll_max 256
      soak "$outdir" "$((HOURS * 3600))" action_restart \
        || { log "WARN: scenario $name 中止，未寫 verdict（重跑會自動重試）"; return 0; } ;;
    outage-30m)
      set_poll_max 256
      soak "$outdir" "$((HOURS * 3600))" action_outage \
        || { log "WARN: scenario $name 中止，未寫 verdict（重跑會自動重試）"; return 0; } ;;
    inject-80ms)
      local poll sub t0 warm
      for poll in 256 2048; do
        sub="$outdir/poll-$poll"
        mkdir -p "$sub"
        if [[ "$poll" == 2048 ]]; then set_poll_max default; else set_poll_max 256; fi
        trap 'stop_monitors "$sub"; set_poll_max default' RETURN
        wait_synced 50 600 || { log "WARN: scenario $name 中止，未寫 verdict（重跑會自動重試）"; return 0; }
        start_monitors "$sub"
        warm=600
        [[ "$poll" == 2048 ]] && warm=2400  # 32→2048 的 poll 倍增需 ~2016s，2400s 保證注入時已在 max poll
        sleep "$warm"
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
      soak "$outdir" 3600 \
        || { log "WARN: scenario $name 中止，未寫 verdict（重跑會自動重試）"; return 0; }
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
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（exp4 的 jitter/tc 需要）"
    trap cleanup_side_effects EXIT INT TERM
    preflight; mkdir -p "$EXP_DIR"
    for s in "${SCENARIOS[@]}"; do run_scenario "$s"; done
    log "exp4 全部完成；各情境 verdict 在 $EXP_DIR/*/verdict.md" ;;
  --scenario)
    name="$2"; shift 2
    [[ "${1:-}" == "--hours" ]] && { HOURS="$2"; shift 2; }
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（exp4 的 jitter/tc 需要）"
    trap cleanup_side_effects EXIT INT TERM
    preflight; mkdir -p "$EXP_DIR"
    run_scenario "$name" ;;
  *)
    die "用法見檔頭註解（--all / --scenario 名稱 / --status / --detach）" ;;
esac
