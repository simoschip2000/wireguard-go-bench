# wireguard-go IFF_BACKPRESSURE benchmark

Measures TCP throughput through wireguard-go with and without
`IFF_BACKPRESSURE` (`WG_TUN_BACKPRESSURE=1`), for different TUN queue lengths.

```
ns1: iperf3 -c + wireguard-go wg1  ──veth──  ns2: wireguard-go wg2 + iperf3 -s
          10.0.0.1 / wg1 10.8.0.1             10.0.0.2 / wg2 10.8.0.2
```

- Unshaped veth, keys generated with `wg genkey` for each run.
- `WG_TUN_BACKPRESSURE` and the TUN queue length (`ip link set txqueuelen`)
  are set on both ends, and the TUN flags and queue length are checked before
  each run.
- wireguard-go sets 7 MiB socket buffers itself (`SO_RCVBUFFORCE`), so no
  sysctl tuning is needed.

## Requirements

- Linux 7.3 or later, root
- iproute2, iperf3 (3.16 or later for one thread per stream), wireguard-tools
- A wireguard-go build with the patch (default: `../wireguard-go/wireguard-go`),
  see below

## Setup

The included wireguard-go patch adds `WG_TUN_BACKPRESSURE`. Build wireguard-go
next to this repository, on the commit the patch was tested on. It needs Go
1.23.1 or later; on Ubuntu 24.04, `golang-go` is too old, so install a
versioned Go package:

```sh
sudo apt install make git golang-1.25-go wireguard-tools iperf3 iproute2
git clone git@github.com:simoschip2000/wireguard-go-bench.git
git clone https://git.zx2c4.com/wireguard-go
cd wireguard-go
git checkout b3bc704
git apply ../wireguard-go-bench/0001-tun-linux-add-WG_TUN_BACKPRESSURE-to-set-IFF_BACKPRE.patch
PATH=/usr/lib/go-1.25/bin:$PATH make
```

## Usage

```sh
sudo ./bench.sh
```

Settings via environment variables (`sudo env VAR=... ./bench.sh`):

| Variable | Default | |
|---|---|---|
| `WIREGUARD_GO` | `../wireguard-go/wireguard-go` | wireguard-go binary |
| `STREAMS` | `8` | iperf3 `-P` |
| `TXQUEUELEN` | `500 5000` | TUN queue lengths to test |
| `DURATION` | `30` | seconds per run |
| `OMIT` | `2` | seconds omitted at the start of each run |
| `REPS` | `40` | repetitions |
| `OUT` | `results/<timestamp>` | output directory |

The defaults take about 1 hour 40 minutes.

## Output

At the end, the mean throughput, TX drops of the client TUN device and TCP
retransmits (iperf3 sender) per queue length are printed and saved to
`summary.txt`:

```
txqueuelen   off Mbit/s    on Mbit/s   change  off drops   on drops   off retr    on retr
       500          ...          ...      ...        ...        ...        ...        ...
      5000          ...          ...      ...        ...        ...        ...        ...
```

`OUT` also contains `results.txt` (one line per run: mode, queue length,
repetition, Mbit/s, TUN drops, retransmits), the iperf3 and wireguard-go
output of each run, and `meta.txt` with kernel, wireguard-go version and
settings.
