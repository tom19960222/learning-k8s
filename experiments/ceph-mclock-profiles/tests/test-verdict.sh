#!/usr/bin/env bash
# Task 10 — lib/verdict.py（aggregate / margins / verdict / need-more-n /
# baseline-check / schemas / schedule-estimate / audit）。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
V="$root/lib/verdict.py"
GEN="$here/fixtures/gen-fio-logs.py"
MK="$here/fixtures/mk-bundle.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-verdict.XXXXXX")"
T0=1750000000

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; rm -rf "$tmp"; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
contains() { case "$1" in *"$2"*) ok ;; *) fail "$3（got=[$1] 不含 [$2]）" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3（got=[$1] 不該含 [$2]）" ;; *) ok ;; esac; }

jget() { # jget <json-file> <dotted.path>
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print("null" if d is None else d)
PY
}

wj() { # wj <file> <json>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

jnum() { # jnum <json-file> <dotted.path>；印四捨五入後的整數
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(int(round(float(d))))
PY
}

flt() { # flt <a> <b>：a < b 為真
  python3 - "$1" "$2" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)
PY
}

# ==================================================================== schemas ==
out="$(python3 "$V" schemas steady)"
contains "$out" "prediction.json" "steady schema 含 prediction"
contains "$out" "qos.json" "steady schema 含 qos"
contains "$out" "aggregate.json" "steady schema 含 aggregate"
contains "$out" "verdict.json" "steady schema 含 verdict"
contains "$out" "# schema_version=" "schema 有版本標註（versioned schema）"
lacks "$out" "fault-timeline.json" "steady 不該要求 fault-timeline"

out="$(python3 "$V" schemas fault)"
for f in prediction.json verdict.json fault-timeline.json sampler-summary.json \
         censor-status.json final-clean-proof.json cleanup-proof.json \
         coverage-proof.json return-backfill.json; do
  contains "$out" "$f" "fault schema 含 ${f}"
done

out="$(python3 "$V" schemas chaos)"
contains "$out" "event-seq.json" "chaos schema 含 event-seq"
contains "$out" "coverage-proof.json" "chaos schema 含 coverage-proof"
contains "$out" "prediction.json" "chaos schema 含 prediction"
contains "$out" "verdict.json" "chaos schema 含 verdict"
lacks "$out" "fault-timeline.json" "chaos 不沿用 fault 的 timeline 契約"

python3 "$V" schemas nope >/dev/null 2>&1 && fail "未知 kind 應非 0 退出"
ok

# 三個 kind 的檔案清單必須互不相同（versioned per-kind schema 的意義）
eq "$(python3 "$V" schemas steady | grep -cv '^#')" "5" "steady 必備檔數"
[ "$(python3 "$V" schemas fault | grep -cv '^#')" -gt \
  "$(python3 "$V" schemas steady | grep -cv '^#')" ] || fail "fault 應為 steady 的超集"
ok

# ---- 與 Task 2 bundle_finalize 的契約（真的用 lib/common.sh 跑一次）----------
export VERDICT_PY="$V"
export RESULTS_DIR="$tmp/finalize-results"
# shellcheck source=../lib/common.sh
. "$root/lib/common.sh"

b="$(new_bundle c99-contract r1)"
bundle_finalize "$b" fault >/dev/null 2>&1 && fail "缺件時 bundle_finalize 不該成功"
ok
while IFS= read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  printf '{}\n' > "$b/$f"
done < <(python3 "$V" schemas fault)
bundle_finalize "$b" fault >/dev/null 2>&1 || fail "齊件時 bundle_finalize 應成功"
ok
[ -f "$b/DONE" ] || fail "finalize 後應有 DONE"
ok

# =================================================================== aggregate ==
# 兩 client × 兩 segment，段界重疊一秒（seg01 尾窗 vs seg02 首秒）
mkb() { # mkb <bundle> ; 產 fio log
  local bd="$1" c
  for c in c1 c2; do
    python3 "$GEN" --out "$bd/fio/$c" --seg seg01 --start "$T0" --seconds 61 \
      --stall-secs "58,59,60" --brownout-secs "10,11,12,13,14" --dup-secs "5" >/dev/null
    python3 "$GEN" --out "$bd/fio/$c" --seg seg02 --start "$((T0 + 60))" --seconds 60 \
      --stall-secs "0,1" --omit-secs "40,41,42" >/dev/null
  done
}

B1="$tmp/b1"
mkdir -p "$B1"
mkb "$B1"
wj "$B1/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 119))},\"gaps\":[],\"tainted\":false}"
out="$(python3 "$V" aggregate "$B1")"
contains "$out" "aggregate: OK" "aggregate 機器行"
A="$B1/aggregate.json"

# --- 窗尾夾到 fio 實際結束（真機：偵測延遲 34s 被算成 stall）-------------------
BW="$tmp/bw"; mkdir -p "$BW"
python3 "$GEN" --out "$BW/fio/c1" --seg seg01 --start "$T0" --seconds 60 >/dev/null
# coverage 窗比 fio 資料多 40 秒（模擬「偵測 fio 結束」的輪詢延遲）
wj "$BW/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 99))},\"gaps\":[],\"tainted\":false}"
# fio 自行結束 → 必須夾窗，尾端 40 秒不得算成 stall
wj "$BW/fio-exit-proof.json" \
  "{\"all_ok\":true,\"clients\":{\"c1\":{\"exit_code\":0,\"fio_exited_at\":$((T0 + 59))}}}"
python3 "$V" aggregate "$BW" >/dev/null 2>&1 || fail "aggregate（夾窗）應成功"
ok
eq "$(jget "$BW/aggregate.json" endpoints.max_stall_seconds)" "0" \
  "fio 自行結束後的偵測延遲不得算成 stall"

# 反面：fio 被我們 STOP 中止（沒有 fio_exited_at）→ 尾端沒 IO 是真 stall，不得夾掉
BW2="$tmp/bw2"; mkdir -p "$BW2"
python3 "$GEN" --out "$BW2/fio/c1" --seg seg01 --start "$T0" --seconds 60 >/dev/null
wj "$BW2/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 99))},\"gaps\":[],\"tainted\":false}"
wj "$BW2/fio-exit-proof.json" \
  "{\"all_ok\":true,\"clients\":{\"c1\":{\"exit_code\":0,\"fio_exited_at\":null}}}"
python3 "$V" aggregate "$BW2" >/dev/null 2>&1 || fail "aggregate（不夾窗）應成功"
ok
[ "$(jget "$BW2/aggregate.json" endpoints.max_stall_seconds)" -ge 30 ] \
  || fail "被中止時尾端無 IO 必須算成 stall（client 全黑正是故障實驗要抓的）"
ok

# 1) 段界 stall 續接：seg01 的尾窗 T+60 被 seg02 覆蓋 → 丟尾窗、留 seg02
#    → stall = T+58, T+59, T+60, T+61 共 4 秒連續
eq "$(jget "$A" windows.full.max_stall_seconds)" "4" "跨 segment 的連續 stall 要接得起來"
# 2) 未宣告 gap 的缺樣秒（T+100..104）也算 stall（coverage supervisor 說工具活著）
eq "$(jget "$A" windows.full.total_stall_seconds)" "7" "缺樣秒在無 gap 宣告時算 stall"
# 3) 重複 timestamp 被丟棄（每 client 每 direction 一筆重複 + 尾窗重疊）
[ "$(jget "$A" normalization.duplicate_rows_dropped)" -ge 4 ] || fail "重複 timestamp 未被丟棄"
ok
# 4) brownout：該秒 hist p99 > 1s
eq "$(jget "$A" windows.full.max_brownout_seconds)" "5" "brownout 最長連續秒數"
eq "$(jget "$A" windows.full.total_brownout_seconds)" "5" "brownout 總秒數"
# 5) hist 單位由 bin 數自動判定
eq "$(jget "$A" log_schema.hist_bins)" "1856" "hist bin 數（ns 版）"
eq "$(jget "$A" log_schema.hist_unit)" "ns" "hist 單位自動判定"
eq "$(jget "$A" log_schema.epoch_ms)" "True" "log_unix_epoch=1 偵測"
# 6) percentile 四件組齊備
for k in p50_ns p99_ns p999_ns max_ns; do
  [ "$(jget "$A" "windows.full.$k")" != "null" ] || fail "缺 ${k}"
  ok
done
# 7) 兩 client 的 IOPS 相加（2 client × 2 direction × 1000）
eq "$(jnum "$A" windows.full.iops_median)" "4000" "跨 client/direction 的 IOPS 合計"

# ---- log gap（工具中斷）≠ stall -------------------------------------------
B2="$tmp/b2"
mkdir -p "$B2"
mkb "$B2"
wj "$B2/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 119))},\"gaps\":[{\"start\":$((T0 + 100)),\"end\":$((T0 + 102)),\"source\":\"fio-heartbeat\"}],\"tainted\":false}"
python3 "$V" aggregate "$B2" >/dev/null
A2="$B2/aggregate.json"
eq "$(jget "$A2" windows.full.gap_seconds)" "3" "coverage-proof 宣告的 gap 秒數"
eq "$(jget "$A2" windows.full.total_stall_seconds)" "4" "gap 不得被算成 stall"
eq "$(jget "$A2" windows.full.max_stall_seconds)" "4" "gap 排除後最長 stall 不變"

# ---- 不完整尾窗：無其他 segment 覆蓋時保留但不判 stall ----------------------
B3="$tmp/b3"
mkdir -p "$B3"
python3 "$GEN" --out "$B3/fio/c1" --seg seg01 --start "$T0" --seconds 40 >/dev/null
wj "$B3/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 39))},\"gaps\":[],\"tainted\":false}"
python3 "$V" aggregate "$B3" >/dev/null
eq "$(jget "$B3/aggregate.json" windows.full.partial_tail_seconds)" "1" "孤立尾窗被標記"
eq "$(jget "$B3/aggregate.json" windows.full.total_stall_seconds)" "0" "尾窗不得判為 stall"

# ---- us 版 hist（1216 bins）------------------------------------------------
B4="$tmp/b4"
mkdir -p "$B4"
python3 "$GEN" --out "$B4/fio/c1" --seg seg01 --start "$T0" --seconds 40 --bins 1216 >/dev/null
wj "$B4/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 39))},\"gaps\":[],\"tainted\":false}"
python3 "$V" aggregate "$B4" >/dev/null
eq "$(jget "$B4/aggregate.json" log_schema.hist_unit)" "us" "1216 bins → us 版 fio"

# ---- fault 窗口：baseline / fault_t0 / down_epoch 三軌 ----------------------
B5="$tmp/b5"
mkdir -p "$B5"
# 前 90s 健康（lat 500us），之後 90s 劣化（lat 5ms）
python3 "$GEN" --out "$B5/fio/c1" --seg seg01 --start "$T0" --seconds 90 \
  --lat-ns 500000 >/dev/null
python3 "$GEN" --out "$B5/fio/c1" --seg seg02 --start "$((T0 + 90))" --seconds 90 \
  --lat-ns 5000000 --iops 200 >/dev/null
wj "$B5/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 179))},\"gaps\":[],\"tainted\":false}"
wj "$B5/fault-timeline.json" \
  "{\"fault_t0\":$((T0 + 70)),\"down_epoch_t\":$((T0 + 90)),\"heal_t0\":$((T0 + 175)),\"measurement_deadline\":$((T0 + 2770)),\"measurement_cap\":2700}"
wj "$B5/censor-status.json" \
  "{\"censored\":false,\"measurement_cap\":2700,\"time_to_recovery_complete_s\":1200}"
wj "$B5/sampler-summary.json" '{"recovery_bytes_per_sec_median":120000000}'
wj "$B5/return-backfill.json" '{"heal_t0":1,"final_clean_t":2,"duration_s":640}'
wj "$B5/prediction.json" \
  '{"cell_id":"c05","group_id":"g05","profile":"balanced","shape":"4k-randrw","pressure":"mid"}'
python3 "$V" aggregate "$B5" >/dev/null
A5="$B5/aggregate.json"
eq "$(jget "$A5" windows.baseline.start)" "$((T0 + 10))" "baseline 窗 = fault_t0 前 60s"
eq "$(jget "$A5" windows.baseline.end)" "$((T0 + 69))" "baseline 窗結束於 fault_t0 前一秒"
eq "$(jget "$A5" windows.measurement_t0.start)" "$((T0 + 70))" "量測窗以 fault_t0 起算"
eq "$(jget "$A5" windows.measurement_down_epoch.start)" "$((T0 + 90))" "另一軌以 OSDMap down epoch 起算"
# fault_t0 軌含 20 秒「什麼都沒發生」（isolation 要等 heartbeat grace 才判 down）
# → 以 fault_t0 對齊會把健康段算進故障窗，量測值被系統性稀釋（H-020）。
r_t0="$(jget "$A5" endpoints.p99_degradation_ratio)"
r_de="$(jget "$A5" endpoints.p99_degradation_ratio_down_epoch)"
flt "1.0" "$r_t0" || fail "故障窗應量到 p99 劣化"
flt "1.0" "$r_de" || fail "down_epoch 軌也應量到 p99 劣化"
flt "$(jget "$A5" windows.measurement_down_epoch.iops_mean)" \
    "$(jget "$A5" windows.measurement_t0.iops_mean)" \
  || fail "fault_t0 軌被前 20 秒健康窗稀釋（H-020：跨故障型比較須用 down epoch）"
ok
eq "$(jget "$A5" endpoints.recovery_bytes_per_sec)" "120000000" "recovery bytes/s 取自 sampler"
eq "$(jget "$A5" endpoints.time_to_recovery_complete_s)" "1200" "time-to-recovery 取自 censor-status"
eq "$(jget "$A5" endpoints.return_backfill_duration_s)" "640" "H-008 回歸 backfill 時長"
eq "$(jget "$A5" censor_basis)" "recovery_complete" "censor 相對 recovery_complete"
# heal 之後的秒數不得算進量測窗
[ "$(jget "$A5" windows.measurement_t0.end)" -lt "$((T0 + 175))" ] \
  || fail "量測窗不得延伸到 heal 之後"
ok

# ---- censored：時間取 cap ---------------------------------------------------
B6="$tmp/b6"
mkdir -p "$B6"
python3 "$GEN" --out "$B6/fio/c1" --seg seg01 --start "$T0" --seconds 90 >/dev/null
wj "$B6/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 89))},\"gaps\":[],\"tainted\":false}"
wj "$B6/fault-timeline.json" \
  "{\"fault_t0\":$((T0 + 70)),\"measurement_deadline\":$((T0 + 2770)),\"measurement_cap\":2700}"
wj "$B6/censor-status.json" '{"censored":true,"measurement_cap":2700}'
python3 "$V" aggregate "$B6" >/dev/null
eq "$(jget "$B6/aggregate.json" censored)" "True" "censored 旗標透傳"
eq "$(jget "$B6/aggregate.json" endpoints.time_to_recovery_complete_s)" "2700" \
   "censored 時 time-to-recovery = cap（右設限下界）"

# ---- --validate-schema（fio_smoke_real 的 parser 校正）----------------------
out="$(python3 "$V" aggregate "$B1" --validate-schema)"
contains "$out" "aggregate: SCHEMA-OK" "真機 log 校正模式通過"
contains "$out" "hist_bins=1856" "校正模式回報 hist bin 數"

BS="$tmp/bad-bins"
mkdir -p "$BS"
python3 "$GEN" --out "$BS/fio/c1" --seg seg01 --start "$T0" --seconds 40 --bins 900 >/dev/null
out="$(python3 "$V" aggregate "$BS" --validate-schema 2>/dev/null)" && \
  fail "未知 hist bin 數應 SCHEMA-FAIL"
contains "$out" "aggregate: SCHEMA-FAIL" "未知 bin 數 → SCHEMA-FAIL"

BT="$tmp/bad-ts"
mkdir -p "$BT"
python3 "$GEN" --out "$BT/fio/c1" --seg seg01 --start 0 --seconds 40 >/dev/null
out="$(python3 "$V" aggregate "$BT" --validate-schema 2>/dev/null)" && \
  fail "非 epoch timestamp 應 SCHEMA-FAIL"
contains "$out" "SCHEMA-FAIL" "缺 log_unix_epoch=1 → SCHEMA-FAIL"

BE="$tmp/too-short"
mkdir -p "$BE"
python3 "$GEN" --out "$BE/fio/c1" --seg seg01 --start "$T0" --seconds 5 >/dev/null
python3 "$V" aggregate "$BE" --validate-schema >/dev/null 2>&1 && \
  fail "樣本過短應 SCHEMA-FAIL"
ok

# ===================================================================== margins ==
MRES="$tmp/mres"
mkrep() { python3 "$MK" --results "$MRES" "$@" >/dev/null; }

# 穩態三 cells × 3 replicates：p99 ratio 很穩（噪音 << 生產門檻）、
# stall 很飄（噪音 >= 生產門檻 2s）→ 兩種靈敏度都要驗到
i=0
for cell in s01 s02 s03; do
  j=0
  for rep in r1 r2 r3; do
    ratios="1.00 1.02 0.98"
    stalls="0 5 10"
    ratio="$(printf '%s' "$ratios" | cut -d' ' -f$((j + 1)))"
    stall="$(printf '%s' "$stalls" | cut -d' ' -f$((j + 1)))"
    mkrep --cell "$cell" --rep "$rep" --attempt "ts$rep" --group "gs$i" \
      --endpoint "p99_degradation_ratio=$ratio" --endpoint "max_stall_seconds=$stall"
    j=$((j + 1))
  done
  i=$((i + 1))
done

STEADY=""
for cell in s01 s02 s03; do
  for rep in r1 r2 r3; do
    STEADY="$STEADY $MRES/$cell/$rep/attempts/ts$rep"
  done
done
# shellcheck disable=SC2086  # STEADY 是刻意要做 word-splitting 的 bundle 路徑清單
out="$(python3 "$V" margins $STEADY -o "$MRES/margins.json" --results "$MRES")"
contains "$out" "margins: OK" "margins 機器行"
contains "$out" "margins: UNDERPOWERED max_stall_seconds" "噪音 >= 生產門檻 → 靈敏度不足"
M="$MRES/margins.json"
eq "$(jget "$M" sensitivity.p99_degradation_ratio.status)" "adequate" "p99 ratio 靈敏度足夠"
eq "$(jget "$M" sensitivity.max_stall_seconds.status)" "underpowered" "stall 靈敏度不足"
# 雙軌並存：production 取 HYPOTHESES.md 預註冊值，noise 由 CoV 導出
eq "$(jget "$M" production.max_stall_seconds.diff_abs)" "2.0" "production margin = 預註冊絕對門檻"
eq "$(jget "$M" production.p99_degradation_ratio.severity.incident)" "10.0" "事故級門檻入檔"
eq "$(jget "$M" noise_steady.p99_degradation_ratio.cells)" "3" "noise margin 由三個 cell 導出"
[ "$(jget "$M" noise_steady.max_stall_seconds.pooled_stdev)" != "null" ] || fail "缺 pooled stdev"
ok
eq "$(jget "$M" noise_steady.p99_degradation_ratio.basis)" "within-cell-replicates" "noise 基礎"

# 故障 cells 的噪音不可直接沿用穩態 → --fault 提供的補正要優先
mkrep --cell f01 --rep r1 --attempt t1 --group gf --endpoint "max_stall_seconds=20"
mkrep --cell f01 --rep r2 --attempt t2 --group gf --endpoint "max_stall_seconds=21"
# shellcheck disable=SC2086
python3 "$V" margins $STEADY --fault "$MRES/f01/r1/attempts/t1" "$MRES/f01/r2/attempts/t2" \
  -o "$MRES/margins-f.json" --results "$MRES" >/dev/null
eq "$(jget "$MRES/margins-f.json" sensitivity.max_stall_seconds.noise_basis)" "fault" \
   "故障 cells 的 noise margin 以故障資料補正"

# HYPOTHESES.md 漂移偵測（預註冊門檻是 SoT，兩邊不得悄悄分岔）
sed 's/≥ \*\*3×\*\*/≥ **4×**/' "$root/HYPOTHESES.md" > "$tmp/hyp-drift.md"
# shellcheck disable=SC2086
out="$(python3 "$V" margins $STEADY -o "$tmp/m2.json" --results "$MRES" \
  --hypotheses "$tmp/hyp-drift.md" 2>/dev/null)" && fail "門檻漂移應非 0 退出"
contains "$out" "margins: HYPOTHESES-DRIFT" "偵測到預註冊門檻漂移"

# ========================================================== prediction freeze ==
FB="$tmp/freeze-bundle"
mkdir -p "$FB"
wj "$tmp/pred-a.json" '{"cell_id":"c01","group_id":"g01","profile":"balanced"}'
wj "$tmp/pred-b.json" '{"cell_id":"c01","group_id":"g01","profile":"high_client_ops"}'
out="$(python3 "$V" freeze "$FB" --prediction "$tmp/pred-a.json")"
contains "$out" "freeze: FROZEN" "首次凍結"
[ -f "$FB/prediction.json" ] || fail "freeze 應把 prediction 寫進 bundle"
ok
out="$(python3 "$V" freeze "$FB" --prediction "$tmp/pred-a.json")"
contains "$out" "freeze: ALREADY-FROZEN" "同內容重複凍結為冪等"
python3 "$V" freeze "$FB" --prediction "$tmp/pred-b.json" >/dev/null 2>&1 \
  && fail "凍結後以不同內容覆寫應被拒"
ok
eq "$(jget "$FB/prediction.json" profile)" "balanced" "freeze 後內容不可變"
# 竄改偵測
wj "$FB/prediction.json" '{"cell_id":"c01","profile":"high_recovery_ops"}'
python3 "$V" verdict "$FB" >/dev/null 2>&1 && fail "prediction 被竄改時 verdict 應拒絕"
ok

# ============================================================ verdict（三態）==
VRES="$tmp/vres"
vrep() { python3 "$MK" --results "$VRES" "$@" >/dev/null; }

# 1) 單 replicate 記錄 + 嚴重度分級
vrep --cell v01 --rep r1 --attempt t1 --group gv1 --profile balanced \
  --endpoint "p99_degradation_ratio=12" --endpoint "max_stall_seconds=7" --cap 2700
VB="$VRES/v01/r1/attempts/t1"
out="$(python3 "$V" verdict "$VB")"
contains "$out" "verdict: RECORDED v01" "replicate 級 verdict 機器行"
contains "$out" "censored=0" "非 censored"
eq "$(jget "$VB/verdict.json" severity.max_stall_seconds)" "incident" "stall >= 5s 判事故級"
eq "$(jget "$VB/verdict.json" severity.p99_degradation_ratio)" "incident" "ratio >= 10x 判事故級"
eq "$(jget "$VB/verdict.json" censor_basis)" "recovery_complete" "censor 基準"

# 2) 拒絕合併不同 cap 的 replicates（→ 觸發 extra-n）
vrep --cell v02 --rep r1 --attempt t1 --group gv2 --endpoint "max_stall_seconds=3" --cap 2700
vrep --cell v02 --rep r2 --attempt t1 --group gv2 --endpoint "max_stall_seconds=4" --cap 5400
out="$(python3 "$V" verdict --cell v02 --results "$VRES")"
contains "$out" "verdict: CAP-MISMATCH v02 2700,5400" "不同 cap 的 replicates 拒絕合併"
eq "$(jget "$VRES/v02/cell-verdict.json" pooling.status)" "rejected-cap-mismatch" "標記 cap 不一致"
eq "$(jget "$VRES/v02/cell-verdict.json" extra_n_required)" "True" "觸發 extra-n"

# 3) 同 cap 可合併
vrep --cell v03 --rep r1 --attempt t1 --group gv3 --endpoint "max_stall_seconds=3" --cap 2700
vrep --cell v03 --rep r2 --attempt t1 --group gv3 --endpoint "max_stall_seconds=5" --cap 2700
out="$(python3 "$V" verdict --cell v03 --results "$VRES")"
contains "$out" "verdict: POOLED v03 n=2" "同 cap 才合併"
eq "$(jget "$VRES/v03/cell-verdict.json" endpoints.max_stall_seconds.mean)" "4.0" "pooled 平均"

# 4) group 三態：confirmed（方向與預測 order 一致且超過生產門檻）
GRES="$tmp/gres"
ORD="p99_degradation_ratio=separated:high_client_ops,balanced,high_recovery_ops"
python3 "$MK" --results "$GRES" --cell g1a --group G1 --profile high_client_ops \
  --endpoint "p99_degradation_ratio=2.0" --expect "$ORD" >/dev/null
python3 "$MK" --results "$GRES" --cell g1b --group G1 --profile balanced \
  --endpoint "p99_degradation_ratio=3.5" --expect "$ORD" >/dev/null
python3 "$MK" --results "$GRES" --cell g1c --group G1 --profile high_recovery_ops \
  --endpoint "p99_degradation_ratio=6.0" --expect "$ORD" >/dev/null
wj "$GRES/margins.json" \
  '{"sensitivity":{"p99_degradation_ratio":{"noise_absolute":0.1},"max_stall_seconds":{"noise_absolute":0.1},"recovery_bytes_per_sec":{"noise_absolute":0.1},"time_to_recovery_complete_s":{"noise_absolute":0.1}}}'
out="$(python3 "$V" verdict --group G1 --results "$GRES")"
contains "$out" "verdict: G1 p99_degradation_ratio confirmed" "方向一致 → confirmed"

# 5) violated：預測等效卻量到超過生產門檻的差異
python3 "$MK" --results "$GRES" --cell g2a --group G2 --profile high_client_ops \
  --endpoint "p99_degradation_ratio=2.0" --expect "p99_degradation_ratio=indistinguishable" >/dev/null
python3 "$MK" --results "$GRES" --cell g2b --group G2 --profile balanced \
  --endpoint "p99_degradation_ratio=6.0" --expect "p99_degradation_ratio=indistinguishable" >/dev/null
out="$(python3 "$V" verdict --group G2 --results "$GRES")"
contains "$out" "verdict: G2 p99_degradation_ratio violated" "預測等效但實測分離 → violated"

# 6) indistinguishable(equivalent)：差異 < 生產門檻，且噪音 < 生產門檻
python3 "$MK" --results "$GRES" --cell g3a --group G3 --profile high_client_ops \
  --endpoint "p99_degradation_ratio=2.0" --expect "$ORD" >/dev/null
python3 "$MK" --results "$GRES" --cell g3b --group G3 --profile balanced \
  --endpoint "p99_degradation_ratio=2.3" --expect "$ORD" >/dev/null
out="$(python3 "$V" verdict --group G3 --results "$GRES")"
contains "$out" "verdict: G3 p99_degradation_ratio indistinguishable(equivalent)" \
  "差異 < 生產門檻且噪音夠小 → 等效"
eq "$(jget "$GRES/group-verdicts/G3.json" endpoints.p99_degradation_ratio.indistinguishable_type)" \
   "equivalent" "equivalent 型別入檔"

# 7) indistinguishable(underpowered)：同樣的觀測，但噪音 >= 生產門檻
wj "$GRES/margins-loud.json" \
  '{"sensitivity":{"p99_degradation_ratio":{"noise_absolute":9.0},"max_stall_seconds":{"noise_absolute":9.0},"recovery_bytes_per_sec":{"noise_absolute":9.0},"time_to_recovery_complete_s":{"noise_absolute":9.0}}}'
out="$(python3 "$V" verdict --group G3 --results "$GRES" --margins "$GRES/margins-loud.json")"
contains "$out" "verdict: G3 p99_degradation_ratio indistinguishable(underpowered)" \
  "噪音 >= 生產門檻 → 靈敏度不足（禁止寫成 profile 沒差）"

# ================================================================ need-more-n ==
NRES="$tmp/nres"
nrep() { python3 "$MK" --results "$NRES" "$@" >/dev/null; }
mkdir -p "$NRES"
wj "$NRES/margins.json" \
  '{"noise_steady":{"p99_degradation_ratio":{"relative":0.5},"max_stall_seconds":{"relative":0.5},"recovery_bytes_per_sec":{"relative":0.5},"time_to_recovery_complete_s":{"relative":0.5}}}'

# 1) CoV 在 margin 內 → 不加跑
nrep --cell n01 --rep r1 --attempt t1 --endpoint "max_stall_seconds=3"
nrep --cell n01 --rep r2 --attempt t1 --endpoint "max_stall_seconds=3.1"
out="$(python3 "$V" need-more-n n01 --results "$NRES")"
contains "$out" "need-more-n: OK n01 n=2" "CoV 在 margin 內不升級"

# 2) CoV 超 margin → 加跑一個
nrep --cell n02 --rep r1 --attempt t1 --endpoint "max_stall_seconds=1"
nrep --cell n02 --rep r2 --attempt t1 --endpoint "max_stall_seconds=10"
out="$(python3 "$V" need-more-n n02 --results "$NRES" --emit-amend)"
contains "$out" "need-more-n: EXTRA n02 1" "CoV 超 margin → 加跑"
contains "$out" '"type": "extra-replicates"' "輸出可餵給 manifest.py amend 的 journal 行"

# 3) 含 censored 觀測的 cell **不走 CoV 升級**（CoV 無定義）
nrep --cell n03 --rep r1 --attempt t1 --endpoint "max_stall_seconds=1" --censored
nrep --cell n03 --rep r2 --attempt t1 --endpoint "max_stall_seconds=10"
out="$(python3 "$V" need-more-n n03 --results "$NRES" --emit-amend)"
contains "$out" "need-more-n: CENSORED-NO-COV-UPGRADE n03 censored=1" "censored cell 不走 CoV 升級"
lacks "$out" "extra-replicates" "censored cell 不得產生 CoV 升級的 amendment"
lacks "$out" "RESCUE-CAP" "只有一個 censored 不觸發自救"
eq "$(jget "$NRES/n03/need-more-n.json" path)" "censored-no-cov-upgrade" "決策路徑記錄"

# 4) 雙 censored 自救：一次 cap×2 的加跑，每 cell 限一次
nrep --cell n04 --rep r1 --attempt t1 --endpoint "max_stall_seconds=1" --censored --cap 2700
nrep --cell n04 --rep r2 --attempt t1 --endpoint "max_stall_seconds=2" --censored --cap 2700
out="$(python3 "$V" need-more-n n04 --results "$NRES" --emit-amend)"
contains "$out" "need-more-n: RESCUE-CAP n04 5400" "雙 censored → cap×2 加跑"
contains "$out" '"type": "rescue-replicate"' "自救走 rescue-replicate 型 amendment"
lacks "$out" "extra-replicates" "自救不得混用 CoV 升級型"
printf '%s\n' '{"schema_version":1,"type":"rescue-replicate","key":"n04","value":{"cap":5400},"source":"t","seq":1}' \
  > "$NRES/schedule-amendments.json"
out="$(python3 "$V" need-more-n n04 --results "$NRES")"
contains "$out" "need-more-n: RESCUE-ALREADY-ISSUED n04" "自救每 cell 以一次為限"
rm -f "$NRES/schedule-amendments.json"

# 5) 不同 cap → 補一個同 cap 樣本
nrep --cell n05 --rep r1 --attempt t1 --endpoint "max_stall_seconds=1" --cap 2700
nrep --cell n05 --rep r2 --attempt t1 --endpoint "max_stall_seconds=2" --cap 5400
out="$(python3 "$V" need-more-n n05 --results "$NRES")"
contains "$out" "need-more-n: CAP-MISMATCH n05 2700,5400 extra=1" "cap 不一致 → 補同 cap 樣本"

# 6) n=5 上限
for rep in r1 r2 r3 r4 r5; do
  nrep --cell n06 --rep "$rep" --attempt t1 --endpoint "max_stall_seconds=$((RANDOM % 20))"
done
out="$(python3 "$V" need-more-n n06 --results "$NRES")"
case "$out" in
  *"need-more-n: CAPPED n06"*|*"need-more-n: OK n06"*) ok ;;
  *) fail "n=5 時只能是 CAPPED 或 OK（got=[$out]）" ;;
esac

# ============================================================== baseline-check ==
CAL='{"schema_version":1,"rho":0.7,"shapes":{"4k-randrw":{"ceiling_iops":40000,"rates":{"low":10000,"mid":20000,"high":32000},"reference_p99_ns":{"low":900000,"mid":1500000,"high":4000000,"extreme":20000000}}}}'

bcheck() { # bcheck <name> <pressure> <achieved> <p99> ; 印機器行
  local name="$1" pressure="$2" achieved="$3" p99="$4" dir
  dir="$tmp/bc-$name"
  mkdir -p "$dir/results" "$dir/b"
  wj "$dir/results/calibration.json" "$CAL"
  wj "$dir/b/baseline.json" \
    "{\"shape\":\"4k-randrw\",\"pressure\":\"${pressure}\",\"achieved_iops\":${achieved},\"p99_ns\":${p99},\"duration_s\":60}"
  wj "$dir/b/prediction.json" \
    "{\"cell_id\":\"bc-${name}\",\"shape\":\"4k-randrw\",\"pressure\":\"${pressure}\"}"
  python3 "$V" baseline-check "$dir/b" --results "$dir/results" 2>/dev/null
}

out="$(bcheck clean mid 19500 1550000)"
contains "$out" "baseline-check: OK" "無漂移"

# **關鍵防線**：低壓 cell 本來就只跑 25% ceiling，不得拿 achieved 比 ceiling
out="$(bcheck lowpressure low 9800 920000)"
contains "$out" "baseline-check: OK" "固定速率 cell 以該壓力目標速率為基準（不得比 ceiling）"
lacks "$out" "baseline-drift" "低壓 cell 不得因為只跑 25% ceiling 被誤判漂移"

out="$(bcheck slow mid 15000 1550000)"
contains "$out" "baseline-drift achieve-ratio" "供給達成率 < 85% → 漂移徵兆"
contains "$out" "baseline-check: DRIFT" "單次漂移記為 covariate"

out="$(bcheck lat mid 19500 2000000)"
contains "$out" "baseline-drift baseline-p99" "baseline p99 偏移 > ±15% → 漂移徵兆"

# 連續 3 個 replicate 超標 → 佇列暫停（HUMAN gate）
BCD="$tmp/bc-consec"
mkdir -p "$BCD/results"
wj "$BCD/results/calibration.json" "$CAL"
seen_human=0
for k in 1 2 3; do
  mkdir -p "$BCD/b$k"
  wj "$BCD/b$k/baseline.json" \
    '{"shape":"4k-randrw","pressure":"mid","achieved_iops":15000,"p99_ns":1550000}'
  wj "$BCD/b$k/prediction.json" \
    '{"cell_id":"bcx","shape":"4k-randrw","pressure":"mid"}'
  out="$(python3 "$V" baseline-check "$BCD/b$k" --results "$BCD/results" 2>/dev/null)"
  case "$out" in *"baseline-check: HUMAN-NEEDED recalibrate 3"*) seen_human=1 ;; esac
done
eq "$seen_human" "1" "連續 3 個 replicate 漂移 → 佇列暫停要求 recalibrate"
# 恢復正常後計數歸零
mkdir -p "$BCD/b4"
wj "$BCD/b4/baseline.json" \
  '{"shape":"4k-randrw","pressure":"mid","achieved_iops":19500,"p99_ns":1550000}'
wj "$BCD/b4/prediction.json" '{"cell_id":"bcx","shape":"4k-randrw","pressure":"mid"}'
python3 "$V" baseline-check "$BCD/b4" --results "$BCD/results" >/dev/null 2>&1
eq "$(jget "$BCD/results/baseline-drift-state.json" consecutive)" "0" "無漂移即重置連續計數"

# 固定速率 cell 的 target 等於 ceiling = 禁止的比較基準
BCB="$tmp/bc-bad"
mkdir -p "$BCB/results" "$BCB/b"
wj "$BCB/results/calibration.json" \
  '{"shapes":{"4k-randrw":{"ceiling_iops":40000,"rates":{"mid":40000},"reference_p99_ns":{"mid":1500000}}}}'
wj "$BCB/b/baseline.json" '{"shape":"4k-randrw","pressure":"mid","achieved_iops":19500,"p99_ns":1500000}'
wj "$BCB/b/prediction.json" '{"cell_id":"bad","shape":"4k-randrw","pressure":"mid"}'
out="$(python3 "$V" baseline-check "$BCB/b" --results "$BCB/results" 2>/dev/null)" \
  && fail "禁止的比較基準應非 0 退出"
contains "$out" "baseline-check: BAD-TARGET" "擋掉「固定速率 achieved 比 ceiling」的假陽性來源"

# =========================================================== schedule-estimate ==
SRES="$tmp/sres"
srep() { python3 "$MK" --results "$SRES" "$@" >/dev/null; }
mkdir -p "$SRES"

srep --cell p-osd --rep r1 --attempt t1 --fault osd-down --cap 2700 \
  --endpoint "time_to_recovery_complete_s=1000"
srep --cell p-rack --rep r1 --attempt t1 --fault rack-isolation --cap 2700 \
  --endpoint "time_to_recovery_complete_s=2000"
out="$(python3 "$V" schedule-estimate "$SRES/p-osd/r1/attempts/t1" \
  "$SRES/p-rack/r1/attempts/t1" --results "$SRES")"
contains "$out" "schedule-estimate: cap-update osd-down 2700" "2×1000 < 2700 → 保留預設 cap"
contains "$out" "schedule-estimate: cap-update rack-isolation 4000" "cap = max(2700, 2×pilot)"
contains "$out" '"type": "cap-update"' "輸出 cap-update 型 amendment"

# censored pilot：禁止把 censored 值餵進 2× 公式
srep --cell p-cen --rep r1 --attempt t1 --fault node-isolation --cap 2700 --censored \
  --endpoint "time_to_recovery_complete_s=2700"
out="$(python3 "$V" schedule-estimate "$SRES/p-cen/r1/attempts/t1" --results "$SRES" 2>/dev/null)" \
  && fail "PILOT-CENSORED 應以非 0 退出交人工 gate"
contains "$out" "schedule-estimate: PILOT-CENSORED node-isolation 2700" "偵測 censored pilot"
lacks "$out" "cap-update node-isolation" "censored pilot 不得產生 cap-update"
eq "$(jget "$SRES/schedule-estimate.json" faults.node-isolation.recommended_cap)" "null" \
   "censored pilot 不得推導 cap"
eq "$(jget "$SRES/schedule-estimate.json" faults.node-isolation.cap_x2_suggestion)" "5400" \
   "人工 gate 選項之一：cap×2 重跑 pilot"

# ======================================================================= audit ==
ARES="$tmp/ares"
arep() { python3 "$MK" --results "$ARES" "$@" >/dev/null; }
mkdir -p "$ARES"
wj "$ARES/manifest.json" \
  '{"cells":[{"cell_id":"a01","group_id":"G1","profile":"balanced","shape":"4k-randrw","pressure":"mid","fault":"osd-down","fault_params":{},"base_n":2,"targets":[1]},{"cell_id":"a02","group_id":"G1","profile":"balanced","shape":"4k-randrw","pressure":"low","fault":"osd-down","fault_params":{},"base_n":2,"targets":[1]}]}'
{
  printf '%s\n' '{"schema_version":1,"type":"extra-replicates","key":"a01","value":1,"source":"cov","seq":1}'
  printf '%s\n' '{"schema_version":1,"type":"needs-human","key":"a02/r2","value":"連續 3 次 taint","seq":2}'
  printf '%s\n' '{"schema_version":1,"type":"cap-update","key":"osd-down","value":4000,"seq":3}'
} > "$ARES/schedule-amendments.json"
wj "$ARES/descope.json" '{"cells":[{"cell_id":"a02","reason":"S3 時間不足"}]}'

arep --cell a01 --rep r1 --attempt ts1 --endpoint "max_stall_seconds=1"
arep --cell a01 --rep r1 --attempt ts2 --endpoint "max_stall_seconds=1"   # duplicate finalization
arep --cell a01 --rep r2 --attempt ts1 --endpoint "max_stall_seconds=2" --tainted
arep --cell a02 --rep r1 --attempt ts1 --endpoint "max_stall_seconds=3" --censored
arep --cell zzz --rep r1 --attempt ts1 --endpoint "max_stall_seconds=4"   # manifest 沒有的孤兒

out="$(python3 "$V" audit "$ARES" --out-dir "$tmp/audit-out" 2>/dev/null)" \
  && fail "齊備度未達應以非 0 退出"
contains "$out" "cells=2" "cell 數取自 manifest"
contains "$out" "missing=2" "缺件清單"
contains "$out" "duplicate=1" "duplicate finalization 偵測"
contains "$out" "censored=1" "censored 清單"
contains "$out" "tainted=1" "tainted 清單"
contains "$out" "needs-human=1" "needs-human 取自 amendments journal"
contains "$out" "descope=1" "descope 清單"
contains "$out" "audit: INCOMPLETE" "齊備度判定"
AJ="$ARES/audit.json"
eq "$(jget "$AJ" executions_base)" "4" "base executions = sum(base_n)"
eq "$(jget "$AJ" executions_expected)" "5" "expected = base + amendments（extra-replicates）"
eq "$(jget "$AJ" executions_done)" "3" "DONE 數不含 manifest 外的孤兒"
eq "$(jget "$AJ" unknown_cells.0.cell_id)" "zzz" "manifest 沒有的 bundle 要被點名"
eq "$(jget "$AJ" cap_updates.osd-down)" "4000" "cap-update 視圖"

# EVIDENCE-SUMMARY 落在實驗根目錄（非 results/）
SUM="$(find "$tmp/audit-out" -name 'EVIDENCE-SUMMARY-*.md' -type f | head -1)"
[ -n "$SUM" ] || fail "未產生 EVIDENCE-SUMMARY-<date>.md"
ok
grep -q '^layout: doc' "$SUM" || fail "EVIDENCE-SUMMARY 缺 frontmatter layout"
ok
grep -q '^title:' "$SUM" || fail "EVIDENCE-SUMMARY 缺 frontmatter title"
ok
for section in "缺件" "duplicate" "right-censored" "tainted" "needs-human" "descope"; do
  grep -q "$section" "$SUM" || fail "EVIDENCE-SUMMARY 缺 ${section} 章節"
  ok
done
grep -q 'zzz' "$SUM" || fail "EVIDENCE-SUMMARY 未列出孤兒 bundle"
ok

# ================================== schemas --verify（bundle 交叉核對）=========
# B5 已有 fio log + fault-timeline/censor/sampler/return-backfill/coverage-proof/prediction
VB2="$tmp/verify-bundle"
mkdir -p "$VB2"
cp -R "$B5"/. "$VB2"/
python3 "$V" aggregate "$VB2" >/dev/null
python3 "$V" verdict "$VB2" >/dev/null
for f in qos.json fio-summary.json final-clean-proof.json cleanup-proof.json; do
  printf '{}\n' > "$VB2/$f"
done
out="$(python3 "$V" schemas fault --verify "$VB2")"
contains "$out" "schemas: OK fault" "齊件且欄位一致 → 交叉核對通過"

# manifest-hash 不符
out="$(python3 "$V" schemas fault --verify "$VB2" --manifest-hash deadbeef 2>/dev/null)" \
  && fail "manifest_hash 不符應非 0 退出"
contains "$out" "schemas: MISMATCH fault" "manifest_hash 交叉核對"

# profile 不一致（prediction vs aggregate）
python3 - "$VB2/aggregate.json" <<'PYX'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["profile"] = "high_recovery_ops"
json.dump(d, open(p, "w"))
PYX
out="$(python3 "$V" schemas fault --verify "$VB2" 2>/dev/null)" && fail "profile 不一致應非 0 退出"
contains "$out" "schemas: MISMATCH" "prediction/aggregate 的 profile 必須一致"
python3 "$V" aggregate "$VB2" >/dev/null   # 還原

# coverage-proof 標 tainted → 不得 finalize 為有效 replicate
wj "$VB2/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 179))},\"gaps\":[],\"tainted\":true}"
out="$(python3 "$V" schemas fault --verify "$VB2" 2>/dev/null)" && fail "tainted 應非 0 退出"
contains "$out" "schemas: MISMATCH" "tainted attempt 不得通過 schema 核對"

# 缺件
wj "$VB2/coverage-proof.json" \
  "{\"window\":{\"start\":${T0},\"end\":$((T0 + 179))},\"gaps\":[],\"tainted\":false}"
rm -f "$VB2/qos.json"
out="$(python3 "$V" schemas fault --verify "$VB2" 2>/dev/null)" && fail "缺件應非 0 退出"
contains "$out" "缺件或空檔：qos.json" "缺件會指名檔案"

printf 'test-verdict.sh: %d assertions passed\n' "$asserts"
rm -rf "$tmp"
