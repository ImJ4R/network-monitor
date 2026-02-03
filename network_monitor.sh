#!/bin/bash
################################################################################
# Production Network Monitor
# - Supports multiple interfaces & bonding
# - Rolling capture with delta analysis
# - Logs historical data
# - Real-time alerting
#
# Usage: ./network_monitor.sh [interface] [interval] [logfile]
# Example: ./network_monitor.sh eth0 5 /var/log/network.log
################################################################################

INTERFACE=${1:-eth0}
INTERVAL=${2:-5}
LOGFILE=${3:-/var/log/network_drops.log}
ALERT_THRESHOLD=100  # Alert if drops > this in one interval

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Create log directory
mkdir -p "$(dirname "$LOGFILE")"

################################################################################
# Functions
################################################################################

# Get bond slaves if interface is bonded
get_bond_slaves() {
    local iface=$1
    if [ -d "/sys/class/net/$iface/bonding" ]; then
        cat /sys/class/net/$iface/bonding/slaves 2>/dev/null
    fi
}

# Get all counters for an interface
get_interface_counters() {
    local iface=$1
    
    # NIC drops (RX + TX)
    local rx_dropped=$(ethtool -S "$iface" 2>/dev/null | grep "rx_dropped:" | awk '{print $2}')
    local tx_dropped=$(ethtool -S "$iface" 2>/dev/null | grep "tx_dropped:" | awk '{print $2}')
    local rx_missed=$(ethtool -S "$iface" 2>/dev/null | grep "rx_missed_errors:" | awk '{print $2}')
    
    # qdisc drops
    local qdisc_drops=$(tc -s qdisc show dev "$iface" 2>/dev/null | grep -oP 'dropped \K[0-9]+' | head -1)
    
    echo "${rx_dropped:-0} ${tx_dropped:-0} ${rx_missed:-0} ${qdisc_drops:-0}"
}

# Get system-wide counters
get_system_counters() {
    # Softirq drops (all CPUs)
    local softirq=$(awk '{sum+=strtonum("0x"$2)} END {print sum}' /proc/net/softnet_stat)
    
    # TCP stats
    local syn_drops=$(netstat -s 2>/dev/null | grep "SYNs to LISTEN sockets dropped" | awk '{print $1}')
    local listen_overflows=$(netstat -s 2>/dev/null | grep "times the listen queue.*overflowed" | awk '{print $1}')
    local tcp_pruned=$(netstat -s 2>/dev/null | grep "packets pruned" | awk '{print $1}')
    local tcp_collapsed=$(netstat -s 2>/dev/null | grep "packets collapsed" | awk '{print $1}')
    
    # UDP stats
    local udp_rcvbuf=$(netstat -su 2>/dev/null | grep "RcvbufErrors" | awk '{print $2}')
    local udp_sndbuf=$(netstat -su 2>/dev/null | grep "SndbufErrors" | awk '{print $2}')
    
    echo "${softirq:-0} ${syn_drops:-0} ${listen_overflows:-0} ${tcp_pruned:-0} ${tcp_collapsed:-0} ${udp_rcvbuf:-0} ${udp_sndbuf:-0}"
}

################################################################################
# Startup
################################################################################

clear
echo "================================================================================"
echo -e "${GREEN}Production Network Monitor${NC}"
echo "================================================================================"
echo "Interface:       $INTERFACE"
echo "Check Interval:  ${INTERVAL}s"
echo "Log File:        $LOGFILE"
echo "Alert Threshold: $ALERT_THRESHOLD drops/interval"

# Check if interface exists
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo -e "${RED}ERROR: Interface $INTERFACE not found${NC}"
    exit 1
fi

# Check for bonding
BOND_SLAVES=$(get_bond_slaves "$INTERFACE")
if [ -n "$BOND_SLAVES" ]; then
    BOND_MODE=$(cat /sys/class/net/$INTERFACE/bonding/mode 2>/dev/null)
    echo -e "${YELLOW}Bond Mode:       $BOND_MODE${NC}"
    echo -e "${YELLOW}Bond Slaves:     $BOND_SLAVES${NC}"
fi

echo "================================================================================"
echo -e "${BLUE}Monitoring started at $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}Press Ctrl+C to stop${NC}"
echo "================================================================================"

# Write CSV header to log
if [ ! -f "$LOGFILE" ]; then
    echo "timestamp,iteration,interface,total_drops,nic_rx,nic_tx,nic_missed,qdisc,softirq,syn_queue,accept_queue,tcp_pruned,tcp_collapsed,udp_rcvbuf,udp_sndbuf,severity" > "$LOGFILE"
fi

################################################################################
# Get baseline
################################################################################

read PREV_RX PREV_TX PREV_MISSED PREV_QDISC <<< $(get_interface_counters "$INTERFACE")
read PREV_SOFTIRQ PREV_SYN PREV_LISTEN PREV_PRUNED PREV_COLLAPSED PREV_UDP_RCV PREV_UDP_SND <<< $(get_system_counters)

# Trap Ctrl+C
trap 'echo -e "\n${YELLOW}Stopping monitor...${NC}"; exit 0' INT

################################################################################
# Main monitoring loop
################################################################################

ITERATION=0
while true; do
    sleep "$INTERVAL"
    ITERATION=$((ITERATION + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get current counters
    read CURR_RX CURR_TX CURR_MISSED CURR_QDISC <<< $(get_interface_counters "$INTERFACE")
    read CURR_SOFTIRQ CURR_SYN CURR_LISTEN CURR_PRUNED CURR_COLLAPSED CURR_UDP_RCV CURR_UDP_SND <<< $(get_system_counters)
    
    # Calculate deltas
    DELTA_RX=$((CURR_RX - PREV_RX))
    DELTA_TX=$((CURR_TX - PREV_TX))
    DELTA_MISSED=$((CURR_MISSED - PREV_MISSED))
    DELTA_QDISC=$((CURR_QDISC - PREV_QDISC))
    DELTA_SOFTIRQ=$((CURR_SOFTIRQ - PREV_SOFTIRQ))
    DELTA_SYN=$((CURR_SYN - PREV_SYN))
    DELTA_LISTEN=$((CURR_LISTEN - PREV_LISTEN))
    DELTA_PRUNED=$((CURR_PRUNED - PREV_PRUNED))
    DELTA_COLLAPSED=$((CURR_COLLAPSED - PREV_COLLAPSED))
    DELTA_UDP_RCV=$((CURR_UDP_RCV - PREV_UDP_RCV))
    DELTA_UDP_SND=$((CURR_UDP_SND - PREV_UDP_SND))
    
    # Total drops this interval
    TOTAL_DELTA=$((DELTA_RX + DELTA_TX + DELTA_MISSED + DELTA_QDISC + DELTA_SOFTIRQ + DELTA_SYN + DELTA_LISTEN + DELTA_PRUNED + DELTA_COLLAPSED + DELTA_UDP_RCV + DELTA_UDP_SND))
    
    # Determine severity
    if [ "$TOTAL_DELTA" -eq 0 ]; then
        SEVERITY="OK"
        COLOR=$GREEN
        SYMBOL="✓"
    elif [ "$TOTAL_DELTA" -lt "$ALERT_THRESHOLD" ]; then
        SEVERITY="WARN"
        COLOR=$YELLOW
        SYMBOL="⚠"
    else
        SEVERITY="CRIT"
        COLOR=$RED
        SYMBOL="✖"
    fi
    
    # Console output - one line summary
    printf "${COLOR}[%s] #%04d | $SYMBOL %s | Drops: %d${NC}\n" \
        "$TIMESTAMP" "$ITERATION" "$SEVERITY" "$TOTAL_DELTA"
    
    # Detailed breakdown if drops detected
    if [ "$TOTAL_DELTA" -gt 0 ]; then
        [ "$DELTA_RX" -gt 0 ] && printf "  ${COLOR}├─ NIC RX Dropped: %d${NC}\n" "$DELTA_RX"
        [ "$DELTA_TX" -gt 0 ] && printf "  ${COLOR}├─ NIC TX Dropped: %d${NC}\n" "$DELTA_TX"
        [ "$DELTA_MISSED" -gt 0 ] && printf "  ${COLOR}├─ NIC RX Missed: %d${NC}\n" "$DELTA_MISSED"
        [ "$DELTA_QDISC" -gt 0 ] && printf "  ${COLOR}├─ qdisc Dropped: %d${NC}\n" "$DELTA_QDISC"
        [ "$DELTA_SOFTIRQ" -gt 0 ] && printf "  ${COLOR}├─ Softirq Dropped: %d${NC}\n" "$DELTA_SOFTIRQ"
        [ "$DELTA_SYN" -gt 0 ] && printf "  ${COLOR}├─ SYN Queue Dropped: %d${NC}\n" "$DELTA_SYN"
        [ "$DELTA_LISTEN" -gt 0 ] && printf "  ${COLOR}├─ Accept Queue Overflow: %d${NC}\n" "$DELTA_LISTEN"
        [ "$DELTA_PRUNED" -gt 0 ] && printf "  ${COLOR}├─ TCP Pruned: %d${NC}\n" "$DELTA_PRUNED"
        [ "$DELTA_COLLAPSED" -gt 0 ] && printf "  ${COLOR}├─ TCP Collapsed: %d${NC}\n" "$DELTA_COLLAPSED"
        [ "$DELTA_UDP_RCV" -gt 0 ] && printf "  ${COLOR}├─ UDP RcvBuf Full: %d${NC}\n" "$DELTA_UDP_RCV"
        [ "$DELTA_UDP_SND" -gt 0 ] && printf "  ${COLOR}╰─ UDP SndBuf Full: %d${NC}\n" "$DELTA_UDP_SND"
        echo ""
    fi
    
    # Log to CSV
    echo "$TIMESTAMP,$ITERATION,$INTERFACE,$TOTAL_DELTA,$DELTA_RX,$DELTA_TX,$DELTA_MISSED,$DELTA_QDISC,$DELTA_SOFTIRQ,$DELTA_SYN,$DELTA_LISTEN,$DELTA_PRUNED,$DELTA_COLLAPSED,$DELTA_UDP_RCV,$DELTA_UDP_SND,$SEVERITY" >> "$LOGFILE"
    
    # Update previous values
    PREV_RX=$CURR_RX
    PREV_TX=$CURR_TX
    PREV_MISSED=$CURR_MISSED
    PREV_QDISC=$CURR_QDISC
    PREV_SOFTIRQ=$CURR_SOFTIRQ
    PREV_SYN=$CURR_SYN
    PREV_LISTEN=$CURR_LISTEN
    PREV_PRUNED=$CURR_PRUNED
    PREV_COLLAPSED=$CURR_COLLAPSED
    PREV_UDP_RCV=$CURR_UDP_RCV
    PREV_UDP_SND=$CURR_UDP_SND
done
