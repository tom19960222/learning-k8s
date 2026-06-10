#!/usr/bin/env bash
# all.sh — 校準 → exp1 → exp2 → exp3 → exp4 全套無人值守，可中斷後重跑（自動續）。
# 用法：sudo ./all.sh [--soak-hours 4] [--detach] ；./all.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOAK_HOURS=4
DETACH=0
STATE="$RESULTS_DIR/all-state.json"

mark() {  # mark <phase> <status>
  $PY - "$STATE" "$1" "$2" <<'PYEOF'
import json, os, sys
path, phase, status = sys.argv[1:4]
d = json.load(open(path)) if os.path.exists(path) else {}
d[phase] = status
json.dump(d, open(path, "w"), indent=1)
PYEOF
}

# while-loop 解析：--soak-hours 與 --detach 任意順序都行
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      systemctl status tsexp-all --no-pager 2>/dev/null || true
      { [[ -f "$STATE" ]] && cat "$STATE"; } || echo "尚未開始"
      exit 0 ;;
    --detach) DETACH=1; shift ;;
    --soak-hours) SOAK_HOURS="$2"; shift 2 ;;
    *) die "用法：sudo ./all.sh [--soak-hours N] [--detach] / --status" ;;
  esac
done

if [[ "$DETACH" == 1 ]]; then
  require_root
  detach_self all --soak-hours "$SOAK_HOURS"
  exit 0
fi

require_root
preflight

if [[ ! -f "$RESULTS_DIR/calibration.json" ]]; then
  mark calibrate running
  "$RUN_DIR/../setup/calibrate.sh" --minutes 30
fi
mark calibrate done

mark exp1 running; "$RUN_DIR/exp1-drift-recovery.sh" --all;                 mark exp1 done
mark exp2 running; "$RUN_DIR/exp2-slew-399ms.sh";                           mark exp2 done
mark exp3 running; "$RUN_DIR/exp3-restart-sync.sh" --all;                   mark exp3 done
mark exp4 running; "$RUN_DIR/exp4-poll256-soak.sh" --all --hours "$SOAK_HOURS"; mark exp4 done

log "全套完成。結果都在 $RESULTS_DIR；scp 回 repo 後 commit。"
