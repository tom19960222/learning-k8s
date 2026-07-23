#!/bin/bash
# E-01（L1 段）— baseline 採集 script 的 offset parser 邊界判決。
# fake timedatectl 走 PATH 覆蓋；baseline script 原封不動，僅 TEXTFILE_DIR 一行
# 由測試改寫到 sandbox（parser 邏輯零改動）。預期值 = H-001 prediction 先寫死。
# stdout 只放 PASS/FAIL 一行，其餘走 stderr（repo 慣例）。bash 3.2 相容。
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BASELINE="${HERE}/../../current/collect_ntp_offset.sh"

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

FAKE_BIN="${TMPDIR_ROOT}/bin"
OUT_DIR="${TMPDIR_ROOT}/textfile"
CASE_FILE="${TMPDIR_ROOT}/timesync-status.txt"
SUT="${TMPDIR_ROOT}/collect.sh"
mkdir -p "${FAKE_BIN}" "${OUT_DIR}"

# fake timedatectl：timesync-status 吐 case 檔內容；show 固定回已同步。
# TDCTL_FAIL=1 時兩者皆 exit 1（模擬 daemon 不在／D-Bus 失敗）。
cat > "${FAKE_BIN}/timedatectl" <<EOF
#!/bin/bash
[ "\${TDCTL_FAIL:-0}" = "1" ] && exit 1
case "\$1" in
  timesync-status) cat "${CASE_FILE}" ;;
  show) echo "NTPSynchronized=yes" ;;
esac
EOF
chmod +x "${FAKE_BIN}/timedatectl"

# baseline 唯一允許的測試改動：TEXTFILE_DIR 指到 sandbox
sed "s|^TEXTFILE_DIR=.*|TEXTFILE_DIR=\"${OUT_DIR}\"|" "${BASELINE}" > "${SUT}"
chmod +x "${SUT}"

PROM="${OUT_DIR}/ntp_offset.prom"
pass=0
fail=0

# offset 字串 → 預期的 node_ntp_offset_seconds 值
check_offset() {
    local raw="$1" expected="$2" label="$3"
    {
        echo "         Server: 127.0.0.1 (test)"
        echo "         Offset: ${raw}"
        echo "   Packet count: 42"
    } > "${CASE_FILE}"
    TDCTL_FAIL=0 PATH="${FAKE_BIN}:${PATH}" "${SUT}"
    local got
    got=$(awk '/^node_ntp_offset_seconds/ {print $2}' "${PROM}")
    if [[ "${got}" == "${expected}" ]]; then
        echo "ok   ${label}: '${raw}' -> ${got}" >&2
        pass=$((pass + 1))
    else
        echo "FAIL ${label}: '${raw}' -> got '${got}' want '${expected}'" >&2
        fail=$((fail + 1))
    fi
}

# ── 60 秒以下（dot notation 單 token）：parser 正確 ──
check_offset "812us"        "0.000812000"  "T-us"
check_offset "-45.2ms"      "-0.045200000" "T-ms-neg"
check_offset "+2.337s"      "2.337000000"  "T-s"
check_offset "+59.9s"       "59.900000000" "T-s-max"
# ── ≥ 1 分鐘（format_timespan 多單位）：H-001 炸彈 — awk 只拿 \$2、強制轉型 ──
check_offset "+1min 2.337s" "1.000000000"  "T-min-BUG(62s->1s)"
check_offset "+1h 2min 3s"  "1.000000000"  "T-hour-BUG(3723s->1s)"
check_offset "+1d"          "1.000000000"  "T-day-BUG(86400s->1s)"
# ── 非數字 token：codex 修正 — 匯報完美同步而非 unavailable ──
check_offset "n/a"          "0.000000000"  "T-na-BUG(lying-0)"

# ── Offset 整行缺失（首次 sync 前的正常態）→ unavailable 分支 ──
{
    echo "         Server: 127.0.0.1 (test)"
    echo "   Packet count: 0"
} > "${CASE_FILE}"
TDCTL_FAIL=0 PATH="${FAKE_BIN}:${PATH}" "${SUT}"
if grep -q '^# timedatectl unavailable' "${PROM}" \
   && ! grep -q '^node_ntp_offset_seconds' "${PROM}"; then
    echo "ok   T-no-offset-line: unavailable 分支（全部 metrics 消失）" >&2
    pass=$((pass + 1))
else
    echo "FAIL T-no-offset-line: $(cat "${PROM}")" >&2
    fail=$((fail + 1))
fi

# ── timedatectl 整個失敗（exit 1）→ 同上 ──
TDCTL_FAIL=1 PATH="${FAKE_BIN}:${PATH}" "${SUT}"
if grep -q '^# timedatectl unavailable' "${PROM}"; then
    echo "ok   T-tdctl-fail: unavailable 分支" >&2
    pass=$((pass + 1))
else
    echo "FAIL T-tdctl-fail: $(cat "${PROM}")" >&2
    fail=$((fail + 1))
fi

# ── H-003 檔案面：Packet count 行缺失 → 寫出「無值行」（node_exporter 會拒收整檔）──
{
    echo "         Server: 127.0.0.1 (test)"
    echo "         Offset: +1.2ms"
} > "${CASE_FILE}"
TDCTL_FAIL=0 PATH="${FAKE_BIN}:${PATH}" "${SUT}"
if grep -Eq '^node_ntp_packet_count_total[[:space:]]*$' "${PROM}"; then
    echo "ok   T-empty-packet: 無值行已寫出（H-003 檔案面證據）" >&2
    pass=$((pass + 1))
else
    echo "FAIL T-empty-packet: $(cat "${PROM}")" >&2
    fail=$((fail + 1))
fi

echo "== parser tests: ${pass} ok, ${fail} fail" >&2
if [[ ${fail} -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
