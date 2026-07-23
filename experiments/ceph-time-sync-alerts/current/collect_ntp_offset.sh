#!/bin/bash
# BASELINE — 使用者現行版本，原封不動存檔供 review 與 E-05 使用。勿修改。

TEXTFILE_DIR="/var/lib/ceph/<fsid>/node-exporter.<hostname>/etc/node-exporter"
OUTFILE="${TEXTFILE_DIR}/ntp_offset.prom"

offset_raw=$(timedatectl timesync-status 2>/dev/null | awk '/Offset:/ {print $2}')
packet_count=$(timedatectl timesync-status 2>/dev/null | awk '/Packet count:/ {print $3}')
ntp_sync=$(timedatectl show 2>/dev/null | awk -F= '/NTPSynchronized/ {print ($2=="yes") ? 1 : 0}')

if [[ -z "$offset_raw" ]]; then
    echo "# timedatectl unavailable" > "${OUTFILE}.tmp"
else
    offset_s=$(echo "$offset_raw" | awk '{
        val = $0
        if (sub(/ms$/, "", val)) {
            val = val / 1000
        }
        else if (sub(/us$/, "", val)) {
            val = val / 1000000
        }
        else if (sub(/s$/, "", val)) {
            val = val + 0
        }
        printf "%.9f", val
    }')

    cat << METRICS > "${OUTFILE}.tmp"
# HELP node_ntp_offset_seconds NTP offset from reference in seconds (via timedatectl)
# TYPE node_ntp_offset_seconds gauge
node_ntp_offset_seconds ${offset_s}
# HELP node_ntp_synchronized NTP synchronization status (1=yes, 0=no)
# TYPE node_ntp_synchronized gauge
node_ntp_synchronized ${ntp_sync}
# HELP node_ntp_packet_count_total Total NTP packets received (use rate() in Prometheus)
# TYPE node_ntp_packet_count_total counter
node_ntp_packet_count_total ${packet_count}
METRICS
fi

mv "${OUTFILE}.tmp" "${OUTFILE}"
