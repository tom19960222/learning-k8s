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
  trap 'stop_probe "$outdir/probe.csv"; reset_clock_state || log "WARN: cell 清理時 reset 失敗，續跑下一 cell"' RETURN
  reset_clock_state || { log "ERROR: cell 前置 reset 失敗，略過此 cell"; return 0; }
  wait_synced 5 300 || { log "ERROR: cell baseline 收斂失敗，略過此 cell"; return 0; }
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
  # systemd 249（22.04）寫 "Initial synchronization to time server"，v250+ 改 "Contacted time server"
  contact_mono="$(grep -E 'Contacted time server|Initial synchronization to time server' "$outdir/journal.txt" \
    | head -1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')"
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
  # 注意：這裡不能寫 [[ ... ]] && log（rc=0 時整串回 1 = 函式回傳值 → 炸掉呼叫端 set -e）
  if [[ $rc -eq 3 ]]; then
    log "警告：${ms}ms 未在 ${TIMEOUT_S}s 內收斂，違反預測"
  fi
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
    systemctl start systemd-timesyncd 2>/dev/null || true   # 收尾：別讓 timesyncd 停著
    log "exp3 全部完成 → $EXP_DIR" ;;
  --offset-ms)
    require_root; preflight; mkdir -p "$EXP_DIR"
    run_cell "$2"
    systemctl start systemd-timesyncd 2>/dev/null || true ;;
  *)
    die "用法見檔頭註解（--all / --offset-ms N / --status / --detach）" ;;
esac
