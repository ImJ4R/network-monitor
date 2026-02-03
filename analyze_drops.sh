#!/bin/bash
################################################################################
# Analyze Network Monitor Logs
################################################################################

LOGFILE=${1:-/var/log/network_drops.log}

if [ ! -f "$LOGFILE" ]; then
    echo "Error: Log file not found: $LOGFILE"
    exit 1
fi

echo "================================================================================"
echo "Network Drop Analysis Report"
echo "Log File: $LOGFILE"
echo "================================================================================"

# Skip header line, count intervals
TOTAL_INTERVALS=$(tail -n +2 "$LOGFILE" | wc -l)
DROP_INTERVALS=$(tail -n +2 "$LOGFILE" | awk -F',' '$4 > 0' | wc -l)

echo "Total Monitoring Intervals: $TOTAL_INTERVALS"
echo "Intervals with Drops: $DROP_INTERVALS"

if [ "$TOTAL_INTERVALS" -gt 0 ]; then
    DROP_PCT=$(awk -v d="$DROP_INTERVALS" -v t="$TOTAL_INTERVALS" 'BEGIN {printf "%.2f", (d/t)*100}')
    echo "Drop Rate: ${DROP_PCT}%"
fi

# Category breakdown
echo -e "\n=== Total Drops by Category ==="
tail -n +2 "$LOGFILE" | awk -F',' '{
    nic_rx+=$5; nic_tx+=$6; nic_missed+=$7; qdisc+=$8; 
    softirq+=$9; syn+=$10; accept+=$11; 
    pruned+=$12; collapsed+=$13; udp_rcv+=$14; udp_snd+=$15
} END {
    printf "NIC RX Dropped:      %10d\n", nic_rx
    printf "NIC TX Dropped:      %10d\n", nic_tx
    printf "NIC RX Missed:       %10d\n", nic_missed
    printf "qdisc Dropped:       %10d\n", qdisc
    printf "Softirq Dropped:     %10d\n", softirq
    printf "SYN Queue Dropped:   %10d\n", syn
    printf "Accept Queue Ovfl:   %10d\n", accept
    printf "TCP Pruned:          %10d\n", pruned
    printf "TCP Collapsed:       %10d\n", collapsed
    printf "UDP RcvBuf Errors:   %10d\n", udp_rcv
    printf "UDP SndBuf Errors:   %10d\n", udp_snd
}'

# Top 10 worst intervals
echo -e "\n=== Top 10 Worst Intervals ==="
tail -n +2 "$LOGFILE" | awk -F',' '{print $1, $4}' | sort -t' ' -k2 -rn | head -10 | \
    while read timestamp drops; do
        printf "%s: %d drops\n" "$timestamp" "$drops"
    done

# Time-of-day analysis
echo -e "\n=== Drops by Hour of Day ==="
tail -n +2 "$LOGFILE" | awk -F'[, :]' '{
    hour=$2":"$3; 
    drops[hour]+=$(NF-1)
} END {
    for (h in drops) {
        printf "%s:00 - %d drops\n", h, drops[h]
    }
}' | sort

# Recent activity (last 20 intervals)
echo -e "\n=== Last 20 Monitoring Intervals ==="
tail -20 "$LOGFILE" | awk -F',' '{
    if (NR==1) {
        print "Timestamp           | Drops | Severity"
        print "--------------------+-------+---------"
    } else {
        printf "%s | %5d | %s\n", $1, $4, $16
    }
}'

echo "================================================================================"
