#!/bin/bash
# v2 script（collect_time_sync.sh）的 L1 判決：同一批 E-01 邊界 case，
# 預期從「baseline 的錯誤行為」翻成「正確值或 fail-loud」。
# stdout 只放 PASS/FAIL 一行；bash 3.2 相容。
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${HERE}/../../v2/collect_time_sync.sh"

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

FAKE_BIN="${TMPDIR_ROOT}/bin"
OUT_DIR="${TMPDIR_ROOT}/textfile"
CASE_FILE="${TMPDIR_ROOT}/timesync-status.txt"
mkdir -p "${FAKE_BIN}" "${OUT_DIR}"

cat > "${FAKE_BIN}/timedatectl" <<EOF
#!/bin/bash
[ "\${TDCTL_FAIL:-0}" = "1" ] && exit 1
case "\$1" in
  timesync-status) cat "${CASE_FILE}" ;;
  show) echo "NTPSynchronized=\${TDCTL_SYNC:-yes}" ;;
esac
EOF
chmod +x "${FAKE_BIN}/timedatectl"

PROM="${OUT_DIR}/time_sync.prom"
pass=0
fail=0

run_sut() {
    TDCTL_FAIL="${TDCTL_FAIL:-0}" TEXTFILE_DIR="${OUT_DIR}" \
        PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" 2>/dev/null
}

write_case() {  # write_case <offset 字串>（其餘欄位固定健康值）
    {
        echo "       Server: 10.0.2.8 (lab-upstream)"
        echo "Poll interval: 4min 16s (min: 32s; max: 4min 16s)"
        echo "         Leap: normal"
        echo "      Stratum: 2"
        echo "    Reference: A9FEA97B"
        echo "    Precision: 1us (-24)"
        echo "Root distance: 348us (max: 5s)"
        echo "       Offset: $1"
        echo "        Delay: 1.2ms"
        echo "       Jitter: 340us"
        echo " Packet count: 461"
        echo "    Frequency: +12.3ppm"
    } > "${CASE_FILE}"
}

metric() { awk -v m="$1" '$1 == m {print $2}' "${PROM}"; }

check() {  # check <label> <metric> <expected>
    local got
    got=$(metric "$2")
    if [[ "${got}" == "$3" ]]; then
        echo "ok   $1: $2=${got}" >&2
        pass=$((pass + 1))
    else
        echo "FAIL $1: $2 got '${got}' want '$3'" >&2
        fail=$((fail + 1))
    fi
}

# ── 健康 fixture：全部欄位正確解析、error=0 ──
write_case "+1.2ms"
run_sut
check "V-healthy-offset"   node_ntp_offset_seconds          "0.001200000"
check "V-healthy-error"    node_time_sync_collector_error   "0"
check "V-healthy-sync"     node_ntp_synchronized            "1"
check "V-healthy-count"    node_ntp_packet_count_total      "461"
check "V-healthy-poll"     node_ntp_poll_interval_seconds   "256.000000000"
check "V-healthy-rootdist" node_ntp_root_distance_seconds   "0.000348000"
check "V-healthy-stratum"  node_ntp_stratum                 "2"
check "V-healthy-age"      node_ntp_seconds_since_last_packet "0"

# ── H-001 修正：多單位 offset 正確累加 ──
write_case "+1min 2.337s";  run_sut
check "V-min"  node_ntp_offset_seconds "62.337000000"
write_case "-45.2ms";       run_sut
check "V-neg"  node_ntp_offset_seconds "-0.045200000"
write_case "+1h 2min 3s";   run_sut
check "V-hour" node_ntp_offset_seconds "3723.000000000"
write_case "812us";         run_sut
check "V-us"   node_ntp_offset_seconds "0.000812000"
write_case "-2d 1h";        run_sut
check "V-day"  node_ntp_offset_seconds "-176400.000000000"

# ── 真正的零值："0"（systemd 對 0 印純 0、無單位）→ 合法 0，error 維持 0 ──
write_case "0"
run_sut
check "V-zero-offset" node_ntp_offset_seconds        "0.000000000"
check "V-zero-error"  node_time_sync_collector_error "0"

# ── heartbeat：永遠存在、為合理的 epoch 秒數 ──
hb=$(metric node_time_sync_last_run_timestamp_seconds)
now_epoch=$(date +%s)
if [[ "${hb}" =~ ^[0-9]+$ && $(( now_epoch - hb )) -le 5 ]]; then
    echo "ok   V-heartbeat: ${hb}" >&2; pass=$((pass + 1))
else
    echo "FAIL V-heartbeat: '${hb}'" >&2; fail=$((fail + 1))
fi

# ── 發布後檔案權限 644（cephadm node-exporter 以 UID 65534 讀）──
# shellcheck disable=SC2012  # 檔名是測試自己控制的固定路徑；stat 的 flag macOS/Linux 不相容，ls 反而可攜
perm=$(ls -l "${PROM}" | awk '{print $1}')
if [[ "${perm}" == "-rw-r--r--"* ]]; then
    echo "ok   V-perms: ${perm}" >&2; pass=$((pass + 1))
else
    echo "FAIL V-perms: ${perm}" >&2; fail=$((fail + 1))
fi

# ── 時鐘倒退（state 時戳在未來）→ age 不可信：缺席 + error=1，不 clamp 成 0 ──
write_case "+1.2ms"
run_sut   # 建立 state（count=461）
printf '461 %s\n' "$(( $(date +%s) + 1000 ))" > "${OUT_DIR}/.time_sync.state"
run_sut
check "V-backstep-error" node_time_sync_collector_error "1"
if [[ -z "$(metric node_ntp_seconds_since_last_packet)" ]]; then
    echo "ok   V-backstep-absent: age 缺席（不假裝新鮮）" >&2; pass=$((pass + 1))
else
    echo "FAIL V-backstep-absent: age='$(metric node_ntp_seconds_since_last_packet)'" >&2; fail=$((fail + 1))
fi
rm -f "${OUT_DIR}/.time_sync.state"

# ── n/a → fail-loud（offset 缺席 + error=1），絕不匯報 0 ──
write_case "n/a"
run_sut
check "V-na-error"  node_time_sync_collector_error "1"
if [[ -z "$(metric node_ntp_offset_seconds)" ]]; then
    echo "ok   V-na-absent: offset 缺席（不說謊）" >&2; pass=$((pass + 1))
else
    echo "FAIL V-na-absent: offset 不該存在" >&2; fail=$((fail + 1))
fi

# ── Packet count 缺失：無無值行、其餘欄位照常、error=1 ──
write_case "+1.2ms"
sed -i '' '/Packet count/d' "${CASE_FILE}" 2>/dev/null || sed -i '/Packet count/d' "${CASE_FILE}"
run_sut
check "V-nocount-error"  node_time_sync_collector_error "1"
check "V-nocount-offset" node_ntp_offset_seconds        "0.001200000"
if grep -Eq '^[a-z_]+[[:space:]]*$' "${PROM}"; then
    echo "FAIL V-nocount-novalueless: 出現無值行" >&2; fail=$((fail + 1))
else
    echo "ok   V-nocount-novalueless: 無無值行（node_exporter 不會拒收）" >&2; pass=$((pass + 1))
fi

# ── timedatectl 整個失敗：檔案仍產出、error=1、資料 metrics 全缺席 ──
TDCTL_FAIL=1 run_sut
check "V-fail-error" node_time_sync_collector_error "1"
if [[ -z "$(metric node_ntp_offset_seconds)" && -z "$(metric node_ntp_synchronized)" ]]; then
    echo "ok   V-fail-absent: 資料 metrics 缺席、僅剩 error（fail-loud）" >&2; pass=$((pass + 1))
else
    echo "FAIL V-fail-absent" >&2; fail=$((fail + 1))
fi

# ── last-packet-age：count 不變 → age 累積；count 變化 → 歸零 ──
write_case "+1.2ms"
run_sut                       # count=461 → 建立基準（age=0）
sleep 1
run_sut                       # count 仍 461 → age ≥ 1
age=$(metric node_ntp_seconds_since_last_packet)
if [[ "${age}" =~ ^[0-9]+$ && "${age}" -ge 1 ]]; then
    echo "ok   V-age-grows: age=${age}" >&2; pass=$((pass + 1))
else
    echo "FAIL V-age-grows: age='${age}'" >&2; fail=$((fail + 1))
fi
sed -i '' 's/ Packet count: 461/ Packet count: 462/' "${CASE_FILE}" 2>/dev/null \
    || sed -i 's/ Packet count: 461/ Packet count: 462/' "${CASE_FILE}"
run_sut
check "V-age-resets" node_ntp_seconds_since_last_packet "0"

# ── EMIT_TIMEX fallback：macOS 上 adjtimex 不存在 → 要求了拿不到 = fail-loud
#    （值路徑的正確性由 L2 真機對照 node_exporter timex collector 驗證）──
write_case "+1.2ms"
EMIT_TIMEX=1 TDCTL_FAIL=0 TEXTFILE_DIR="${OUT_DIR}" PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" 2>/dev/null
if [[ "$(uname)" == "Darwin" ]]; then
    check "V-timex-fail-loud" node_time_sync_collector_error "1"
    if [[ -z "$(metric node_timex_offset_seconds)" ]]; then
        echo "ok   V-timex-absent: timex metrics 缺席（macOS 無 adjtimex）" >&2; pass=$((pass + 1))
    else
        echo "FAIL V-timex-absent" >&2; fail=$((fail + 1))
    fi
else
    check "V-timex-error0" node_time_sync_collector_error "0"
    if [[ -n "$(metric node_timex_offset_seconds)" && -n "$(metric node_timex_sync_status)" ]]; then
        echo "ok   V-timex-present: $(metric node_timex_offset_seconds)" >&2; pass=$((pass + 1))
    else
        echo "FAIL V-timex-present" >&2; fail=$((fail + 1))
    fi
fi

echo "== v2 parser tests: ${pass} ok, ${fail} fail" >&2
if [[ ${fail} -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
