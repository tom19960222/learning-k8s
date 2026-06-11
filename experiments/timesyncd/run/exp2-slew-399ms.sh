#!/usr/bin/env bash
# exp2-slew-399ms.sh — NTP_MAX_ADJUST(0.4s) 門檻兩側 1ms 的對照實驗。
# 用法：sudo ./exp2-slew-399ms.sh [--detach] ；./exp2-slew-399ms.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

EXP_DIR="$RESULTS_DIR/exp2"
TIMEOUT_S=600

case "${1:-}" in
  --status)
    systemctl status tsexp-exp2 --no-pager 2>/dev/null || true
    for c in 399 401; do
      [[ -f "$EXP_DIR/cell-${c}ms/result.json" ]] && { echo "--- ${c}ms ---"; cat "$EXP_DIR/cell-${c}ms/result.json"; } || true
    done
    exit 0 ;;
  --detach)
    require_root; detach_self exp2; exit 0 ;;
  "") ;;
  *) die "用法：sudo ./exp2-slew-399ms.sh [--detach|--status]" ;;
esac

require_root
preflight
mkdir -p "$EXP_DIR"
export WITH_STEP_DETECTOR=1

for ms in 399 401; do
  outdir="$EXP_DIR/cell-${ms}ms"
  if [[ -f "$outdir/result.json" ]]; then
    log "skip ${ms}ms（已有 result.json）"
    continue
  fi
  log "=== cell ${ms}ms（門檻 0.4s 的$( [[ $ms -lt 400 ]] && echo 下 || echo 上 )側）==="
  rc=0
  run_recovery_cell "$outdir" "$ms" 0 "$TIMEOUT_S" || rc=$?
  if [[ $rc -eq 4 ]]; then
    log "cell ${ms}ms 前置 reset 失敗，未寫 result（下次重跑會自動重試）"
    continue
  fi
  write_result "$outdir" "${ms}ms" 0 0 "$ms"
  # step 事件統計（連續 vs 不連續的 signature）
  jumps=$(grep -c ',jump,' "$outdir/steps.csv" || true)
  maxjump=$(awk -F, '$3=="jump" {v=($4<0?-$4:$4); if (v>m) m=v} END {print m+0}' "$outdir/steps.csv" 2>/dev/null || echo 0)
  log "cell ${ms}ms：step 事件 ${jumps} 筆，最大單筆 ${maxjump}ms（預期：399ms=一串小事件、401ms=單筆≈400ms）"
  if [[ $rc -eq 3 ]]; then
    log "警告：${ms}ms 未在 ${TIMEOUT_S}s 內收斂，違反預測，檢查 probe.csv"
  fi
done
systemctl start systemd-timesyncd 2>/dev/null || true   # 收尾：別讓 timesyncd 停著
log "exp2 完成 → $EXP_DIR"
