#!/usr/bin/env bash
# setup-client.sh — Ubuntu 22.04 client VM：timesyncd 指向 lab server + 實驗依賴 + 安全網。
# 用法：sudo ./setup-client.sh   （需先把 env.example.sh 複製成 env.sh 填好）
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
require_root

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iputils-ping iproute2 iptables python3

# 同一台不能有第二個 NTP client 搶 clock
if systemctl is-active chrony >/dev/null 2>&1; then
  die "client 上跑著 chrony，會跟 timesyncd 打架。先 systemctl disable --now chrony"
fi

# timesyncd 指向 lab server（drop-in，不動主設定檔）
mkdir -p /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/99-driftlab.conf <<EOF
[Time]
NTP=${SERVER_IP}
FallbackNTP=
EOF

# exp4 資源監測需要 accounting
mkdir -p /etc/systemd/system/systemd-timesyncd.service.d
cat > /etc/systemd/system/systemd-timesyncd.service.d/99-driftlab.conf <<EOF
[Service]
CPUAccounting=yes
MemoryAccounting=yes
EOF

systemctl daemon-reload
timedatectl set-ntp true
systemctl restart systemd-timesyncd
sleep 5
timedatectl timesync-status | head -8

preflight
echo "setup-client: OK。下一步：sudo ./setup/calibrate.sh"
