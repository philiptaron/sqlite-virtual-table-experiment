#!/usr/bin/env bash
# The host half of test/nfs-cluster.nix, for an Ubuntu machine such as
# GitHub Actions' ubuntu-latest: an NFS export for the shared store's files
# and nixremote-server for its metadata, both on the host's loopback, where
# the test's VMs reach them at 10.0.2.2.
#
#   test/ci-host.sh start      install and start both servers, and start
#                              recording NFS traffic and nfsd's state
#   test/ci-host.sh verify     check the host's view after the test
#   test/ci-host.sh logs       print the metadata service's log and the
#                              kernel's
#   test/ci-host.sh nfs-trace  stop recording and summarize it; the whole
#                              capture stays in /tmp/nixremote-host
set -euo pipefail
cd "$(dirname "$0")/.."

export_dir=/srv/nixremote
cache_dir=/srv/nixremote-cache
work=/tmp/nixremote-host
db=$work/meta.sqlite
pcap=$work/nfs.pcap

case ${1:-} in
  start)
    sudo apt-get update -q
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
      nfs-kernel-server sqlite3 tcpdump tshark
    sudo mkdir -p "$export_dir" "$cache_dir"
    # QEMU's user-mode network makes every guest connection come from the
    # host's loopback, from an unprivileged port: hence insecure. Nix runs
    # as root on the clients and chowns what it builds: hence
    # no_root_squash. The store's files are one export, and a binary cache
    # (a file:// store) is another; clients mount each by its path.
    for dir in "$export_dir" "$cache_dir"; do
      echo "$dir 127.0.0.1(rw,sync,insecure,no_root_squash,no_subtree_check)"
    done | sudo tee /etc/exports >/dev/null
    sudo systemctl restart nfs-kernel-server
    sudo exportfs -v

    mkdir -p "$work"
    # Every NFS packet both ways, callbacks included: they share the
    # clients' connections (the NFSv4.1 backchannel).
    sudo nohup tcpdump -i lo -s 0 -U -w "$pcap" tcp port 2049 >"$work/tcpdump.log" 2>&1 &
    sudo nohup test/nfsd-states >"$work/nfsd-states.log" 2>&1 &

    # --test-hooks: the test holds commits to crash a client mid-commit.
    nohup python3 server/nixremote-server --db "$db" --listen 127.0.0.1:8080 -v --test-hooks \
      >"$work/server.log" 2>&1 &
    echo $! >"$work/server.pid"
    for _ in $(seq 50); do
      curl -sf http://127.0.0.1:8080/v1/health >/dev/null && exit 0
      sleep 0.2
    done
    cat "$work/server.log"
    exit 1
    ;;

  verify)
    # Every path the service holds is on the export, and every store path
    # on the export is registered (lock files and dot files aside).
    registered=$(sqlite3 "$db" 'select path from ValidPaths' | LC_ALL=C sort)
    on_disk=$(find "$export_dir/nix/store" -mindepth 1 -maxdepth 1 -printf '/nix/store/%f\n' |
      grep -v -e '\.lock$' -e '^/nix/store/\.' | LC_ALL=C sort)
    if [[ $registered != "$on_disk" ]]; then
      echo "the metadata service and the NFS export disagree (< registered, > on disk):"
      diff <(echo "$registered") <(echo "$on_disk") || true
      exit 1
    fi
    echo "$(wc -l <<<"$registered") store paths, each registered with the service and present on the export:"
    echo "$registered"
    for name in shared client1 client2 client3 combined interrupted dropped applied cutoff substituted raced; do
      grep -q -- "-nixremote-$name\$" <<<"$registered" || { echo "no nixremote-$name output"; exit 1; }
    done
    # And what's on the export has the hash the service holds for it: a NAR
    # hash, which Nix stores as sha256:<hex>.
    mismatched=0
    while IFS='|' read -r path hash; do
      got=sha256:$(nix-store --dump "$export_dir$path" | sha256sum | cut -d' ' -f1)
      if [[ $got != "$hash" ]]; then
        echo "$path has hash $got on the export, but $hash registered"
        mismatched=1
      fi
    done < <(sqlite3 "$db" 'select path, hash from ValidPaths')
    [[ $mismatched == 0 ]] || exit 1
    echo "and each one's contents match the hash the service holds"
    ;;

  logs)
    echo "# nixremote-server"
    cat "$work/server.log"
    echo "# kernel $(uname -r)"
    sudo dmesg --ctime | tail -n 100
    ;;

  nfs-trace)
    sudo pkill -INT -x tcpdump || true
    sudo pkill -f test/nfsd-states || true
    sleep 1
    sudo chmod a+r "$pcap"
    trace() { tshark -r "$pcap" -n -T fields -e frame.time -e tcp.stream "$@" 2>&1; }

    echo "# nfsd's clients and the state each holds, whenever that changes"
    # Keyed by address: the names have spaces in them.
    awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^127\.0\.0\.1:/) addr = $i
           v = substr($0, length($1) + 2); if (last[addr] != v) print; last[addr] = v }' \
      "$work/nfsd-states.log"

    echo "# connections in the capture: time, tcp.stream, client port"
    trace -Y 'tcp.flags.syn == 1 && tcp.flags.ack == 0' -e tcp.srcport

    echo "# callbacks: the server's calls to clients, and their replies, by connection"
    tshark -r "$pcap" -n -Y '(tcp.srcport == 2049 && rpc.msgtyp == 0) || (tcp.dstport == 2049 && rpc.msgtyp == 1)' \
      -T fields -e tcp.stream -e _ws.col.Info 2>&1 |
      sed -E 's/ \(Call In [0-9]+\)//' | sort | uniq -c

    # A compound has a status per operation, and != would need all of them
    # to differ; > matches if any does. 2 is NOENT, which lookups get.
    echo "# NFS errors other than NOENT, by connection"
    tshark -r "$pcap" -n -Y 'nfs.nfsstat4 > 2' -T fields -e tcp.stream -e _ws.col.Info 2>&1 |
      awk -F'\t' '{ match($2, /NFS4ERR_[A-Z_]+/); print "stream " $1 ": " substr($2, RSTART, RLENGTH) }' |
      sort | uniq -c

    echo "# pauses of over 5 seconds on a connection, and what ended them"
    tshark -r "$pcap" -n -Y rpc -T fields -e frame.time_epoch -e tcp.stream -e _ws.col.Info 2>&1 |
      awk -F'\t' '{ if ($2 in last && $1 - last[$2] > 5) printf "stream %s quiet for %.1fs, then %s\n", $2, $1 - last[$2], $3
                    last[$2] = $1 }'
    ;;

  *)
    echo "usage: $0 start|verify|logs|nfs-trace" >&2
    exit 2
    ;;
esac
