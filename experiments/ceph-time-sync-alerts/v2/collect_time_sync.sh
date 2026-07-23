#!/bin/bash
# collect_time_sync.sh — v2 時間同步採集（systemd-timesyncd 為主 backend）。
# 修正 baseline 的全部已證缺陷（HYPOTHESES.md H-001/003/006/007/035 + codex findings）：
#   - 完整 format_timespan 多單位 parser（y/month/w/d/h/min/s/ms/us、正負號、多 token）
#   - 非數字（n/a）→ collector_error，絕不匯報 0
#   - 單次 timesync-status 呼叫、一次解析（不做三次不一致快照）
#   - 絕不寫出無值行（值驗證過才 emit 該行；缺欄位靠 absent + collector_error 歸因）
#   - flock 防並發互踩、timeout 防 D-Bus 阻塞疊加（偵測不到工具則警告後續跑，repo 慣例）
#   - last-packet-age：state 檔追蹤 packet count 變化時刻 → 快速失聯訊號
#     （NTPSynchronized 要 maxerror>16s ≈ 失聯 8.9h 才翻 no，不能等它）
#   - chrony 接管／timesyncd 不在 → fail-loud（collector_error=1，檔案仍在、mtime 仍新）
#
# 部署：cron/systemd timer 每 15–60s 跑一次；TEXTFILE_DIR 可用環境變數覆蓋，
# 否則自動偵測 cephadm node-exporter 的 textfile 目錄。
set -u
export LC_ALL=C

TEXTFILE_DIR="${TEXTFILE_DIR:-}"
if [[ -z "${TEXTFILE_DIR}" ]]; then
    for d in /var/lib/ceph/*/node-exporter.*/etc/node-exporter; do
        if [[ -d "${d}" ]]; then TEXTFILE_DIR="${d}"; break; fi
    done
fi
if [[ -z "${TEXTFILE_DIR}" || ! -d "${TEXTFILE_DIR}" ]]; then
    echo "collect_time_sync: TEXTFILE_DIR 不存在（設環境變數或確認 cephadm node-exporter）" >&2
    exit 1
fi

OUTFILE="${TEXTFILE_DIR}/time_sync.prom"
STATE_FILE="${STATE_FILE:-${TEXTFILE_DIR}/.time_sync.state}"
LOCK_FILE="${TEXTFILE_DIR}/.time_sync.lock"

# ── 並發保護（H-035）：搶不到鎖就靜默退出，讓上一個 instance 跑完 ──
if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "collect_time_sync: 另一個 instance 執行中，跳過" >&2
        exit 0
    fi
else
    echo "warn: flock 不存在，無並發保護" >&2
fi

# ── timeout 偵測（H-006：sd-bus 25s timeout 有界但仍會疊加）──
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 10"
else
    echo "warn: timeout 不存在，D-Bus 阻塞時單次可達 ~25s" >&2
fi

# ── 單次快照：兩個指令各呼叫一次，失敗不中斷（fail-loud 靠 collector_error）──
ts_out=$(${TIMEOUT_CMD} timedatectl timesync-status 2>/dev/null) || ts_out=""
show_out=$(${TIMEOUT_CMD} timedatectl show 2>/dev/null) || show_out=""

collector_error=0

field() {  # field <name> — 從 timesync-status 表格取欄位值（含空白的值整段取回）
    printf '%s\n' "${ts_out}" | sed -n "s/^[[:space:]]*${1}: //p" | head -1
}

# format_timespan 反向 parser：支援全部 systemd 單位與多 token（H-001 修正核心）。
# 單位秒數對齊 systemd time-util.c 的 USEC_PER_*（y=365.25d、month=30.44d）。
# 解析失敗輸出空字串（呼叫端據此設 collector_error，絕不輸出 0）。
parse_timespan() {
    awk -v raw="$1" 'BEGIN {
        s = raw; sign = 1
        sub(/^\+/, "", s)
        if (sub(/^-/, "", s)) sign = -1
        if (s == "" || s == "infinity") exit 0
        if (s == "0") { printf "%.9f", 0; exit 0 }   # systemd 對 0 印純 "0"（無單位）
        n = split(s, tok, /[[:space:]]+/)
        total = 0
        for (i = 1; i <= n; i++) {
            t = tok[i]
            if (t !~ /^[0-9]+(\.[0-9]+)?(y|month|w|d|h|min|s|ms|us)$/) exit 0
            v = t; sub(/[a-z]+$/, "", v)
            u = t; sub(/^[0-9.]+/, "", u)
            if      (u == "y")     m = 31557600
            else if (u == "month") m = 2629800
            else if (u == "w")     m = 604800
            else if (u == "d")     m = 86400
            else if (u == "h")     m = 3600
            else if (u == "min")   m = 60
            else if (u == "s")     m = 1
            else if (u == "ms")    m = 0.001
            else if (u == "us")    m = 0.000001
            else exit 0
            total += v * m
        }
        printf "%.9f", sign * total
    }'
}

# ── 逐欄位解析（值驗證通過才會被 emit）──
offset_s=""
raw=$(field "Offset")
if [[ -n "${raw}" ]]; then
    offset_s=$(parse_timespan "${raw}")
    [[ -z "${offset_s}" ]] && collector_error=1   # n/a 或未知格式：fail-loud，不輸出 0
else
    collector_error=1   # Offset 行缺失（daemon 未同步過/不在）
fi

root_distance_s=""
raw=$(field "Root distance")
if [[ -n "${raw}" ]]; then
    root_distance_s=$(parse_timespan "${raw%% (max*}")
    [[ -z "${root_distance_s}" ]] && collector_error=1
fi

poll_s=""
raw=$(field "Poll interval")
if [[ -n "${raw}" ]]; then
    poll_s=$(parse_timespan "${raw%% (min*}")
    [[ -z "${poll_s}" ]] && collector_error=1
fi

stratum=""
raw=$(field "Stratum")
if [[ "${raw}" =~ ^[0-9]+$ ]]; then
    stratum="${raw}"
elif [[ -n "${raw}" ]]; then
    collector_error=1
fi

# 核心欄位：缺席也 fail-loud（Offset 同此原則）；輔助欄位（stratum/root/poll）
# 缺席容忍（systemd 版本差異）、有值但格式錯才 error。
packet_count=""
raw=$(field "Packet count")
if [[ "${raw}" =~ ^[0-9]+$ ]]; then
    packet_count="${raw}"
else
    collector_error=1
fi

ntp_sync=""
raw=$(printf '%s\n' "${show_out}" | sed -n 's/^NTPSynchronized=//p' | head -1)
case "${raw}" in
    yes) ntp_sync=1 ;;
    no)  ntp_sync=0 ;;
    *)   collector_error=1 ;;
esac

# ── last-packet-age（快速失聯訊號）：packet count 變化才更新 state 時刻。
#    注意：state 存 wall-clock；時鐘倒退或 state 損壞時 age 不可信 → fail-loud
#    而非 clamp 成 0（codex r2 finding 5：別在時鐘事故當下假裝新鮮）──
now=$(date +%s)
seconds_since_packet=""
if [[ -n "${packet_count}" ]]; then
    prev_count=""
    prev_ts=""
    if [[ -r "${STATE_FILE}" ]]; then
        read -r prev_count prev_ts < "${STATE_FILE}" || true
    fi
    if [[ "${prev_count}" == "${packet_count}" && "${prev_ts}" =~ ^[0-9]+$ ]]; then
        if [[ ${now} -lt ${prev_ts} ]]; then
            collector_error=1   # 時鐘倒退或 state 時戳在未來 — age 無法信任
        else
            seconds_since_packet=$(( now - prev_ts ))
        fi
    else
        # count 變化（含 daemon restart 歸零）→ 重設基準；寫不進 state 也要 fail-loud
        if printf '%s %s\n' "${packet_count}" "${now}" > "${STATE_FILE}.tmp" \
            && mv "${STATE_FILE}.tmp" "${STATE_FILE}"; then
            seconds_since_packet=0
        else
            collector_error=1
        fi
    fi
fi

# ── 輸出：mktemp 唯一暫存（同檔案系統，rename 原子）+ trap 清理 ──
tmp=$(mktemp "${OUTFILE}.XXXXXX") || exit 1
trap 'rm -f "${tmp}"' EXIT

emit() {  # emit <name> <type> <help> <value>（value 已驗證，絕無空值行）
    {
        printf '# HELP %s %s\n' "$1" "$3"
        printf '# TYPE %s %s\n' "$1" "$2"
        printf '%s %s\n' "$1" "$4"
    } >> "${tmp}"
}

# heartbeat 永遠第一個 emit：timer 死掉時 node_exporter 會永久重讀舊檔（series 不會
# 消失、時間戳每次 scrape 都新鮮 — codex r2 finding 2），唯一可靠的停擺訊號就是
# 這個「凍結的 wall-clock 時戳」與 time() 的差距。
emit node_time_sync_last_run_timestamp_seconds gauge \
    "Wall-clock time of the last collector run (frozen value = collector dead)" "${now}"
emit node_time_sync_collector_error gauge \
    "1 if any field failed to collect/parse this run (metrics for failed fields are absent)" \
    "${collector_error}"
[[ -n "${offset_s}" ]] && emit node_ntp_offset_seconds gauge \
    "NTP offset at last poll in seconds (timesyncd view; frozen between polls)" "${offset_s}"
[[ -n "${ntp_sync}" ]] && emit node_ntp_synchronized gauge \
    "NTPSynchronized flag (kernel maxerror < 16s; flips ~8.9h after upstream loss)" "${ntp_sync}"
[[ -n "${packet_count}" ]] && emit node_ntp_packet_count_total counter \
    "NTP packets received (resets on daemon restart)" "${packet_count}"
[[ -n "${seconds_since_packet}" ]] && emit node_ntp_seconds_since_last_packet gauge \
    "Seconds since packet count last changed (fast upstream-loss signal)" "${seconds_since_packet}"
[[ -n "${stratum}" ]] && emit node_ntp_stratum gauge \
    "Stratum of the selected NTP server" "${stratum}"
[[ -n "${root_distance_s}" ]] && emit node_ntp_root_distance_seconds gauge \
    "Total accumulated error bound to the reference clock in seconds" "${root_distance_s}"
[[ -n "${poll_s}" ]] && emit node_ntp_poll_interval_seconds gauge \
    "Current timesyncd poll interval in seconds (long = stable, short = struggling)" "${poll_s}"

# 先 chmod 再原子發布（mktemp 給 0600；cephadm node-exporter 以 UID 65534 讀 —
# rename 後才 chmod 會有一個不可讀窗口，且 mv 失敗時舊檔被 chmod 造成假成功）
chmod 644 "${tmp}"
if ! mv "${tmp}" "${OUTFILE}"; then
    echo "collect_time_sync: 發布 ${OUTFILE} 失敗" >&2
    exit 1
fi
trap - EXIT
