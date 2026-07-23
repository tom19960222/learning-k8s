#!/bin/bash
# E-00 環境盤點 — 全 read-only，不改機器任何狀態。
# 用法：
#   SSH_KEY=~/.ssh/azure-lab SSH_USER=azureuser \
#     bash run/e00-inventory.sh 40.74.71.132 20.210.162.69 ...
# 產出：results/e00-inventory/<host>.txt（每台一份），stdout 只印結果目錄路徑。
# 盤點項（對應 README E-00 六欄表 + Azure 特有項）：
#   systemd 版本（parser 行為）、NTP daemon 種類與設定、node_exporter 與 textfile 路徑、
#   Prometheus/alert 堆疊位置、Hyper-V host time sync 介面（hv_utils / PTP 裝置）
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="${HERE}/results/e00-inventory"
mkdir -p "${OUT_DIR}"

SSH_KEY="${SSH_KEY:-${HOME}/.ssh/azure-lab}"
SSH_USER="${SSH_USER:-azureuser}"

if [[ $# -lt 1 ]]; then
    echo "用法：bash run/e00-inventory.sh <host> [host...]" >&2
    exit 1
fi

# 全部唯讀指令；|| true 讓單項缺席不中斷整台盤點
# shellcheck disable=SC2016  # 刻意單引號：$p 等變數要在遠端 shell 展開，非本機
REMOTE_SCRIPT='
set -u
section() { echo; echo "===== $1 ====="; }
section "host"
hostname; uname -r; date -u +%FT%TZ
section "systemd version"
systemctl --version | head -2
section "NTP daemon"
systemctl is-active systemd-timesyncd chrony chronyd ntpsec 2>/dev/null || true
systemctl is-enabled systemd-timesyncd 2>/dev/null || true
command -v chronyd >/dev/null 2>&1 && echo "chronyd binary PRESENT" || echo "chronyd binary absent"
section "timesyncd config"
cat /etc/systemd/timesyncd.conf 2>/dev/null || true
ls /etc/systemd/timesyncd.conf.d/ 2>/dev/null && cat /etc/systemd/timesyncd.conf.d/*.conf 2>/dev/null || true
section "timedatectl show"
timedatectl show 2>&1 || true
section "timedatectl timesync-status"
timedatectl timesync-status 2>&1 || true
section "adjtimex snapshot (chronyc/adjtimex unavailable -> skip)"
command -v adjtimex >/dev/null 2>&1 && adjtimex --print 2>/dev/null || echo "adjtimex tool absent（用 node_exporter timex metrics 代替）"
section "Azure host time sync surfaces"
lsmod | grep -E "hv_|ptp" || true
ls /sys/class/ptp/ 2>/dev/null || true
for p in /sys/class/ptp/ptp*/clock_name; do [ -r "$p" ] && echo "$p = $(cat "$p")"; done 2>/dev/null || true
section "node_exporter"
pgrep -a node_exporter 2>/dev/null || echo "node_exporter process not found by pgrep"
ss -ltn 2>/dev/null | grep -E ":9100|:9283|:9095" || true
curl -s --max-time 3 localhost:9100/metrics 2>/dev/null | grep -cE "^node_timex" | sed "s/^/timex metric lines: /" || true
curl -s --max-time 3 localhost:9100/metrics 2>/dev/null | grep -E "^node_textfile" || true
section "textfile dir candidates"
ls -d /var/lib/ceph/*/node-exporter.*/etc/node-exporter 2>/dev/null || echo "cephadm textfile dir not found"
ls -d /var/lib/node_exporter* /var/lib/prometheus/node-exporter 2>/dev/null || true
section "ceph deployment surfaces"
command -v cephadm >/dev/null 2>&1 && echo "cephadm PRESENT" || echo "cephadm absent"
command -v ceph >/dev/null 2>&1 && echo "ceph cli PRESENT" || echo "ceph cli absent"
command -v docker >/dev/null 2>&1 && sudo docker ps --format "{{.Names}}" 2>/dev/null | head -20 || true
command -v podman >/dev/null 2>&1 && sudo podman ps --format "{{.Names}}" 2>/dev/null | head -20 || true
section "prometheus surfaces"
pgrep -a prometheus 2>/dev/null || echo "no prometheus process on this host"
pgrep -a alertmanager 2>/dev/null || echo "no alertmanager process on this host"
section "cron/timer for any existing collector"
sudo crontab -l 2>/dev/null | grep -i -E "ntp|time" || echo "root crontab: no time-related entries"
systemctl list-timers 2>/dev/null | grep -i -E "ntp|time" || true
'

for host in "$@"; do
    echo "== ${host}" >&2
    ssh -i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "${SSH_USER}@${host}" "${REMOTE_SCRIPT}" \
        > "${OUT_DIR}/${host}.txt" 2>&1 || echo "warn: ${host} 盤點失敗（見輸出檔）" >&2
done

echo "${OUT_DIR}"
