#!/usr/bin/env bash
# Task 7 — lib/fio.sh：RBD image / krbd map / client tuning / job render 契約 /
# 背景 fio + readiness barrier + exit proof / steady + baseline / calibrate /
# raw NVMe 基線 guard / smoke-real parser 校正。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
GEN_LOGS="$here/fixtures/gen-fio-logs.py"
GEN_JSON="$here/fixtures/gen-fio-json.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-fio.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { grep -qF -- "$2" "$1" || fail "$3：未含 [$2]"; ok; }
hasnt() { grep -qF -- "$2" "$1" && fail "$3：不該含 [$2]"; ok; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1" "$2"; }

export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export RESULTS_DIR="$tmp/results"
export POLL_INTERVAL=0.05
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export FIO_READINESS_SECS=1
export FIO_RUN_SLACK_SECS=1
export FIO_PRECOND_SECS=1

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }
wf() { printf '%s\n' "$2" > "$1"; }

# 把某次 ssh 呼叫內嵌的 base64 payload 解回明文（remote_bg_start 與 _fio_run_script
# 都以 base64 過線，只驗 argv 會漏掉真正送出去的腳本內容）。
decode_call() { # <call-index>
  python3 - "$FAKE_SSH_STATE/call.$1.args" <<'PY'
import base64
import re
import sys

PAT = re.compile(r"printf %s '([A-Za-z0-9+/=]+)'")


def expand(text, depth=0):
    """遞迴展開：remote_bg_start 的 payload 裡還包著 job 檔的 base64。"""
    out = [text]
    if depth > 4:
        return out
    for m in PAT.finditer(text):
        try:
            inner = base64.b64decode(m.group(1)).decode("utf-8", "replace")
        except Exception:
            continue
        out.extend(expand(inner, depth + 1))
    return out


sys.stdout.write("\n".join(expand(open(sys.argv[1]).read())))
PY
}
decode_all() { # 全部呼叫的解碼結果串起來（找「某段腳本有沒有送出去」）
  local n i
  n="$(cat "$FAKE_SSH_STATE/count" 2>/dev/null || echo 0)"
  i=1
  while [ "$i" -le "$n" ]; do decode_call "$i"; i=$((i + 1)); done
}

# shellcheck source=../lib/fio.sh
. "$root/lib/fio.sh"
inventory_load "$fixture"
cleanup_push "rm -rf '$tmp'"
mkdir -p "$RESULTS_DIR"

CLIENTS="mclock-client-1 mclock-client-2 mclock-client-3 mclock-client-4"

# =============================================================== fio_render_job ==
# 1) 4K randrw 70/30 的完整 time-series 契約（plan Global Constraints「fio 常數」）
J4K="$tmp/job-4k.ini"
fio_render_job 4k steady 20000 > "$J4K" || fail "fio_render_job 4k steady 應成功"
ok
for k in ioengine=libaio direct=1 randseed=4242 time_based=1 \
         log_avg_msec=1000 log_hist_msec=1000 log_unix_epoch=1 \
         write_iops_log= write_lat_log= write_hist_log= \
         rw=randrw rwmixread=70 bs=4k iodepth=16 numjobs=4 \
         runtime=300 ramp_time=30; do
  has "$J4K" "$k" "4k steady job 契約"
done
# 逐秒 histogram 是 brownout 判準的唯一來源：coarseness 必須顯式為 0（全 bin）
has "$J4K" "log_hist_coarseness=0" "hist log 必須是全 bin"
# 供給速率是「aggregate → per-job」反推：20000 / (numjobs 4 × client 4) = 1250
# randrw 70/30 → 讀 875 / 寫 375（兩者相加 = per-job 1250，aggregate 才等於 20000）
has "$J4K" "rate_iops=875,375" "4k 的 per-job rate 反推（含 70/30 拆分）"

# 2) 1M seq write
JSQ="$tmp/job-seq.ini"
fio_render_job seq steady 1600 > "$JSQ" || fail "fio_render_job seq steady 應成功"
ok
for k in rw=write bs=1M iodepth=8 numjobs=2 log_unix_epoch=1; do
  has "$JSQ" "$k" "seq steady job 契約"
done
hasnt "$JSQ" "rwmixread" "純寫形態不得有 rwmixread"
has "$JSQ" "rate_iops=200" "seq 的 per-job rate（1600 / (2 × 4)）"

# 3) 極端壓 = 閉迴路：不得出現 rate_iops
JEX="$tmp/job-extreme.ini"
fio_render_job 4k steady 0 > "$JEX" || fail "極端壓 render 應成功"
ok
hasnt "$JEX" "rate_iops" "極端壓（不限速）不得有 rate_iops"

# 4) mode 決定 runtime/ramp
fio_render_job 4k baseline 20000 > "$tmp/job-base.ini"
has "$tmp/job-base.ini" "runtime=60" "baseline 復測 = 60s"
fio_render_job 4k smoke 0 > "$tmp/job-smoke.ini"
has "$tmp/job-smoke.ini" "runtime=60" "smoke-real = 60s"

# 5) precondition = 全量寫，不是 time_based，也不需要逐秒 log
fio_render_job seq precondition 0 > "$tmp/job-pre.ini"
has "$tmp/job-pre.ini" "rw=write" "precondition 是循序寫"
hasnt "$tmp/job-pre.ini" "time_based" "precondition 不得 time_based（要寫滿整顆 image）"
hasnt "$tmp/job-pre.ini" "write_iops_log" "precondition 不需要逐秒 log"

# 6) 未知 shape / mode 一律 die
( fio_render_job nosuch steady 100 ) >/dev/null 2>&1 && fail "未知 shape 應 die"
ok
( fio_render_job 4k nosuch 100 ) >/dev/null 2>&1 && fail "未知 mode 應 die"
ok

# ============================================================== fio_setup_images ==
# 7) 四顆 fio-c1..c4，各 300 GiB，以 --id mclock-fio 建立
reset_ssh
i=1
for c in $CLIENTS; do
  wf "$tmp/ls-empty.$i" ""
  python3 - "$tmp/info.$i" <<'PY'
import json
import sys
with open(sys.argv[1], "w") as fh:
    json.dump({"name": "img", "size": 322122547200, "objects": 76800}, fh)
PY
  expect_ssh "mclock-imgcheck-${c};" 0 0 "$tmp/ls-empty.$i"
  expect_ssh "mclock-imgcreate-${c};" 0 0 ""
  expect_ssh "mclock-imginfo-${c};" 0 0 "$tmp/info.$i"
  i=$((i + 1))
done
out="$(fio_setup_images)" || fail "fio_setup_images 應成功"
ok
eq "$out" "fio-images: PASS 4" "setup_images 機器行"
payload="$(decode_all)"
printf '%s\n' "$payload" > "$tmp/imgpayload.txt"
has "$tmp/imgpayload.txt" "--id mclock-fio" "rbd 指令必須帶 --id mclock-fio"
has "$tmp/imgpayload.txt" "create fio-c1 --size 307200" "fio-c1 = 300 GiB"
has "$tmp/imgpayload.txt" "create fio-c4 --size 307200" "fio-c4 = 300 GiB"

# 8) 已存在即跳過建立（冪等）
reset_ssh
i=1
for c in $CLIENTS; do
  wf "$tmp/ls-have.$i" "fio-c${i}"
  expect_ssh "mclock-imgcheck-${c};" 0 0 "$tmp/ls-have.$i"
  expect_ssh "mclock-imginfo-${c};" 0 0 "$tmp/info.$i"
  i=$((i + 1))
done
fio_setup_images >/dev/null || fail "冪等路徑應成功"
ok
decode_all > "$tmp/imgpayload2.txt"
hasnt "$tmp/imgpayload2.txt" "rbd -p mclock --id mclock-fio create" "image 已存在不得重建"

# 9) 大小不符 → die（300 GiB 是 20–30% 填充率的前提）
reset_ssh
python3 - "$tmp/info-small" <<'PY'
import json
import sys
with open(sys.argv[1], "w") as fh:
    json.dump({"name": "img", "size": 1073741824}, fh)
PY
wf "$tmp/ls-have.1" "fio-c1"
expect_ssh "mclock-imgcheck-mclock-client-1;" 0 0 "$tmp/ls-have.1"
expect_ssh "mclock-imginfo-mclock-client-1;" 0 0 "$tmp/info-small"
( fio_setup_images ) >/dev/null 2>&1 && fail "image 大小不符應 die"
ok

# ========================================================= fio_map_all / unmap ==
mk_devlist() { # <file> <image|-> <dev>
  python3 - "$@" <<'PY'
import json
import sys
out, image, dev = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
if image != "-":
    rows.append({"id": dev.replace("/dev/rbd", ""), "pool": "mclock",
                 "namespace": "", "name": image, "snap": "-", "device": dev})
with open(out, "w") as fh:
    json.dump(rows, fh)
PY
}

# 10) map 後必須留下 /dev/rbdX 對應與 map options
reset_ssh
i=1
for c in $CLIENTS; do
  mk_devlist "$tmp/dl-empty.$i" - "/dev/rbd$((i - 1))"
  mk_devlist "$tmp/dl-have.$i" "fio-c${i}" "/dev/rbd$((i - 1))"
  wf "$tmp/mapout.$i" "/dev/rbd$((i - 1))"
  expect_ssh "mclock-maplist-${c};" 0 0 "$tmp/dl-empty.$i"
  expect_ssh "mclock-map-${c};" 0 0 "$tmp/mapout.$i"
  expect_ssh "mclock-maplist2-${c};" 0 0 "$tmp/dl-have.$i"
  i=$((i + 1))
done
out="$(fio_map_all)" || fail "fio_map_all 應成功"
ok
eq "$out" "fio-map: PASS 4" "map_all 機器行"
MAPJSON="$RESULTS_DIR/rbd-map.json"
[ -s "$MAPJSON" ] || fail "rbd-map.json 未寫入"
ok
eq "$(jget "$MAPJSON" clients.mclock-client-1.device)" "/dev/rbd0" "記錄 /dev/rbdX 對應"
eq "$(jget "$MAPJSON" clients.mclock-client-3.image)" "fio-c3" "記錄 image 對應"
has "$MAPJSON" "map_options" "必須記錄 map options（環境快照的一部分）"
has "$MAPJSON" "device_list" "必須留 rbd device list 原始輸出"
# 真機首跑踩到：`rbd device list|unmap` 是系統層操作，帶 `-p` 會 unrecognised option。
# 指令是 base64 過線的，log 裡看不到明文，也因此 fake ssh 的子字串比對守不住——
# 必須把 argv 裡的 base64 解出來對真正送出去的指令斷言。
_decoded_cmds="$(sed -n "s/.*printf %s '\([A-Za-z0-9+/=]*\)'.*/\1/p" "$FAKE_SSH_LOG" \
  | while IFS= read -r b; do printf '%s' "$b" | base64 --decode 2>/dev/null; printf '\n'; done)"
if printf '%s\n' "$_decoded_cmds" | grep -F 'device list' | grep -qF -- '-p '; then
  fail "rbd device list 不得帶 -p（pool 選項只有 pool 層子命令吃）"
fi
ok
if printf '%s\n' "$_decoded_cmds" | grep -F 'device unmap' | grep -qF -- '-p '; then
  fail "rbd device unmap 不得帶 -p"
fi
ok
# 反向自證：解碼真的有抓到指令（否則上面兩條又是空過）
printf '%s\n' "$_decoded_cmds" | grep -qF 'device list' \
  || fail "解碼後應看得到 device list 指令（斷言不得空過）"
ok
eq "$(fio_device mclock-client-2)" "/dev/rbd1" "fio_device 由 map 記錄查裝置"

# 11) 已 map 即不重複 map（冪等）
reset_ssh
i=1
for c in $CLIENTS; do
  expect_ssh "mclock-maplist-${c};" 0 0 "$tmp/dl-have.$i"
  i=$((i + 1))
done
fio_map_all >/dev/null || fail "已 map 的冪等路徑應成功"
ok
hasnt "$FAKE_SSH_LOG" "mclock-map-mclock-client-1;" "已 map 不得再 map"

# 12) unmap：有 map 才 unmap，冪等
reset_ssh
i=1
for c in $CLIENTS; do
  expect_ssh "mclock-maplist-${c};" 0 0 "$tmp/dl-have.$i"
  expect_ssh "mclock-unmap-${c};" 0 0 ""
  i=$((i + 1))
done
out="$(fio_unmap_all)" || fail "fio_unmap_all 應成功"
ok
eq "$out" "fio-unmap: PASS 4" "unmap_all 機器行"
reset_ssh
i=1
for c in $CLIENTS; do
  expect_ssh "mclock-maplist-${c};" 0 0 "$tmp/dl-empty.$i"
  i=$((i + 1))
done
out="$(fio_unmap_all)" || fail "未 map 時 unmap 應成功（冪等）"
ok
eq "$out" "fio-unmap: PASS 0" "沒東西可 unmap 時回 0"

# ============================================================== client tuning ==
# 重新建立 map 記錄（前一段的 unmap 測試不影響 rbd-map.json）
tune_expect_apply() {
  local c
  for c in $CLIENTS; do
    wf "$tmp/tune.$c" "$(printf '[mq-deadline] none\n128\ntuned')"
    expect_ssh "mclock-tune-${c};" 0 0 "$tmp/tune.$c"
  done
}
# 13) apply：scheduler=none + readahead 固定，且原值要留存供 restore
reset_ssh
tune_expect_apply
out="$(client_tuning_apply)" || fail "client_tuning_apply 應成功"
ok
eq "$out" "client-tuning: PASS 4" "client_tuning_apply 機器行"
TUNEJSON="$RESULTS_DIR/client-tuning.json"
[ -s "$TUNEJSON" ] || fail "client-tuning.json 未寫入"
ok
eq "$(jget "$TUNEJSON" clients.mclock-client-1.original_scheduler)" "mq-deadline" "留存原 scheduler"
eq "$(jget "$TUNEJSON" clients.mclock-client-1.original_read_ahead_kb)" "128" "留存原 readahead"
decode_all > "$tmp/tunepayload.txt"
has "$tmp/tunepayload.txt" "/sys/block/rbd0/queue/scheduler" "以 sysfs 路徑設定 scheduler"
has "$tmp/tunepayload.txt" "/sys/block/rbd0/queue/read_ahead_kb" "以 sysfs 路徑設定 readahead"

# 14) verify：apply 後必須回讀確認
reset_ssh
for c in $CLIENTS; do
  wf "$tmp/tv.$c" "$(printf 'mq-deadline [none]\n128')"
  expect_ssh "mclock-tuneverify-${c};" 0 0 "$tmp/tv.$c"
done
out="$(client_tuning_verify)" || fail "client_tuning_verify 應通過"
ok
eq "$out" "client-tuning-verify: PASS 4" "verify 機器行"

# 15) verify 不符 → die（設定沒生效卻繼續量測 = 全組資料作廢）
reset_ssh
for c in $CLIENTS; do
  wf "$tmp/tvbad.$c" "$(printf '[mq-deadline] none\n128')"
  expect_ssh "mclock-tuneverify-${c};" 0 0 "$tmp/tvbad.$c"
done
( client_tuning_verify ) >/dev/null 2>&1 && fail "scheduler 未生效應 die"
ok

# 16) restore：campaign 收尾把原值寫回去
reset_ssh
for c in $CLIENTS; do
  expect_ssh "mclock-tunerestore-${c};" 0 0 ""
done
out="$(client_tuning_restore)" || fail "client_tuning_restore 應成功"
ok
eq "$out" "client-tuning-restore: PASS 4" "restore 機器行"
decode_all > "$tmp/restorepayload.txt"
has "$tmp/restorepayload.txt" "mq-deadline" "restore 必須寫回原值而非硬編碼預設"

# ========================================== 背景 fio：start / readiness / stop ==
# 合成一個 client 的遠端工作目錄 tarball（fio 三 log + segment JSON + exit-code）
mk_tar() { # <tar-path> <seconds> <read-iops> <write-iops> <p99-ns> [--no-hist|--json-only]
  local tarp="$1" secs="$2" riops="$3" wiops="$4" p99="$5" variant="${6:-}"
  local d="$tmp/wd.$$.$RANDOM"
  mkdir -p "$d"
  # --json-only：summary 只讀 seg*.json，逐秒 log 產生器很貴（1856 bin × 每秒），
  # 不需要 log 的情境（calibrate 的 7 段）就別產。
  if [ "$variant" != "--json-only" ]; then
    python3 "$GEN_LOGS" --out "$d" --seg seg01 --job 1 --start 1800000000 \
      --seconds "$secs" --iops "$riops" --lat-ns "$p99" >/dev/null
    [ "$variant" = "--no-hist" ] && rm -f "$d"/seg01_clat_hist.1.log
  fi
  python3 "$GEN_JSON" --out "$d/seg01.json" --read-iops "$riops" \
    --write-iops "$wiops" --p99-ns "$p99" >/dev/null
  printf '0\n' > "$d/exit-code"
  printf '0\n' > "$d/exit-code.seg01"
  ( cd "$d" && tar cf "$tarp" . )
  rm -rf "$d"
}

TAR_OK="$tmp/wd-ok.tar"
mk_tar "$TAR_OK" 60 1000 400 1500000

expect_start() { # <mode>
  local c
  wf "$tmp/pid.txt" "4242"
  for c in $CLIENTS; do
    expect_ssh "fio-${1}-${c}.pid" 0 0 "$tmp/pid.txt"
    # 與 fio 併行啟動的逐秒裝置取樣器（readiness 的資料來源）
    expect_ssh "fio-${1}-${c}-devstat.pid" 0 0 "$tmp/pid.txt"
  done
}
expect_wait_done() {
  local c
  wf "$tmp/done0.txt" "DONE 0"
  for c in $CLIENTS; do
    expect_ssh "mclock-wait-${c};" 0 0 "$tmp/done0.txt"
  done
}
expect_stop() { # <mode> <tar> [exit-code]
  local c
  wf "$tmp/stopout.txt" \
    "$(printf 'EXIT %s\nHB 1800000060\nSEG 1\nNOW 1800000062' "${3:-0}")"
  for c in $CLIENTS; do
    expect_ssh "mclock-signal-${c};" 0 0 ""
  done
  for c in $CLIENTS; do
    expect_ssh "mclock-stop-${c};" 0 0 "$tmp/stopout.txt"
    expect_ssh "fio-${1}-${c}.pid" 0 0 ""
    # 取樣器是無窮迴圈，不停掉會讓下一個 replicate 的 start 因 registry 有活 pid 而 die
    expect_ssh "fio-${1}-${c}-devstat.pid" 0 0 ""
    expect_ssh "mclock-fetch-${c};" 0 0 "$2"
  done
}
expect_readiness() { # <seconds> <iops>
  # readiness 讀的是與 fio 併行的逐秒裝置取樣器寫出的 devstat.log（累計計數），
  # 不是 fio 的逐秒 log——後者跑完才落地，執行中讀不到（真機首跑就栽在這）。
  local c i
  : > "$tmp/devstat.txt"
  i=0
  while [ "$i" -le "$1" ]; do
    printf '%s %s 0\n' "$((1800000000 + i))" "$((i * $2))" >> "$tmp/devstat.txt"
    i=$((i + 1))
  done
  for c in $CLIENTS; do
    expect_ssh "mclock-devstat-${c};" 0 0 "$tmp/devstat.txt"
  done
}

# 17) start_bg：per-client run-id 走 remote_bg_start（不得用 node_ssh_to 阻塞）
reset_ssh
B1="$tmp/bundle-1"; mkdir -p "$B1"
expect_start segment
out="$(fio_start_bg "$B1" segment 4k 20000)" || fail "fio_start_bg 應成功"
ok
eq "$out" "fio-start: PASS 4" "start_bg 機器行"
[ -s "$B1/fio/run.json" ] || fail "run.json 未寫入（fio_stop 需要它才能不帶 mode）"
ok
eq "$(jget "$B1/fio/run.json" mode)" "segment" "run.json 記錄 mode"
eq "$(jget "$B1/fio/run.json" runids.mclock-client-2)" "fio-segment-mclock-client-2" \
  "per-client run-id"
decode_all > "$tmp/startpayload.txt"
has "$tmp/startpayload.txt" "randseed=4242" "job 檔真的送到遠端"
has "$tmp/startpayload.txt" "/dev/rbd0" "device 由 rbd-map.json 帶入"
has "$tmp/startpayload.txt" "heartbeat" "背景 runner 必須有 heartbeat（exit proof 的前置）"
# 同一個 replicate attempt 的量測與 baseline 共用 workdir（runid 不含 mode）。
# runner 沒把上一輪的 seg*.json 清掉的話，baseline 的 fetch 會把量測期的段落
# 一起撈走，再被 summary 摺進 baseline——而 baseline 是劣化比的分母。
# shellcheck disable=SC2016
# 這裡刻意用單引號：比對的是遠端腳本裡「未展開」的 $D 字面，展開反而對不上。
has "$tmp/startpayload.txt" 'rm -f "$D"/seg* "$D"/exit-code.seg*' \
  "runner 啟動時必須清掉上一輪的 segment 產物"
has "$tmp/startpayload.txt" "devstat.log" \
  "devstat.log 是 >> 累加，同樣要清（runner 比取樣器早啟動，清了才安全）"
hasnt "$root/lib/fio.sh" "node_ssh_to" "背景 fio 不得走 node_ssh_to（非串流且會等待）"

# 17b) replicate bundle 的 run-id 必須與 lib/collect.sh 的 collect_fio_run_id 逐字一致
#      （coverage supervisor 靠它找 heartbeat；registry 條目也不能跨 replicate 互撞）
reset_ssh
RB="$RESULTS_DIR/c07/r1/attempts/20260725T031000Z"
mkdir -p "$RB"
for c in $CLIENTS; do
  expect_ssh "fio-c07-r1-20260725T031000Z-${c}.pid" 0 0 "$tmp/pid.txt"
  expect_ssh "fio-c07-r1-20260725T031000Z-${c}-devstat.pid" 0 0 "$tmp/pid.txt"
done
fio_start_bg "$RB" segment 4k 20000 >/dev/null || fail "replicate bundle 的 start 應成功"
ok
eq "$(awk -F'\t' '$1 == "mclock-client-1" {print $2}' "$RB/fio/run.tsv")" \
  "fio-c07-r1-20260725T031000Z-mclock-client-1" "run-id 與 collect_fio_run_id 一致"
eq "$(awk -F'\t' '$1 == "mclock-client-1" {print $3}' "$RB/fio/run.tsv")" \
  "/var/tmp/mclock-fio/fio-c07-r1-20260725T031000Z-mclock-client-1" \
  "run.tsv 第三欄 = workdir（collect.sh 由此找 <workdir>/heartbeat）"

# 18) readiness barrier：ramp 完成 + 60s 穩定窗，且該窗要落檔（= p99 分母）
reset_ssh
expect_readiness 120 1000
out="$(fio_readiness_barrier "$B1")" || fail "穩定的 workload 應通過 readiness barrier"
ok
case "$out" in "fio-readiness: PASS"*) ok ;; *) fail "readiness 機器行不符：${out}" ;; esac
[ -s "$B1/readiness.json" ] || fail "readiness.json 未寫入"
# readiness 必須讀「與 fio 併行的取樣器」寫的 devstat.log，不得讀 fio 自己的逐秒 log
# ——後者跑完才落地，執行中讀不到，真機首跑因此量測窗全空、endpoint 全 null。
# fake ssh 以 tag 比對，分辨不出讀的是哪個檔，所以要解 base64 對真正送出的指令斷言。
_rb_cmds="$(sed -n "s/.*printf %s '\([A-Za-z0-9+/=]*\)'.*/\1/p" "$FAKE_SSH_LOG" \
  | while IFS= read -r b; do printf '%s' "$b" | base64 --decode 2>/dev/null; printf '\n'; done)"
printf '%s\n' "$_rb_cmds" | grep -qF 'devstat.log' \
  || fail "readiness 必須讀 devstat.log（與 fio 併行的取樣器輸出）"
ok
if printf '%s\n' "$_rb_cmds" | grep -F 'mclock-devstat' | grep -qF '_iops.'; then
  fail "readiness 不得讀 fio 自己的逐秒 log（跑完才落地）"
fi
ok
ok
eq "$(jget "$B1/readiness.json" stable_seconds)" "60" "穩定窗固定 60s"
S="$(jget "$B1/readiness.json" window.start)"
E="$(jget "$B1/readiness.json" window.end)"
eq "$((E - S + 1))" "60" "readiness 窗長度 = 60s"

# 19) 樣本不足 60s（ramp 剛過）→ 不得放行
reset_ssh
expect_readiness 20 1000
for _ in 1 2 3 4 5 6 7 8; do expect_readiness 20 1000; done
( fio_readiness_barrier "$B1" ) >/dev/null 2>&1 && fail "樣本不足應不通過"
ok

# 20) 吞吐不穩（CoV 過大）→ 不得放行
reset_ssh
python3 - "$tmp/readlog-unstable.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    for rel in range(120):
        val = 1000 if rel % 2 == 0 else 200
        fh.write("%d, %d, 0, 4096, 0\n" % ((1800000000 + rel) * 1000, val))
PY
for _ in 1 2 3 4 5 6 7 8 9; do
  for c in $CLIENTS; do
    expect_ssh "mclock-readlogs-${c};" 0 0 "$tmp/readlog-unstable.txt"
  done
done
( fio_readiness_barrier "$B1" ) >/dev/null 2>&1 && fail "吞吐不穩應不通過"
ok

# 21) heartbeat 新鮮 → alive；過期 → 不 alive（coverage supervisor 的判準）
reset_ssh
now="$(date +%s)"
for c in $CLIENTS; do
  wf "$tmp/hb.$c" "$(printf 'HB %s\nNOW %s' "$now" "$now")"
  expect_ssh "mclock-hb-${c};" 0 0 "$tmp/hb.$c"
done
fio_assert_alive "$B1" >/dev/null || fail "heartbeat 新鮮應判 alive"
ok
reset_ssh
for c in $CLIENTS; do
  wf "$tmp/hbold.$c" "$(printf 'HB 1800000000\nNOW 1800009999')"
  expect_ssh "mclock-hb-${c};" 0 0 "$tmp/hbold.$c"
done
fio_assert_alive "$B1" >/dev/null 2>&1 && fail "heartbeat 過期應判 dead"
ok

# 22) wait_segments：stop-fn 成立即回 0；撞 deadline 回 124
reset_ssh
stop_yes() { return 0; }
stop_no() { return 1; }
fio_wait_segments "$B1" stop_yes "$(( $(date +%s) + 60 ))" || fail "stop-fn 成立應回 0"
ok
rc=0
fio_wait_segments "$B1" stop_no "$(( $(date +%s) - 1 ))" || rc=$?
eq "$rc" "124" "撞 measurement deadline 回 124"

# 23) 量測窗中 fio 死掉 → 回 2（該 attempt 要標 taint，不是靜靜跑完）
reset_ssh
for c in $CLIENTS; do
  expect_ssh "mclock-hb-${c};" 0 0 "$tmp/hbold.$c"
done
rc=0
fio_wait_segments "$B1" stop_no "$(( $(date +%s) + 60 ))" >/dev/null 2>&1 || rc=$?
eq "$rc" "2" "fio 失聯回 2"

# 24) stop：收 exit code + 每 client heartbeat = exit proof
reset_ssh
expect_stop segment "$TAR_OK"
out="$(fio_stop "$B1")" || fail "fio_stop 應成功"
ok
eq "$out" "fio-stop: PASS 4" "fio_stop 機器行"
# 取樣器是無窮迴圈：沒被停掉的話 registry 會留活著的 pid，下一個 replicate 的
# fio_start_bg 會因「拒絕覆蓋」而 die（真機第一個 cell 收尾時就是這樣卡住）。
# expect_ssh 只是「允許」該呼叫，不保證發生——要對 log 斷言才守得住。
eq "$(grep -c -- '-devstat.pid' "$FAKE_SSH_LOG")" "4" \
  "fio_stop 必須一併停掉 4 台的 devstat 取樣器"

# STOP 必須先廣播給全部 4 台，再回頭逐台等待。邊送邊等的話，末台會比首台晚好
# 幾分鐘才看到 STOP——真機實測末台多跑了兩個 segment，期間仍在全速打 IO。
eq "$(grep -c -- 'mclock-signal-' "$FAKE_SSH_LOG")" "4" "STOP 廣播給 4 台"
last_signal="$(grep -n -- 'mclock-signal-' "$FAKE_SSH_LOG" | tail -1 | cut -d: -f1)"
first_wait="$(grep -n -- 'mclock-stop-' "$FAKE_SSH_LOG" | head -1 | cut -d: -f1)"
[ -n "$last_signal" ] && [ -n "$first_wait" ] && [ "$last_signal" -lt "$first_wait" ] \
  || fail "末台的 STOP 廣播 (${last_signal}) 必須早於首台的等待迴圈 (${first_wait})"
ok
# 指令是 base64 過線的：比對明文永遠不匹配 = 空過的測試，必須先解碼再比。
decode_all > "$tmp/stoppayload.txt"
# tar 的 rc 1 =「檔案在讀取中被改動」，archive 仍完整；rc >= 2 才是真錯誤。
# 被 H-033 卡住的 fio 停不下來、會持續寫 log，tar 幾乎必然回 1——當成致命錯誤等於
# 「因為量到了要量的現象，所以把該次量測丟掉」。真機一個 cell 就這樣在收尾 FATAL。
has "$tmp/stoppayload.txt" '-le 1' "fetch 必須容忍 tar 的 rc 1（檔案讀取中被改動）"
has "$tmp/stoppayload.txt" "/STOP" "廣播的內容確實是 touch STOP（已解碼比對）"
# STOP 只在 segment 邊界生效，等待若短於一整段，能否乾淨收工純看運氣。
[ "$FIO_STOP_WAIT_SECS" -gt $((FIO_STEADY_SECS + FIO_RAMP_SECS)) ] \
  || fail "FIO_STOP_WAIT_SECS (${FIO_STOP_WAIT_SECS}) 必須涵蓋 segment 全長 ($((FIO_STEADY_SECS + FIO_RAMP_SECS)))"
ok
[ -s "$B1/fio-exit-proof.json" ] || fail "fio-exit-proof.json 未寫入"
ok
eq "$(jget "$B1/fio-exit-proof.json" clients.mclock-client-1.exit_code)" "0" "收 exit code"
eq "$(jget "$B1/fio-exit-proof.json" clients.mclock-client-1.heartbeat_age_s)" "2" \
  "每 client heartbeat 落差"
eq "$(jget "$B1/fio-exit-proof.json" all_ok)" "True" "全部正常收工"
# 三 log 要回收進 bundle（verdict.py aggregate 的輸入契約）
for f in seg01_iops.1.log seg01_lat.1.log seg01_clat_hist.1.log seg01.json; do
  [ -s "$B1/fio/mclock-client-1/$f" ] || fail "fio 輸出未回收：$f"
  ok
done

# 25) 任一 client 非 0 離開 → FAIL（不得靜默當成功）
reset_ssh
B2="$tmp/bundle-2"; mkdir -p "$B2"
expect_start segment
fio_start_bg "$B2" segment 4k 20000 >/dev/null || fail "start 應成功"
ok
expect_stop segment "$TAR_OK" 1
rc=0
out="$(fio_stop "$B2")" || rc=$?
[ "$rc" -ne 0 ] || fail "fio 非 0 離開時 fio_stop 應回非 0"
ok
case "$out" in "fio-stop: FAIL"*) ok ;; *) fail "失敗機器行不符：${out}" ;; esac
eq "$(jget "$B2/fio-exit-proof.json" all_ok)" "False" "exit proof 記錄失敗"

# ================================================ fio_run_steady / run_baseline ==
# 26) 單段 300s 穩態：readiness → 跑完 → summary
reset_ssh
B3="$tmp/bundle-3"; mkdir -p "$B3"
expect_start steady
expect_readiness 120 1000
expect_wait_done
expect_stop steady "$TAR_OK"
out="$(fio_run_steady "$B3" 4k 20000)" || fail "fio_run_steady 應成功"
ok
case "$out" in "fio-steady: PASS"*) ok ;; *) fail "steady 機器行不符：${out}" ;; esac
[ -s "$B3/fio-summary.json" ] || fail "fio-summary.json 未寫入（steady schema 必備件）"
ok
eq "$(jget "$B3/fio-summary.json" achieved_iops)" "5600.0" "四台 client 的 (read+write) 加總"
eq "$(jget "$B3/fio-summary.json" p99_ns)" "1500000.0" "p99 由 fio JSON 取"
eq "$(jget "$B3/fio-summary.json" target_iops)" "20000" "記錄目標速率"

# 27) baseline 復測 60s 同形態同壓力 → baseline.json（drift gate 的輸入契約）
reset_ssh
B4="$tmp/bundle-4"; mkdir -p "$B4"
expect_start baseline
expect_wait_done
expect_stop baseline "$TAR_OK"
out="$(fio_run_baseline "$B4" 4k mid 20000)" || fail "fio_run_baseline 應成功"
ok
case "$out" in "fio-baseline: PASS"*) ok ;; *) fail "baseline 機器行不符：${out}" ;; esac
for k in shape pressure target_iops achieved_iops p99_ns duration_s; do
  has "$B4/baseline.json" "$k" "baseline.json 契約缺 ${k}"
done
eq "$(jget "$B4/baseline.json" pressure)" "mid" "baseline 記錄壓力等級"
eq "$(jget "$B4/baseline.json" target_iops)" "20000" "baseline 記錄目標速率（非 ceiling）"
# baseline 復測不做 readiness barrier（60s 短跑，barrier 會吃掉整段）
hasnt "$FAKE_SSH_LOG" "mclock-readlogs-mclock-client-1;" "baseline 不跑 readiness barrier"
# baseline 與量測窗共用同一個 replicate bundle：復測資料不得落進 <bundle>/fio，
# 否則 verdict.py aggregate（walk 整個 fio/）會把 60s 復測算進量測窗
[ -s "$B4/fio-baseline/mclock-client-1/seg01_iops.1.log" ] \
  || fail "baseline 產出應落在 <bundle>/fio-baseline/"
ok
[ -e "$B4/fio/mclock-client-1/seg01_iops.1.log" ] \
  && fail "baseline 復測污染了 aggregate 會掃的 <bundle>/fio/"
ok

# ================================================================ fio_calibrate ==
# 28) 校準必須在 balanced + final_clean 下做（共同參考條件，spec §4）
reset_ssh
wf "$tmp/prof-hco.txt" "high_client_ops"
expect_ssh "config get osd osd_mclock_profile" 0 0 "$tmp/prof-hco.txt"
( fio_calibrate 4k ) >/dev/null 2>&1 && fail "非 balanced profile 下校準應 die"
ok

# 29) 三輪不限速取中位為 ceiling，反推 25/50/80%，各壓力另跑 60s 記參考 p99
reset_ssh
wf "$tmp/prof-bal.txt" "balanced"
expect_ssh "config get osd osd_mclock_profile" 0 0 "$tmp/prof-bal.txt"
expect_ssh "ceph -s" 0 0 "$fx/ceph-s-clean.json"
# ceiling 三輪：aggregate 42000 / 38000 / 40000（中位 = 40000）
r=1
for per in 10500 9500 10000; do
  TARC="$tmp/tar-calib-$r.tar"
  mk_tar "$TARC" 60 "$((per * 7 / 10))" "$((per * 3 / 10))" 3000000 --json-only
  expect_start calib
  expect_wait_done
  expect_stop calib "$TARC"
  r=$((r + 1))
done
# 各壓力等級 60s 參考 p99：low/mid/high/extreme
p=1
for p99 in 900000 1500000 4000000 20000000; do
  TARP="$tmp/tar-press-$p.tar"
  mk_tar "$TARP" 60 700 300 "$p99" --json-only
  expect_start baseline
  expect_wait_done
  expect_stop baseline "$TARP"
  p=$((p + 1))
done
out="$(fio_calibrate 4k)" || fail "fio_calibrate 應成功"
ok
case "$out" in "fio-calibrate: PASS 4k 40000"*) ok ;; *) fail "calibrate 機器行不符：${out}" ;; esac
CAL="$RESULTS_DIR/calibration.json"
[ -s "$CAL" ] || fail "calibration.json 未寫入"
ok
eq "$(jget "$CAL" shapes.4k.ceiling_iops)" "40000" "三輪取中位為 ceiling"
eq "$(jget "$CAL" shapes.4k.rates.low)" "10000" "低壓 = 25% ceiling"
eq "$(jget "$CAL" shapes.4k.rates.mid)" "20000" "中壓 = 50% ceiling"
eq "$(jget "$CAL" shapes.4k.rates.high)" "32000" "高壓 = 80% ceiling"
eq "$(jget "$CAL" shapes.4k.per_job_rates.low)" "625" "per-job rate 反推（10000 / 16）"
eq "$(jget "$CAL" shapes.4k.reference_p99_ns.low)" "900000.0" "低壓參考 p99"
eq "$(jget "$CAL" shapes.4k.reference_p99_ns.extreme)" "20000000.0" "極端壓參考 p99"
# 契約對齊：verdict.py baseline-check 要吃得下這份 calibration.json
if ! python3 - "$CAL" <<'PY'
import json
import sys
cal = json.load(open(sys.argv[1]))
entry = cal["shapes"]["4k"]
for pressure in ("low", "mid", "high"):
    assert entry["rates"][pressure] != entry["ceiling_iops"], pressure
    assert entry["reference_p99_ns"][pressure] is not None
assert entry["reference_p99_ns"]["extreme"] is not None
PY
then
  fail "calibration.json 不符 baseline-check 的消費契約"
fi
ok

# ============================================================ fio_precondition ==
# 30) 四 client 平行全量寫 → ceph df 驗 usable 20–30%
mk_df() { # <file> <stored> <max_avail>
  python3 - "$@" <<'PY'
import json
import sys
out, stored, avail = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
doc = {"stats": {"total_bytes": 16888498602639, "total_used_raw_ratio": 0.23},
       "pools": [{"name": "mclock", "id": 2,
                  "stats": {"stored": stored, "objects": 1, "max_avail": avail}}]}
with open(out, "w") as fh:
    json.dump(doc, fh)
PY
}
reset_ssh
mk_df "$tmp/df-ok.json" 1288490188800 4209067950080
expect_start precondition
expect_wait_done
expect_stop precondition "$TAR_OK"
expect_ssh "ceph df" 0 0 "$tmp/df-ok.json"
out="$(fio_precondition)" || fail "fio_precondition 應成功"
ok
case "$out" in "fio-precondition: PASS 23."*) ok ;; *) fail "precondition 機器行不符：${out}" ;; esac
decode_all > "$tmp/prepayload.txt"
has "$tmp/prepayload.txt" "rw=write" "precondition 是全量寫"

# 31) 填充率超出 20–30% → die（不是四捨五入的小事，會改變 backfill footprint）
reset_ssh
mk_df "$tmp/df-low.json" 214748364800 4209067950080
expect_start precondition
expect_wait_done
expect_stop precondition "$TAR_OK"
expect_ssh "ceph df" 0 0 "$tmp/df-low.json"
( fio_precondition ) >/dev/null 2>&1 && fail "填充率不足應 die"
ok

# ======================================================= fio_raw_nvme_baseline ==
# 32) guard 先跑：偵測到 BlueStore/分割即 die（OSD 建立後再打 raw device 會毀資料）
reset_ssh
wf "$tmp/guard-dirty.txt" "RAWGUARD DIRTY blkid-signature"
expect_ssh "mclock-rawguard-mclock-osd-1;" 0 0 "$tmp/guard-dirty.txt"
( fio_raw_nvme_baseline mclock-osd-1 ) >/dev/null 2>&1 && fail "裝置已有簽章應 die"
ok
hasnt "$FAKE_SSH_LOG" "mclock-rawfio-mclock-osd-1;" "guard 未過不得跑 fio"

# 33) guard 過 → 60s 4K randwrite → 契約格式 {node: {iops}}（lib/ceph.sh 的輸入）
reset_ssh
wf "$tmp/guard-ok.txt" "RAWGUARD OK"
python3 "$GEN_JSON" --out "$tmp/rawfio.json" --write-iops 48000 --p99-ns 300000 \
  --jobname raw-nvme >/dev/null
expect_ssh "mclock-rawguard-mclock-osd-1;" 0 0 "$tmp/guard-ok.txt"
expect_ssh "mclock-rawfio-mclock-osd-1;" 0 0 "$tmp/rawfio.json"
out="$(fio_raw_nvme_baseline mclock-osd-1)" || fail "fio_raw_nvme_baseline 應成功"
ok
case "$out" in "raw-nvme-baseline: PASS mclock-osd-1 48000"*) ok ;;
  *) fail "raw baseline 機器行不符：${out}" ;; esac
RAWJSON="$RESULTS_DIR/raw-nvme-baseline.json"
eq "$(jget "$RAWJSON" mclock-osd-1.iops)" "48000.0" "契約：{node: {iops: float}}"
decode_all > "$tmp/rawpayload.txt"
has "$tmp/rawpayload.txt" "/dev/disk/by-id/nvme-MSFT_NVMe_osd-1" "直打 inventory 的 nvme_device"
has "$tmp/rawpayload.txt" "rw=randwrite" "raw 基線 = 4K randwrite"
has "$tmp/rawpayload.txt" "blkid" "guard 用 blkid 偵測既有簽章"
has "$tmp/rawpayload.txt" "ceph-volume" "guard 用 ceph-volume inventory 交叉確認"

# 34) 多台累加不覆蓋（ceph.sh 的 CoV gate 需要 8 顆都在同一份檔案裡）
reset_ssh
python3 "$GEN_JSON" --out "$tmp/rawfio2.json" --write-iops 47100 --p99-ns 310000 \
  --jobname raw-nvme >/dev/null
expect_ssh "mclock-rawguard-mclock-osd-5;" 0 0 "$tmp/guard-ok.txt"
expect_ssh "mclock-rawfio-mclock-osd-5;" 0 0 "$tmp/rawfio2.json"
fio_raw_nvme_baseline mclock-osd-5 >/dev/null || fail "第二台 raw baseline 應成功"
ok
eq "$(jget "$RAWJSON" mclock-osd-1.iops)" "48000.0" "既有節點資料不得被覆蓋"
eq "$(jget "$RAWJSON" mclock-osd-5.iops)" "47100.0" "新節點寫入同一份檔案"

# ============================================================== fio_smoke_real ==
# 35) 60s 真 fio → 三 log 存 golden → aggregate --validate-schema 過才放行
reset_ssh
B5="$tmp/bundle-5"; mkdir -p "$B5"
expect_start smoke
expect_wait_done
expect_stop smoke "$TAR_OK"
out="$(fio_smoke_real "$B5")" || fail "fio_smoke_real 應成功"
ok
case "$out" in "fio-smoke-real: PASS"*) ok ;; *) fail "smoke-real 機器行不符：${out}" ;; esac
[ -s "$RESULTS_DIR/golden/fio-smoke/mclock-client-1/seg01_clat_hist.1.log" ] \
  || fail "golden raw log 未存檔（parser 的一次性校正證據）"
ok

# 36) parser 校正不過（缺 hist log）→ die，不得放行 first cell
reset_ssh
TAR_NOHIST="$tmp/wd-nohist.tar"
mk_tar "$TAR_NOHIST" 60 1000 400 1500000 --no-hist
B6="$tmp/bundle-6"; mkdir -p "$B6"
expect_start smoke
expect_wait_done
expect_stop smoke "$TAR_NOHIST"
( fio_smoke_real "$B6" ) >/dev/null 2>&1 && fail "schema 不過應 die"
ok

# --- summary：沒跑完的尾段 JSON 跳過、跑完的壞 JSON 仍然 die ------------------
# runner 在 fio 回來後才寫 exit-code.<seg>，那個檔就是「這段有正常結束」的憑證。
sd="$tmp/segskip"; mkdir -p "$sd/mclock-client-1"
printf '%s' '{"jobs":[{"job_runtime":300000,"read":{"iops":100.0,"bw_bytes":409600,"clat_ns":{"percentile":{"99.000000":900000}}},"write":{"iops":0.0}}]}' \
  > "$sd/mclock-client-1/seg01.json"
printf '%s' '{"jobs":[{"job_run' > "$sd/mclock-client-1/seg02.json"
_fio_py summary "$sd/out.json" 4k segment 0 \
  "$sd/mclock-client-1/seg01.json" "$sd/mclock-client-1/seg02.json" >/dev/null 2>&1 \
  || fail "尾段沒有 exit-code.seg02 憑證時應跳過而非 die"
ok
has "$sd/out.json" "seg02.json" "跳過的段落必須記進 incomplete_segments（不可靜靜丟掉）"
eq "$(jget "$sd/out.json" segments)" "1" "不完整的段落不計入 segments"
echo 0 > "$sd/mclock-client-1/exit-code.seg02"
_fio_py summary "$sd/out.json" 4k segment 0 \
  "$sd/mclock-client-1/seg01.json" "$sd/mclock-client-1/seg02.json" >/dev/null 2>&1 \
  && fail "有 exit-code.seg02 憑證卻解不開 = 真損毀，必須 die"
ok
rm -f "$sd/mclock-client-1/seg01.json" "$sd/mclock-client-1/exit-code.seg02"
_fio_py summary "$sd/out.json" 4k segment 0 "$sd/mclock-client-1/seg02.json" >/dev/null 2>&1 \
  && fail "全部段落都不完整時不可產出空殼 summary"
ok

printf 'test-fio: %d assertions passed\n' "$asserts"

