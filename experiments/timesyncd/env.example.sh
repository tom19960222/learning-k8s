# timesyncd drift lab 環境設定。複製成 env.sh 後填值（env.sh 已被 .gitignore 擋掉）
# NTP server VM 的 IP（client 看得到的那個）
SERVER_IP=192.168.1.10
# client 對外網卡（exp4 jitter 情境的 tc netem 用）
CLIENT_IFACE=eth0
# probe 打的 NTP port。真實環境 123；L3 fake server 模式也是 123（bind localhost）
NTP_PORT=123
# 結果輸出根目錄（預設 repo 內 results/）
RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"
