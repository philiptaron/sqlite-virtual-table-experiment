#!/usr/bin/env bash
# The host half of test/nfs-cluster.nix, for an Ubuntu machine such as
# GitHub Actions' ubuntu-latest: an NFS export for the shared store's files
# and nixremote-server for its metadata, both on the host's loopback, where
# the test's VMs reach them at 10.0.2.2.
#
#   test/ci-host.sh start    install and start both servers
#   test/ci-host.sh verify   check the host's view after the test
#   test/ci-host.sh logs     print the metadata service's log
set -euo pipefail
cd "$(dirname "$0")/.."

export_dir=/srv/nixremote
work=/tmp/nixremote-host
db=$work/meta.sqlite

case ${1:-} in
  start)
    sudo apt-get update -q
    sudo apt-get install -yq --no-install-recommends nfs-kernel-server sqlite3
    sudo mkdir -p "$export_dir"
    # QEMU's user-mode network makes every guest connection come from the
    # host's loopback, from an unprivileged port: hence insecure. Nix runs
    # as root on the clients and chowns what it builds: hence
    # no_root_squash. fsid=0 makes this the NFSv4 root, so clients mount
    # 10.0.2.2:/.
    echo "$export_dir 127.0.0.1(rw,sync,insecure,no_root_squash,no_subtree_check,fsid=0)" |
      sudo tee /etc/exports >/dev/null
    sudo systemctl restart nfs-kernel-server
    sudo exportfs -v

    mkdir -p "$work"
    nohup python3 server/nixremote-server --db "$db" --listen 127.0.0.1:8080 -v \
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
    for name in shared client1 client2 client3 combined; do
      grep -q -- "-nixremote-$name\$" <<<"$registered" || { echo "no nixremote-$name output"; exit 1; }
    done
    ;;

  logs)
    cat "$work/server.log"
    ;;

  *)
    echo "usage: $0 start|verify|logs" >&2
    exit 2
    ;;
esac
