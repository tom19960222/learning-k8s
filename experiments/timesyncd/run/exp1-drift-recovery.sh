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
  if [[ $rc -eq 4 ]]; then
    log "cell ${d}h × ${p}ppm 前置 reset 失敗，未寫 result（下次重跑會自動重試）"
    return 0
  fi
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
