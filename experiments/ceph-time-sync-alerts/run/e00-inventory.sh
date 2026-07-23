#!/bin/bash
# E-00 環境盤點 — 唯讀意圖（不改機器組態；副作用僅限：本機 results 檔、
# 專用 known_hosts 檔、遠端 SSH 登入紀錄/sudo audit log — 無可避免且無害）。
# codex r2 硬化：BatchMode、sudo -n、遠端 timeout、明確錯誤狀態標記、
# 有效（merged）設定、Hyper-V 時鐘面、cephadm 監控堆疊探查。
#
# 用法：
#   SSH_KEY=~/.ssh/azure-lab SSH_USER=azureuser \
#     bash run/e00-inventory.sh <host> [host...]
# 產出：results/e00-inventory/<host>.txt（results/ 已入 .gitignore，不進版控）。
# stdout 只印結果目錄路徑。
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="${HERE}/results/e00-inventory"
mkdir -p "${OUT_DIR}"

SSH_KEY="${SSH_KEY:-${HOME}/.ssh/azure-lab}"
SSH_USER="${SSH_USER:-azureuser}"
KNOWN_HOSTS="${OUT_DIR}/.known_hosts"   # 專用檔，不動使用者的 ~/.ssh/known_hosts

if [[ $# -lt 1 ]]; then
    echo "用法：bash run/e00-inventory.sh <host> [host...]" >&2
    exit 1
fi

# 每個外部探測都有明確三態：值 / TOOL-ABSENT / PROBE-FAILED（不把工具缺席混成 0）
# shellcheck disable=SC2016  # 刻意單引號：變數要在遠端 shell 展開，非本機
REMOTE_SCRIPT='
set -u
LC_ALL=C; export LC_ALL
T() { command -v timeout >/dev/null 2>&1 && timeout 15 "$@" || "$@"; }
probe() {  # probe <label> <cmd...>：三態輸出
    echo "--- $1"
    shift
    if ! command -v "$1" >/dev/null 2>&1; then echo "TOOL-ABSENT: $1"; return; fi
    T "$@" 2>&1 || echo "PROBE-FAILED: $*"
}
section() { echo; echo "===== $1 ====="; }

section "host"
hostname; uname -r; date -u +%FT%TZ
section "systemd version"
systemctl --version | head -2
section "NTP daemon state"
for u in systemd-timesyncd chrony chronyd ntpsec; do
    printf "%s: active=%s enabled=%s\n" "$u" \
        "$(systemctl is-active "$u" 2>/dev/null)" "$(systemctl is-enabled "$u" 2>/dev/null)"
done
command -v chronyd >/dev/null 2>&1 && echo "chronyd binary PRESENT" || echo "chronyd binary absent"
probe "chrony sources (if active)" chronyc -n sources
section "timesyncd EFFECTIVE config（含 vendor/run drop-ins — 生產 PollIntervalMaxSec=256 的證明點）"
probe "systemd-analyze cat-config" systemd-analyze cat-config systemd/timesyncd.conf
echo "--- fallback: raw files"
cat /etc/systemd/timesyncd.conf 2>/dev/null || echo "no /etc/systemd/timesyncd.conf"
for d in /etc/systemd/timesyncd.conf.d /run/systemd/timesyncd.conf.d /usr/lib/systemd/timesyncd.conf.d; do
    ls "$d" 2>/dev/null && cat "$d"/*.conf 2>/dev/null
done
section "timedatectl"
probe "show" timedatectl show
probe "timesync-status" timedatectl timesync-status
section "Azure / Hyper-V time surfaces"
echo "--- clocksource"
cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null || echo "PROBE-FAILED: clocksource"
cat /sys/devices/system/clocksource/clocksource0/available_clocksource 2>/dev/null || true
echo "--- hv modules"
lsmod | grep -E "hv_|ptp" || echo "no hv_/ptp modules loaded"
echo "--- ptp devices"
ls /dev/ptp* 2>/dev/null || echo "no /dev/ptp*"
for p in /sys/class/ptp/ptp*/clock_name; do [ -r "$p" ] && echo "$p = $(cat "$p")"; done 2>/dev/null || true
echo "--- walinuxagent"
systemctl is-active walinuxagent waagent 2>/dev/null || true
echo "--- kernel hv timesync evidence (bounded)"
sudo -n dmesg 2>/dev/null | grep -i -E "hv_utils|timesync|ptp_hyperv" | tail -20 || echo "PROBE-FAILED: dmesg (sudo -n denied or empty)"
section "node_exporter（重點：實際 argv — cephadm 預設 --no-collector.timex 且無 textfile 目錄）"
pgrep -af node_exporter 2>/dev/null || echo "node_exporter process not found"
probe "listen ports" ss -ltn
probe "textfile/timex metrics" sh -c "curl -s --max-time 5 localhost:9100/metrics | grep -E \"^node_textfile|^node_timex\" | head -10"
echo "--- container inspect (argv)"
for rt in docker podman; do
    if command -v "$rt" >/dev/null 2>&1; then
        sudo -n "$rt" ps --format "{{.Names}}" 2>/dev/null | while read -r c; do
            case "$c" in *node-exporter*|*node_exporter*)
                echo "container: $c"
                sudo -n "$rt" inspect --format "{{.Args}}" "$c" 2>/dev/null || echo "PROBE-FAILED: $rt inspect $c"
            esac
        done
    fi
done
section "textfile dir candidates"
ls -ld /var/lib/ceph/*/node-exporter.*/etc/node-exporter 2>/dev/null || echo "cephadm textfile dir not found"
ls -ld /var/lib/node_exporter* /var/lib/prometheus/node-exporter 2>/dev/null || true
section "ceph deployment surfaces"
command -v cephadm >/dev/null 2>&1 && echo "cephadm PRESENT" || echo "cephadm absent"
command -v ceph >/dev/null 2>&1 && echo "ceph cli PRESENT" || echo "ceph cli absent"
echo "--- ceph orch（僅 admin node 會成功；失敗屬預期）"
sudo -n ceph orch ps --format json 2>/dev/null | head -c 4000 && echo || echo "PROBE-FAILED: ceph orch ps（非 admin node 或 sudo -n 拒絕）"
sudo -n ceph orch ls --format json 2>/dev/null | head -c 2000 && echo || true
section "prometheus / alertmanager（cephadm 預設 port 9095/9093）"
pgrep -af "prometheus|alertmanager" 2>/dev/null || echo "no prometheus/alertmanager process on this host"
for port in 9095 9090; do
    echo "--- prometheus API on :$port"
    curl -s --max-time 5 "localhost:$port/api/v1/status/buildinfo" 2>/dev/null || echo "PROBE-FAILED: no prometheus on :$port"
    echo
    curl -s --max-time 5 "localhost:$port/api/v1/status/config" 2>/dev/null | head -c 6000 && echo || true
    curl -s --max-time 5 "localhost:$port/api/v1/rules?type=alert" 2>/dev/null | head -c 4000 && echo || true
done
echo "--- alertmanager API on :9093"
curl -s --max-time 5 "localhost:9093/api/v2/status" 2>/dev/null | head -c 4000 && echo || echo "PROBE-FAILED: no alertmanager on :9093"
section "existing collector deployment"
sudo -n crontab -l 2>/dev/null | grep -i -E "ntp|time" || echo "root crontab: none/denied"
systemctl list-timers --all 2>/dev/null | grep -i -E "ntp|time_sync|time-sync|collect" || true
'

for host in "$@"; do
    echo "== ${host}" >&2
    ssh -i "${SSH_KEY}" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${KNOWN_HOSTS}" \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=6 \
        "${SSH_USER}@${host}" "${REMOTE_SCRIPT}" \
        > "${OUT_DIR}/${host}.txt" 2>&1 || echo "warn: ${host} 盤點失敗（見輸出檔）" >&2
done

echo "${OUT_DIR}"
