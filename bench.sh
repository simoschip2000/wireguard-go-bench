#!/bin/bash
# wireguard-go TCP throughput with and without IFF_BACKPRESSURE (WG_TUN_BACKPRESSURE=1).
#
# ns1: iperf3 client + wireguard-go wg1  --veth-->  ns2: wireguard-go wg2 + iperf3 server
#
# Usage: sudo ./bench.sh   (settings via environment variables, see README.md)

set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)

WIREGUARD_GO=${WIREGUARD_GO:-$HERE/../wireguard-go/wireguard-go}
STREAMS=${STREAMS:-8}
TXQUEUELEN=${TXQUEUELEN:-"500 5000"}
DURATION=${DURATION:-30}
OMIT=${OMIT:-2}
REPS=${REPS:-40}
OUT=${OUT:-$HERE/results/$(date +%Y%m%d-%H%M%S)}

NS1=wgbench1
NS2=wgbench2
VPN1=10.8.0.1
VPN2=10.8.0.2

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
for tool in ip iperf3 wg ping; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
[ -x "$WIREGUARD_GO" ] || die "wireguard-go binary not found: $WIREGUARD_GO"
WIREGUARD_GO=$(realpath "$WIREGUARD_GO")

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
WORK=$(mktemp -d)

stop_tunnel() {
    local pidfile pid
    for pidfile in "$WORK"/*.pid; do
        [ -e "$pidfile" ] || continue
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        rm -f "$pidfile"
    done
}

cleanup() {
    stop_tunnel
    ip netns del "$NS1" 2>/dev/null || true
    ip netns del "$NS2" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

setup_netns() {
    ip netns del "$NS1" 2>/dev/null || true
    ip netns del "$NS2" 2>/dev/null || true
    ip netns add "$NS1"
    ip netns add "$NS2"
    ip -n "$NS1" link set lo up
    ip -n "$NS2" link set lo up
    ip link add veth1 netns "$NS1" type veth peer name veth2 netns "$NS2"
    ip -n "$NS1" addr add 10.0.0.1/24 dev veth1
    ip -n "$NS2" addr add 10.0.0.2/24 dev veth2
    ip -n "$NS1" link set veth1 up
    ip -n "$NS2" link set veth2 up
}

gen_keys() {
    local side
    for side in server client; do
        (umask 077; wg genkey >"$WORK/$side.key")
        wg pubkey <"$WORK/$side.key" >"$WORK/$side.pub"
    done
}

# start_peer <ns> <dev> <side> <peer side> <peer underlay addr> <vpn addr> <peer vpn addr> <mode> <txqueuelen>
start_peer() {
    local ns=$1 dev=$2 side=$3 peer=$4 peer_addr=$5 vpn=$6 peer_vpn=$7 mode=$8 qlen=$9 env=() log i
    [ "$mode" = on ] && env=(WG_TUN_BACKPRESSURE=1)
    log="$OUT/wireguard-go-$side-$mode-q$qlen.log"

    ip netns exec "$ns" env "${env[@]}" LOG_LEVEL=error "$WIREGUARD_GO" -f "$dev" >"$log" 2>&1 &
    echo $! >"$WORK/$side.pid"
    # Different device names per namespace, since the UAPI socket path is global.
    for i in $(seq 50); do
        [ -S "/var/run/wireguard/$dev.sock" ] && break
        [ "$i" -eq 50 ] && die "wireguard-go did not start, see $log"
        sleep 0.1
    done

    ip netns exec "$ns" wg set "$dev" private-key "$WORK/$side.key" listen-port 51820 \
        peer "$(cat "$WORK/$peer.pub")" endpoint "$peer_addr:51820" allowed-ips "$peer_vpn/32"
    ip -n "$ns" addr add "$vpn/24" dev "$dev"
    ip -n "$ns" link set "$dev" txqueuelen "$qlen" up
}

# start_tunnel <off|on> <txqueuelen>
start_tunnel() {
    local mode=$1 qlen=$2 i ns dev flags
    start_peer "$NS2" wg2 server client 10.0.0.1 "$VPN2" "$VPN1" "$mode" "$qlen"
    start_peer "$NS1" wg1 client server 10.0.0.2 "$VPN1" "$VPN2" "$mode" "$qlen"

    for i in $(seq 30); do
        ip netns exec "$NS1" ping -c 1 -W 1 "$VPN2" >/dev/null 2>&1 && break
        [ "$i" -eq 30 ] && die "tunnel did not come up, see $OUT/wireguard-go-*-$mode-q$qlen.log"
    done

    for ns in "$NS1:wg1" "$NS2:wg2"; do
        dev=${ns#*:} ns=${ns%:*}
        flags=$(ip netns exec "$ns" cat "/sys/class/net/$dev/tun_flags")
        if [ "$mode" = on ] && (( (flags & 0x80) == 0 )); then
            die "IFF_BACKPRESSURE not set on $dev (tun_flags $flags), is wireguard-go patched?"
        elif [ "$mode" = off ] && (( (flags & 0x80) != 0 )); then
            die "IFF_BACKPRESSURE unexpectedly set on $dev (tun_flags $flags)"
        fi
        [ "$(ip netns exec "$ns" cat "/sys/class/net/$dev/tx_queue_len")" = "$qlen" ] ||
            die "tx_queue_len of $dev is not $qlen"
    done
}

# TX drops of the client TUN device, where the iperf3 data enters the tunnel
tun_tx_dropped() { ip netns exec "$NS1" cat /sys/class/net/wg1/statistics/tx_dropped; }

# run_one <mode> <txqueuelen> <rep>
run_one() {
    local mode=$1 qlen=$2 rep=$3 log srv mbps retr d0 drops
    log="$OUT/iperf3-$mode-q$qlen-r$rep.txt"

    ip netns exec "$NS2" iperf3 -s -1 -B "$VPN2" >/dev/null 2>&1 &
    srv=$!
    sleep 1
    d0=$(tun_tx_dropped)
    ip netns exec "$NS1" iperf3 -c "$VPN2" -P "$STREAMS" -t "$DURATION" -O "$OMIT" -f m >"$log" 2>&1 || true
    drops=$(( $(tun_tx_dropped) - d0 ))
    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true

    # The last receiver/sender line is the sum over all streams.
    mbps=$(awk '/receiver/ { v = $(NF - 2) } END { print v + 0 }' "$log")
    retr=$(awk '/sender/ { v = $(NF - 1) } END { print v + 0 }' "$log")
    echo "$mode $qlen $rep $mbps $drops $retr" >>"$OUT/results.txt"
    printf '  txqueuelen %-5s backpressure %-3s %6s Mbit/s %8s tun drops %8s retransmits\n' \
        "$qlen" "$mode" "$mbps" "$drops" "$retr"
    sleep 2
}

summary() {
    awk -v qlens="$TXQUEUELEN" '
        { sum[$1, $2] += $4; drops[$1, $2] += $5; retr[$1, $2] += $6; n[$1, $2]++ }
        END {
            printf "%10s %12s %12s %8s %10s %10s %10s %10s\n", "txqueuelen", "off Mbit/s", "on Mbit/s",
                   "change", "off drops", "on drops", "off retr", "on retr"
            split(qlens, qs, " ")
            for (i = 1; i in qs; i++) {
                q = qs[i]
                if (!n["off", q] || !n["on", q]) continue
                off = sum["off", q] / n["off", q]
                on = sum["on", q] / n["on", q]
                change = off ? sprintf("%+.1f%%", 100 * (on - off) / off) : "-"
                printf "%10d %12.0f %12.0f %8s %10.0f %10.0f %10.0f %10.0f\n", q, off, on, change,
                       drops["off", q] / n["off", q], drops["on", q] / n["on", q],
                       retr["off", q] / n["off", q], retr["on", q] / n["on", q]
            }
        }' "$OUT/results.txt"
}

{
    echo "date: $(date -Iseconds)"
    echo "kernel: $(uname -r)"
    echo "wireguard-go: $("$WIREGUARD_GO" --version | head -1)"
    echo "streams: $STREAMS, txqueuelen: $TXQUEUELEN, duration: $DURATION s, reps: $REPS"
} >"$OUT/meta.txt"

setup_netns
gen_keys

for rep in $(seq "$REPS"); do
    echo "rep $rep/$REPS"
    # Alternate the order so slow drift affects both modes equally.
    if (( rep % 2 )); then modes="off on"; else modes="on off"; fi
    for qlen in $TXQUEUELEN; do
        for mode in $modes; do
            start_tunnel "$mode" "$qlen"
            run_one "$mode" "$qlen" "$rep"
            stop_tunnel
        done
    done
done

echo
summary | tee "$OUT/summary.txt"
echo "(mean over $REPS repetitions, results in $OUT)"
