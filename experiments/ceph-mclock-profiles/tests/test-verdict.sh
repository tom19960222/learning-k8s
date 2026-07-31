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

# --- 故障前 baseline 窗要用「實際觀測序列」為界，不是 coverage 窗 ---------------
# coverage 窗刻意以 fault_t0 為起點（supervisor 從注入那刻才打卡）。若拿它當
# baseline 的下界，readiness barrier 期間那 50-60s 的 fio 資料會被整個擋掉，
# baseline 窗變零寬 → p99_degradation_ratio（跨 profile 比較的主指標）每個故障
# cell 都是 null。真機第一個故障 cell 就是這樣（osd-down/extreme）。
BF="$tmp/bfault"; mkdir -p "$BF"
mkb "$BF"
# fio 序列從 T0 起，故障注在 T0+60 → 應有 60s 故障前資料可當 baseline
wj "$BF/coverage-proof.json" \
  "{\"window\":{\"start\":$((T0 + 60)),\"end\":$((T0 + 119))},\"gaps\":[],\"tainted\":false}"
wj "$BF/fault-timeline.json" \
  "{\"fault\":\"osd-down\",\"fault_t0\":$((T0 + 60)),\"measurement_cap\":2700,\"measurement_deadline\":$((T0 + 2760))}"
wj "$BF/censor-status.json" \
  "{\"censored\":false,\"censor_basis\":\"recovery_complete\",\"fault_t0\":$((T0 + 60)),\"observed_end\":$((T0 + 119)),\"measurement_cap\":2700}"
python3 "$V" aggregate "$BF" >/dev/null 2>&1 || fail "故障 aggregate 應成功"
# 注意 jget 對 None 印的是 "null" 不是 "None"——寫錯會變成永遠成立的空測試。
[ "$(jget "$BF/aggregate.json" windows.baseline.p99_ns)" != "null" ] \
  || fail "故障前 baseline 窗必須有樣本（否則主指標全 null）"
ok
eq "$(jget "$BF/aggregate.json" windows.baseline.start)" "$T0" \
  "baseline 窗下界 = 實際觀測序列起點，不是 coverage 窗起點"
[ "$(jget "$BF/aggregate.json" endpoints.p99_degradation_ratio)" != "null" ] \
  || fail "p99_degradation_ratio 不得是 null——它是跨 profile 比較的主指標"
ok
# recovery_complete_t 尚未落檔時，未被 censor 的 cell 要用 observed_end 推導
eq "$(jget "$BF/aggregate.json" endpoints.time_to_recovery_complete_s)" "59" \
  "未 censor 且缺 recovery_complete_t 時，用 observed_end - fault_t0 推導"

# --- drift 參考：同條件的 campaign 中位數，不是校準值 -------------------------
# 真機實測：所有 baseline 對校準值都是正偏移（+5.6%～+17.1%，系統性），因為校準跑在
# precondition 剛結束、且沒有 sampler/collector 併行。拿條件不同的兩者比會誤判成漂移
# ——實際就停過一次佇列，而同期吞吐是校準天花板的 109–111%，叢集根本沒變慢。
DR="$tmp/drift"; mkdir -p "$DR"
wj "$DR/calibration.json" \
  '{"shapes":{"4k":{"ceiling_iops":1000,"rates":{"high":800},"reference_p99_ns":{"high":10000000}}}}'
_mkbase() { # <cell> <rep> <p99_ns>
  local d="$DR/$1/$2/attempts/a1"; mkdir -p "$d"
  wj "$d/baseline.json" \
    "{\"shape\":\"4k\",\"pressure\":\"high\",\"target_iops\":800,\"achieved_iops\":800,\"p99_ns\":$3}"
  # 參考池按 backfill 類別配對、且只收 DONE 且未 tainted 的 attempt，所以 fixture
  # 要跟真實 bundle 一樣帶 prediction.json 與 DONE
  wj "$d/prediction.json" \
    "{\"cell_id\":\"$1\",\"fault\":\"none\",\"fault_params\":{},\"shape\":\"4k\",\"pressure\":\"high\"}"
  : > "$d/DONE"
  printf '%s\n' "$d"
}
# 先前 6 個 replicate 的 baseline 都在 ~12ms（相對校準 10ms 是 +20% 的系統性偏移）
for i in 1 2 3 4 5 6; do _mkbase "c$i" r1 12000000 >/dev/null; done
# 受測 replicate 也在 ~12ms：對校準值是 +20%（會誤報），對 campaign 中位數是 0%
B7="$(_mkbase c7 r1 12100000)"
python3 "$V" baseline-check "$B7" --results "$DR" >/dev/null 2>&1 \
  || fail "baseline-check（同條件比較）應通過"
ok
eq "$(jget "$B7/baseline-check.json" reference_source | cut -d'(' -f1)" "campaign-median-nobackfill" \
  "有足夠樣本時必須用 campaign 同條件（含同 backfill 類別）中位數當參考"
eq "$(jget "$B7/baseline-check.json" drift_signals)" "[]" \
  "系統性偏移不得誤判成漂移"

# 樣本不足（退回校準值）時不得判漂移：量到的是條件差異不是時間漂移。
# 真機實測：seq/mid 的前三個 replicate 一致 +32%（供給達成率 1.00），停了佇列；
# 每個新的 (形態,壓力) 組合都會經歷這個視窗，不排除就會反覆假停。
DR2="$tmp/drift2"; mkdir -p "$DR2"
wj "$DR2/calibration.json" \
  '{"shapes":{"4k":{"ceiling_iops":1000,"rates":{"mid":500},"reference_p99_ns":{"mid":10000000}}}}'
_mk2() { local d="$DR2/$1/r1/attempts/a1"; mkdir -p "$d"
  wj "$d/baseline.json" \
    "{\"shape\":\"4k\",\"pressure\":\"mid\",\"target_iops\":500,\"achieved_iops\":500,\"p99_ns\":$2}"
  wj "$d/prediction.json" \
    "{\"cell_id\":\"$1\",\"fault\":\"none\",\"fault_params\":{},\"shape\":\"4k\",\"pressure\":\"mid\"}"
  : > "$d/DONE"
  printf '%s\n' "$d"; }
B9="$(_mk2 n1 13500000)"   # 相對校準 10ms 是 +35%，但只有這一筆樣本
python3 "$V" baseline-check "$B9" --results "$DR2" >/dev/null 2>&1 \
  || fail "樣本不足時 baseline-check 應通過"
ok
eq "$(jget "$B9/baseline-check.json" reference_source)" "calibration" "樣本不足 → 退回校準值"
eq "$(jget "$B9/baseline-check.json" drift_signals)" "[]" \
  "非同條件參考不得判漂移（否則每個新 shape/pressure 都會假停）"

# 真漂移仍要抓到：相對 campaign 中位數大幅劣化
B8="$(_mkbase c8 r1 20000000)"
python3 "$V" baseline-check "$B8" --results "$DR" >/dev/null 2>&1
grep -q 'baseline-p99' "$B8/baseline-check.json" \
  || fail "相對同條件中位數的真劣化必須觸發 drift 訊號"
ok

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

bcheck() { # bcheck <name> <pressure> <achieved> <p99> [prior-p99] ; 印機器行
  local name="$1" pressure="$2" achieved="$3" p99="$4" prior="${5:-}" dir i
  dir="$tmp/bc-$name"
  mkdir -p "$dir/results" "$dir/b"
  wj "$dir/results/calibration.json" "$CAL"
  # p99 漂移只在「同條件」參考下才判定，所以要測 p99 訊號就得先鋪 campaign 樣本
  # （樣本不足會退回校準值，那是條件差異不是時間漂移——見下方測試）。
  if [ -n "$prior" ]; then
    for i in 1 2 3; do
      mkdir -p "$dir/results/prior$i/r1/attempts/a1"
      wj "$dir/results/prior$i/r1/attempts/a1/baseline.json" \
        "{\"shape\":\"4k-randrw\",\"pressure\":\"${pressure}\",\"achieved_iops\":${achieved},\"p99_ns\":${prior}}"
      # 參考池按 backfill 類別配對 → prior 要有 prediction.json 的 fault/fault_params
      # 與 DONE（未 finalize 的 attempt 不進池）
      wj "$dir/results/prior$i/r1/attempts/a1/prediction.json" \
        "{\"cell_id\":\"prior$i\",\"fault\":\"osd-down\",\"fault_params\":{\"manual_out\":true},\"shape\":\"4k-randrw\",\"pressure\":\"${pressure}\"}"
      : > "$dir/results/prior$i/r1/attempts/a1/DONE"
    done
  fi
  wj "$dir/b/baseline.json" \
    "{\"shape\":\"4k-randrw\",\"pressure\":\"${pressure}\",\"achieved_iops\":${achieved},\"p99_ns\":${p99},\"duration_s\":60}"
  wj "$dir/b/prediction.json" \
    "{\"cell_id\":\"bc-${name}\",\"fault\":\"osd-down\",\"fault_params\":{\"manual_out\":true},\"shape\":\"4k-randrw\",\"pressure\":\"${pressure}\"}"
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

out="$(bcheck lat mid 19500 2000000 1550000)"
contains "$out" "baseline-drift baseline-p99" "相對同條件中位數偏移 > ±15% → 漂移徵兆"

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

# --- drift 參考池必須「同 backfill 類別」（「參考基準不可比」缺陷第三次）--------
# baseline.json 不是注入前的 baseline，而是「注入 → 回復 → final_clean 之後」的 60s
# 復測，量到的是**善後成本**。真機實測（DONE 且未 tainted 的 attempt，4k）：
#   4k/mid  none 3.523ms(n=9)、flapping 3.654ms(n=6)、osd-down 5.210ms(n=3)、
#           node-isolation 4.817ms(n=1)
#   4k/low  none 2.834ms(n=9)、flapping 3.015ms(n=4)、osd-down 4.284ms(n=6)
# 分界**不是故障型**：flapping 與 none 差 3.2%/7.0%（全 attempt 子集，容忍度內），
# 因為 flapping 全程 noout、不 out；真正拉開的是「有沒有把 OSD 標 out 而觸發
# backfill」。所以參考池按二元 backfill 類別配對，判準從 manifest 已宣告的
# fault_params 推導（manual_out → backfill；no_out / none → 非 backfill）。
BCF="$tmp/bc-class"
BCF_CAL='{"shapes":{"4k":{"ceiling_iops":40000,"rates":{"mid":20000},"reference_p99_ns":{"mid":3600000}}}}'
FP_OSD_DOWN='{"manual_out":true,"measurement_cap":2700}'
FP_NODE_ISO='{"nodes":1,"manual_out":true}'
FP_SEQ_CONT='{"fault":"osd-down","manual_out":true}'
FP_FLAPPING='{"cycles":10,"no_out":true}'
FP_CHAOS='{"seed":4242,"duration":1800}'
_mkb() { # _mkb <results> <cell> <fault> <fault_params> <p99_ns> [done|no-done|tainted|corrupt]
  local r="$1" cell="$2" fault="$3" fp="$4" p99="$5" flag="${6:-done}"
  local d="$r/$cell/r1/attempts/a1"
  wj "$d/baseline.json" \
    "{\"shape\":\"4k\",\"pressure\":\"mid\",\"target_iops\":20000,\"achieved_iops\":20000,\"p99_ns\":${p99}}"
  wj "$d/prediction.json" \
    "{\"cell_id\":\"${cell}\",\"fault\":\"${fault}\",\"fault_params\":${fp},\"shape\":\"4k\",\"pressure\":\"mid\"}"
  case "$flag" in
    no-done) ;;                                     # 未 finalize
    tainted) : > "$d/DONE"; wj "$d/coverage-proof.json" '{"tainted":true}' ;;
    corrupt) : > "$d/DONE"; printf '{"cell_id":"%s","fault":' "$cell" > "$d/prediction.json" ;;
    *)       : > "$d/DONE" ;;
  esac
  printf '%s\n' "$d"
}
_mkb_pool() { # _mkb_pool <results>：6 個非 backfill(3.654ms) + 2 個 backfill(5.210ms)
  local r="$1" i
  wj "$r/calibration.json" "$BCF_CAL"
  for i in 1 2 3 4 5 6; do
    _mkb "$r" "flapping-4k-mid+p$i" flapping "$FP_FLAPPING" 3654000 >/dev/null
  done
  for i in 1 2; do
    _mkb "$r" "osd-down-4k-mid+p$i" osd-down "$FP_OSD_DOWN" 5210000 >/dev/null
  done
}

# (1) 同類別樣本不足（backfill 只有 2 個）→ 不得拿非 backfill 的池子當參考。
# 且「量不了」≠「沒漂移」：consecutive 必須**維持**，不得歸零也不得累加。
BCF1="$BCF/mixed"; mkdir -p "$BCF1"; _mkb_pool "$BCF1"
wj "$BCF1/baseline-drift-state.json" '{"consecutive":2,"recent":["earlier"]}'
BF1="$(_mkb "$BCF1" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5210000)"
out="$(python3 "$V" baseline-check "$BF1" --results "$BCF1" 2>/dev/null)"
contains "$out" "baseline-check: OK covariate-only" \
  "退回時 stdout 要能看出「這格沒開偵測」，不能和正常通過同一行"
lacks "$out" "baseline-drift" "混類別中位數造成的假漂移必須消失"
lacks "$out" "HUMAN-NEEDED" "殘留的 consecutive 不得讓沒有訊號的 execution 停佇列"
eq "$(jget "$BF1/baseline-check.json" reference_source)" "calibration" \
  "同類別樣本 <3 → 退回 covariate-only（參考值仍記錄）"
eq "$(jget "$BF1/baseline-check.json" drift_signals)" "[]" "退回時不得產生 drift signal"
eq "$(jget "$BF1/baseline-check.json" measured)" "False" "退回時要標明 p99 軸沒有量到"
# 退回 = 不判漂移，但值一定要留著（之後人工回看才有得比）
[ "$(jget "$BF1/baseline-check.json" p99_shift)" != "null" ] \
  || fail "退回 covariate-only 時仍要記下 p99_shift"
ok
eq "$(jnum "$BF1/baseline-check.json" baseline_p99_ns)" "5210000" "退回時仍要記下這次的復測 p99"
eq "$(jget "$BCF1/baseline-drift-state.json" consecutive)" "2" \
  "量不了時 consecutive 必須維持（歸零會把跨 group 邊界前的漂移證據抹掉）"
eq "$(jget "$BCF1/baseline-drift-state.json" recent.0)" "earlier" "維持時 recent 也不得被清掉"

# (2) 同類別 >=3 → 參考值 = 同類別中位數；node-isolation 與 osd-down 同池（二元分組）
BCF2="$BCF/paired"; mkdir -p "$BCF2"; _mkb_pool "$BCF2"
_mkb "$BCF2" "node-isolation-4k-mid+p1" node-isolation "$FP_NODE_ISO" 5210000 >/dev/null
wj "$BCF2/baseline-drift-state.json" '{"consecutive":2,"recent":["earlier"]}'
BF2="$(_mkb "$BCF2" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5400000)"
out="$(python3 "$V" baseline-check "$BF2" --results "$BCF2" 2>/dev/null)"
contains "$out" "baseline-check: OK" "同類別比較下的正常復測不得判漂移"
lacks "$out" "covariate-only" "有量到就不該標 covariate-only"
eq "$(jget "$BF2/baseline-check.json" reference_source)" "campaign-median-backfill(n=3)" \
  "ref_source 要看得出是同 backfill 類別配對（含樣本數）"
eq "$(jnum "$BF2/baseline-check.json" reference_p99_ns)" "5210000" \
  "參考值 = 同類別中位數（混類別會拿到 3654000）"
eq "$(jget "$BF2/baseline-check.json" backfill_class)" "backfill" \
  "manual_out 的故障（osd-down / node-isolation）歸 backfill 組"
eq "$(jget "$BF2/baseline-check.json" measured)" "True" "有同類別參考 = p99 軸有量到"
eq "$(jget "$BF2/baseline-check.json" drift_signals)" "[]" "同類別比較下的正常復測不得判漂移"
eq "$(jget "$BCF2/baseline-drift-state.json" consecutive)" "0" \
  "量到了且在容忍內 → consecutive 歸零"

# (3) flapping 與 none 同屬非 backfill 組（真機：兩者差 3.2%/7.0%，在容忍度內）
BCF5="$BCF/nobackfill"; mkdir -p "$BCF5"; _mkb_pool "$BCF5"
BF6="$(_mkb "$BCF5" "none-4k-mid+cur" none '{}' 3600000)"
out="$(python3 "$V" baseline-check "$BF6" --results "$BCF5" 2>/dev/null)"
eq "$(jget "$BF6/baseline-check.json" backfill_class)" "nobackfill" \
  "none 與 flapping（no_out）同屬非 backfill 組"
eq "$(jget "$BF6/baseline-check.json" reference_source)" "campaign-median-nobackfill(n=6)" \
  "穩態要拿得到 flapping 的參考（否則每個新 group 開頭都盲）"
eq "$(jget "$BF6/baseline-check.json" drift_signals)" "[]" "非 backfill 組內的正常復測不得判漂移"

# (4) 同類別的真漂移仍要抓到，且 consecutive 要累加
BF3="$(_mkb "$BCF2" "osd-down-4k-mid+cur2" osd-down "$FP_OSD_DOWN" 7500000)"
out="$(python3 "$V" baseline-check "$BF3" --results "$BCF2" 2>/dev/null)"
contains "$out" "baseline-drift baseline-p99" "同類別下的真劣化必須觸發 drift 訊號"
contains "$(jget "$BF3/baseline-check.json" reference_source)" "campaign-median-backfill" \
  "真漂移判定必須建立在同類別配對的參考上"
eq "$(jget "$BCF2/baseline-drift-state.json" consecutive)" "1" "量到且超標 → consecutive 累加"

# (5) seq-contention 的機制就是 osd-down（fault_params 帶 manual_out）→ 必須歸 backfill
BCF6="$BCF/seqcont"; mkdir -p "$BCF6"; _mkb_pool "$BCF6"
_mkb "$BCF6" "osd-down-4k-mid+p3" osd-down "$FP_OSD_DOWN" 5210000 >/dev/null
BF7="$(_mkb "$BCF6" "seq-contention-4k-mid+cur" seq-contention "$FP_SEQ_CONT" 5210000)"
python3 "$V" baseline-check "$BF7" --results "$BCF6" >/dev/null 2>&1
eq "$(jget "$BF7/baseline-check.json" backfill_class)" "backfill" \
  "seq-contention 的實際機制是 osd-down（manual_out）→ 歸 backfill 組"

# (6) chaos：原始碼沒有 manual out，但也沒有 noout 保護 → 保守歸 backfill
BCF7="$BCF/chaos"; mkdir -p "$BCF7"; _mkb_pool "$BCF7"
BF8="$(_mkb "$BCF7" "chaos-4k-mid+cur" chaos "$FP_CHAOS" 5210000)"
python3 "$V" baseline-check "$BF8" --results "$BCF7" >/dev/null 2>&1
eq "$(jget "$BF8/baseline-check.json" backfill_class)" "backfill" \
  "chaos 無 noout 保護、可能被 auto-out → 保守歸 backfill"

# (7) 分類不明（未知故障型、prediction 缺 fault）→ 不配對、退回 covariate-only。
# 池子裡刻意也放 3 個分類不明的舊 bundle：「不明」不是一個類別，不得互相配對。
BCF3="$BCF/unknown"; mkdir -p "$BCF3"; _mkb_pool "$BCF3"
for i in 1 2 3; do
  d="$BCF3/legacy-4k-mid+p$i/r1/attempts/a1"
  wj "$d/baseline.json" \
    '{"shape":"4k","pressure":"mid","target_iops":20000,"achieved_iops":20000,"p99_ns":3000000}'
  : > "$d/DONE"
done
BF4="$(_mkb "$BCF3" "brandnew-4k-mid+cur" brand-new-fault '{}' 5210000)"
out="$(python3 "$V" baseline-check "$BF4" --results "$BCF3" 2>/dev/null)"
eq "$(jget "$BF4/baseline-check.json" backfill_class)" "null" \
  "未知故障型（沒宣告 manual_out/no_out）要如實記 null，不得亂猜"
eq "$(jget "$BF4/baseline-check.json" reference_source)" "calibration" \
  "分類不明 → 不配對、退回 covariate-only"
eq "$(jget "$BF4/baseline-check.json" drift_signals)" "[]" "分類不明時不得判漂移"

# (8) 沒有 prediction.json 的舊 bundle 不算同類別樣本
BCF4="$BCF/legacy"; mkdir -p "$BCF4"; _mkb_pool "$BCF4"
for i in 1 2 3; do
  d="$BCF4/legacy-4k-mid+p$i/r1/attempts/a1"
  wj "$d/baseline.json" \
    '{"shape":"4k","pressure":"mid","target_iops":20000,"achieved_iops":20000,"p99_ns":5210000}'
  : > "$d/DONE"
done
BF5="$(_mkb "$BCF4" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5210000)"
python3 "$V" baseline-check "$BF5" --results "$BCF4" >/dev/null 2>&1
eq "$(jget "$BF5/baseline-check.json" reference_source)" "calibration" \
  "分類不明的舊 bundle 不得被算成同類別樣本"

# (9) 損毀的 prior prediction.json 不得讓整個 gate 死掉。
# pipeline 只認 rc=4 與 stdout 的 baseline-drift，rc=1 會被靜默吞掉還順手 drift-clear
# → 漂移偵測從此永久靜默失效。而 prediction.json 正是全 bundle 唯一非 atomic 的寫入。
BCF8="$BCF/corrupt"; mkdir -p "$BCF8"; _mkb_pool "$BCF8"
for i in 3 4 5; do
  _mkb "$BCF8" "osd-down-4k-mid+p$i" osd-down "$FP_OSD_DOWN" 5210000 >/dev/null
done
_mkb "$BCF8" "osd-down-4k-mid+broken" osd-down "$FP_OSD_DOWN" 9999000 corrupt >/dev/null
BF9="$(_mkb "$BCF8" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5210000)"
out="$(python3 "$V" baseline-check "$BF9" --results "$BCF8" 2>/dev/null)" \
  || fail "prior 的 prediction.json 損毀不得讓 baseline-check 非 0 退出"
ok
eq "$(jget "$BF9/baseline-check.json" reference_source)" "campaign-median-backfill(n=5)" \
  "損毀的 prior 只是不進池（n=5 而非 6），其餘照常比較"

# (10) 當前 bundle 自己的 prediction.json 損毀 → 也不得死掉，退回 covariate-only
BCF9="$BCF/corrupt-self"; mkdir -p "$BCF9"; _mkb_pool "$BCF9"
BF10="$(_mkb "$BCF9" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5210000 corrupt)"
out="$(python3 "$V" baseline-check "$BF10" --results "$BCF9" 2>/dev/null)" \
  || fail "當前 bundle 的 prediction.json 損毀不得讓 baseline-check 非 0 退出"
ok
contains "$out" "covariate-only" "自己的分類讀不到 → 退回 covariate-only"
eq "$(jget "$BF10/baseline-check.json" backfill_class)" "null" "讀不到就記 null，不猜"

# (11) 參考池只收「DONE 且未 tainted」的 attempt（harness 自己判定無效的不得當基準）
BCF10="$BCF/invalid"; mkdir -p "$BCF10"; _mkb_pool "$BCF10"
_mkb "$BCF10" "osd-down-4k-mid+p3" osd-down "$FP_OSD_DOWN" 5210000 >/dev/null
_mkb "$BCF10" "osd-down-4k-mid+nodone" osd-down "$FP_OSD_DOWN" 20000000 no-done >/dev/null
_mkb "$BCF10" "osd-down-4k-mid+taint" osd-down "$FP_OSD_DOWN" 20000000 tainted >/dev/null
BF11="$(_mkb "$BCF10" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5210000)"
python3 "$V" baseline-check "$BF11" --results "$BCF10" >/dev/null 2>&1
eq "$(jget "$BF11/baseline-check.json" reference_source)" "campaign-median-backfill(n=3)" \
  "未 finalize（無 DONE）與 tainted 的 attempt 都不得進參考池"
eq "$(jnum "$BF11/baseline-check.json" reference_p99_ns)" "5210000" \
  "無效樣本若進池會把中位數拉到 5.21/20ms 之間"

# (12) HUMAN-NEEDED 只在「這次真的量到且超標」時才發：殘留的 consecutive 不得讓
# 一格「量不了」的 cell 直接停佇列（維持語意與停佇列判定的交互作用）。
BCF11="$BCF/stale"; mkdir -p "$BCF11"; _mkb_pool "$BCF11"
wj "$BCF11/baseline-drift-state.json" '{"consecutive":3,"recent":[]}'
BF12="$(_mkb "$BCF11" "osd-down-4k-mid+cur" osd-down "$FP_OSD_DOWN" 5210000)"
out="$(python3 "$V" baseline-check "$BF12" --results "$BCF11" 2>/dev/null)" \
  || fail "殘留 consecutive=3 + 量不了 → 不得非 0 退出（rc=4 會停佇列）"
ok
lacks "$out" "HUMAN-NEEDED" "沒有訊號的 execution 不得因為殘留計數而停佇列"
eq "$(jget "$BCF11/baseline-drift-state.json" consecutive)" "3" "殘留計數維持不變（要人工清）"

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
