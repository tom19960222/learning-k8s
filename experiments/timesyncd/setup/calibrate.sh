#!/usr/bin/env bash
# calibrate.sh — 量 client 天然漂移基線（預設 30 分鐘）。
# 用法：sudo ./calibrate.sh [--minutes 30] [--detach]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
require_root

MINUTES=30
DETACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    --detach) DETACH=1; shift ;;
    *) die "未知參數 $1" ;;
  esac
done
if [[ "$DETACH" == 1 ]]; then
  detach_self calibrate --minutes "$MINUTES"
  exit 0
fi

OUT="$RESULTS_DIR/calibration"
mkdir -p "$OUT"
preflight
trap 'stop_probe "$OUT/probe.csv"; systemctl start systemd-timesyncd' EXIT

reset_clock_state            # 含停 timesyncd、暫存器歸零、步進回真時
start_probe "$OUT/probe.csv"
log "校準中：timesyncd 已停、暫存器歸零，free-run 量 ${MINUTES} 分鐘…"
sleep "$((MINUTES * 60))"
stop_probe "$OUT/probe.csv"

$PY "$LIB_DIR/analyze.py" calibrate --csv "$OUT/probe.csv" --out "$RESULTS_DIR/calibration.json"
log "校準完成 → $RESULTS_DIR/calibration.json"
