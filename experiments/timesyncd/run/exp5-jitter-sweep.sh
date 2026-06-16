#!/usr/bin/env bash
# exp5-jitter-sweep.sh — PollIntervalMaxSec=256 的網路惡化耐受地圖。
#
# 目的：回答「把對時間隔壓到 256 秒後，timesyncd 的時鐘在多惡劣的網路下才會失穩」。
# 全程 max poll = 256s，一階一階加重 netem，每階看時鐘有沒有守住：
#   判準（jitter 模式，與乾淨 soak 不同）：
#     - offset 全程 < 50ms（核心：NTP 樣本被網路糟蹋時，clock 還守不守得住）
#     - 0 次非預期 step（|jump| >= 50ms）
#     - 0 次 5s lease miss / backward
#     - journal 0 error
#     - ping 因 netem 注入必掉，只當參考、不作為 fail 判準
#
# 兩種注入模式（關鍵的方法論區分）：
#   sym  = 雙向對稱（IFB 同時整形 egress + ingress）：來回都延遲，offset 不被偏，
#          純粹隔離「PLL 對雜訊的敏感度 / 樣本被餓死」——這才是 256s 真正的問題。
#   asym = 只整形 egress（netem 掛 root）：路徑變不對稱，offset 被偏 ≈ 延遲/2，
#          這是 NTP 對稱路徑假設破裂、與 poll interval 無關，當對照用。
#
# 用法（--detach 必須是第一個參數）：
#   sudo ./exp5-jitter-sweep.sh --all
#   sudo ./exp5-jitter-sweep.sh --detach
#   sudo ./exp5-jitter-sweep.sh --smoke      # sym + asym 各 1 階 ~90s，部署後煙霧用
#   ./exp5-jitter-sweep.sh --status
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

EXP_DIR="$RESULTS_DIR/exp5"
POLL_DROPIN=/etc/systemd/timesyncd.conf.d/50-driftlab-poll.conf
OFFSET_MAX_MS=50
OFFSET_WINDOW=31   # 滾動中位數視窗（秒）：濾掉重 jitter 下單發探針的零均值雜訊，量真實時鐘偏移
SMOKE=0

# 階梯："name mode delay_ms jitter_ms loss_pct hours"
# clean 錨點 → asym 不對稱延遲對照（找 D/2 偏移的膝點）→ sym 對稱 jitter → sym 對稱 loss
TIERS=(
  "clean    clean   0    0    0   1.5"
  "a40      asym   40    0    0   2.0"
  "a80      asym   80    0    0   2.0"
  "a120     asym  120    0    0   2.0"
  "a200     asym  200    0    0   2.0"
  "j10      sym    10   10    0   2.5"
  "j40      sym    40   40    0   2.5"
  "j100     sym   100  100    0   2.5"
  "j160     sym   160  160    0   2.5"
  "j250     sym   250  250    0   2.5"
  "loss10   sym     5    3   10   2.5"
  "loss30   sym     5    3   30   2.5"
  "loss50   sym     5    3   50   2.5"
  "loss75   sym     5    3   75   2.5"
)

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

# 全清：egress root、ingress、ifb0 root、ifb0 down——冪等，任何模式後都安全呼叫
netem_clear() {
  tc qdisc del dev "$CLIENT_IFACE" root 2>/dev/null || true
  tc qdisc del dev "$CLIENT_IFACE" ingress 2>/dev/null || true
  tc qdisc del dev ifb0 root 2>/dev/null || true
  ip link set dev ifb0 down 2>/dev/null || true
}

# $1=mode $2=delay_ms $3=jitter_ms $4=loss_pct
netem_apply() {
  local mode=$1 d=$2 j=$3 l=$4 spec="netem"
  [[ "$d" != 0 || "$j" != 0 ]] && spec="$spec delay ${d}ms ${j}ms"
  [[ "$l" != 0 ]] && spec="$spec loss ${l}%"
  if [[ "$mode" == clean || "$spec" == "netem" ]]; then
    log "tier 無 netem（乾淨錨點）"; return 0
  fi
  if [[ "$mode" == asym ]]; then
    # shellcheck disable=SC2086
    tc qdisc add dev "$CLIENT_IFACE" root $spec
    log "netem(asym, egress-only)：$spec"
    return 0
  fi
  # sym：IFB 雙向。egress 掛 root、ingress 經 mirred 重導到 ifb0 再掛同樣 netem
  modprobe ifb numifbs=1 2>/dev/null || true
  ip link set dev ifb0 up
  tc qdisc add dev "$CLIENT_IFACE" handle ffff: ingress
  tc filter add dev "$CLIENT_IFACE" parent ffff: protocol all u32 match u32 0 0 \
    action mirred egress redirect dev ifb0
  # shellcheck disable=SC2086
  tc qdisc add dev ifb0 root $spec
  # shellcheck disable=SC2086
  tc qdisc add dev "$CLIENT_IFACE" root $spec
  log "netem(sym, 雙向 IFB)：$spec（egress + ingress）"
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
  JCURSOR="$(journalctl -u systemd-timesyncd --show-cursor -n 0 2>/dev/null | sed -n 's/^-- cursor: //p')"
}

stop_monitors() {  # $1 = outdir
  local d=$1 p
  if [[ -f "$d/sentinel.pid" ]]; then
    kill "$(cat "$d/sentinel.pid")" 2>/dev/null || true; rm -f "$d/sentinel.pid"
  fi
  if [[ -f "$d/ping.pid" ]]; then
    p="$(cat "$d/ping.pid")"
    kill -INT "$p" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$p" 2>/dev/null || break; sleep 1; done
    rm -f "$d/ping.pid"
  fi
  stop_step_detector "$d/steps.csv"
  stop_probe "$d/probe.csv"
  journalctl -q -u systemd-timesyncd --after-cursor "$JCURSOR" -p err --no-pager \
    > "$d/journal-errors.txt" 2>/dev/null || true
}

run_tier() {  # $1=name $2=mode $3=delay $4=jitter $5=loss $6=hours
  local name=$1 mode=$2 delay=$3 jitter=$4 loss=$5 hours=$6 poll=${7:-256} outdir secs rc=0
  outdir="$EXP_DIR/$name"
  if [[ -f "$outdir/verdict.json" ]]; then
    log "skip tier $name（已有 verdict.json）"; return 0
  fi
  mkdir -p "$outdir"
  echo "{\"name\":\"$name\",\"mode\":\"$mode\",\"delay_ms\":$delay,\"jitter_ms\":$jitter,\"loss_pct\":$loss,\"poll\":$poll}" \
    > "$outdir/tier.json"
  secs=$($PY -c "print(int($hours*3600))")
  [[ "$SMOKE" == 1 ]] && secs=90
  log "=== tier $name（$mode）：delay ${delay}±${jitter}ms loss ${loss}%，跑 ${secs}s（max poll ${poll}）==="
  # one-shot trap：函式內 RETURN trap 會殘留到呼叫者，開頭先解除；netem_clear 冪等
  trap 'trap - RETURN; stop_monitors "$outdir"; netem_clear; set_poll_max default || true' RETURN
  set_poll_max "$poll"
  netem_clear   # 確保乾淨網路再對時
  wait_synced 50 600 || { log "ERROR tier $name：baseline 收斂失敗，略過此 tier"; return 0; }
  start_monitors "$outdir"
  netem_apply "$mode" "$delay" "$jitter" "$loss"
  sleep "$secs"
  netem_clear
  stop_monitors "$outdir"
  $PY "$LIB_DIR/analyze.py" soak-verdict --dir "$outdir" \
    --step-min-ms 50 --ignore-ping --offset-max-ms "$OFFSET_MAX_MS" \
    --offset-window "$OFFSET_WINDOW" || rc=$?
  [[ $rc -eq 0 ]] && log "tier $name → PASS" || log "tier $name → FAIL（看 $outdir/verdict.md）"
  return 0   # FAIL 也續跑，地圖要完整
}

summarize() {
  local md="$EXP_DIR/summary.md"
  $PY - "$EXP_DIR" > "$md" <<'PYEOF'
import json, os, sys
exp = sys.argv[1]
print("# exp5 — PollIntervalMaxSec 網路惡化耐受地圖")
print()
print("| tier | mode | poll | delay±jitter (ms) | loss (%) | peak \\|offset\\| | step | lease miss | verdict |")
print("|---|---|---|---|---|---|---|---|---|")
dirs = sorted(d for d in os.listdir(exp) if os.path.isdir(os.path.join(exp, d)))
for nm in dirs:
    tj = os.path.join(exp, nm, "tier.json")
    vj = os.path.join(exp, nm, "verdict.json")
    t = json.load(open(tj)) if os.path.exists(tj) else {}
    dj, jt, ls = t.get("delay_ms", "?"), t.get("jitter_ms", "?"), t.get("loss_pct", "?")
    poll, mode = t.get("poll", 256), t.get("mode", "?")
    if os.path.exists(vj):
        d = json.load(open(vj))
        c = {x["name"]: x["value"] for x in d.get("checks", [])}
        peak = next((v for k, v in c.items() if "offset" in k), "—")
        step = next((v for k, v in c.items() if k.startswith("step")), "—")
        miss = next((v for k, v in c.items() if "lease" in k), "—")
        verd = "✅ PASS" if d.get("pass") else "❌ FAIL"
    else:
        peak = step = miss = "—"; verd = "(進行中/未跑)"
    print(f"| {nm} | {mode} | {poll} | {dj}±{jt} | {ls} | {peak} | {step} | {miss} | {verd} |")
PYEOF
  cat "$md"
}

case "${1:-}" in
  --status)
    systemctl status tsexp-exp5 --no-pager 2>/dev/null || true
    [[ -d "$EXP_DIR" ]] && summarize || echo "尚未開始"
    exit 0 ;;
  --detach)
    shift
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（netem 需要）"
    detach_self exp5 --all "$@"
    exit 0 ;;
  --smoke)
    SMOKE=1
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（netem 需要）"
    trap 'netem_clear; set_poll_max default || true' EXIT INT TERM
    preflight; mkdir -p "$EXP_DIR"
    run_tier clean clean 0 0 0 0
    run_tier a80 asym 80 0 0 0
    run_tier j40 sym 40 40 0 0
    summarize ;;
  --controls)
    # 對照組：同樣對稱抖動但 max poll 用預設 2048，回答「抖動下的失穩是 256s 特有、還是任何 poll 都一樣」
    shift
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（netem 需要）"
    trap 'netem_clear; set_poll_max default || true' EXIT INT TERM
    preflight; mkdir -p "$EXP_DIR"
    run_tier c2048-j40  sym 40  40  0 2.5 2048
    run_tier c2048-j100 sym 100 100 0 2.5 2048
    summarize
    systemctl start systemd-timesyncd 2>/dev/null || true
    log "exp5 controls 完成 → $EXP_DIR/summary.md" ;;
  --detach-controls)
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（netem 需要）"
    detach_self exp5 --controls
    exit 0 ;;
  --all)
    shift
    require_root
    [[ -n "${CLIENT_IFACE:-}" ]] || die "env.sh 缺 CLIENT_IFACE（netem 需要）"
    trap 'netem_clear; set_poll_max default || true' EXIT INT TERM
    preflight; mkdir -p "$EXP_DIR"
    for spec in "${TIERS[@]}"; do
      # shellcheck disable=SC2086
      run_tier $spec
    done
    summarize
    systemctl start systemd-timesyncd 2>/dev/null || true   # 收尾
    log "exp5 全部完成 → $EXP_DIR/summary.md" ;;
  *)
    die "用法見檔頭註解（--all / --smoke / --status / --detach）" ;;
esac
