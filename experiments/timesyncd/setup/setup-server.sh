#!/usr/bin/env bash
# setup-server.sh — Ubuntu 24.04 server VM：chrony 設成 LAN NTP server（一次性）。
# 用法：sudo ./setup-server.sh [--allow 192.168.0.0/16]
set -euo pipefail

ALLOW=""
[[ "${1:-}" == "--allow" ]] && ALLOW="${2:?--allow 需要一個 CIDR}"
[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq chrony

if [[ -n "$ALLOW" ]]; then
  ALLOW_LINES="allow ${ALLOW}"
else
  # 預設只服務 RFC1918 私有網段，避免變成對外開放的 NTP server
  ALLOW_LINES=$'allow 10.0.0.0/8\nallow 172.16.0.0/12\nallow 192.168.0.0/16'
fi

cat > /etc/chrony/conf.d/driftlab.conf <<EOF
# timesyncd drift lab：對 LAN 提供 NTP
${ALLOW_LINES}
# 上游斷線時仍以本機時鐘繼續服務（lab server 角色，stratum 8 防汙染真實 NTP 階層）
local stratum 8
EOF

systemctl restart chrony
sleep 3
chronyc tracking
echo "setup-server: OK。client 端把這台 IP 填進 env.sh 的 SERVER_IP。"
