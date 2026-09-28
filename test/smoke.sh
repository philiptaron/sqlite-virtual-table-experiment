#!/usr/bin/env bash
# End-to-end check of nixremote against the Nix on PATH, without NFS.
#
# Two "hosts", a and b, share one chroot store directory and one backend,
# each with its own state directory and so its own db.sqlite pointer file;
# a may not delete store paths, b may. A plain chroot store with an
# ordinary db.sqlite is the control: every query must answer the same there.
#
#   test/smoke.sh [http|sqlite]
#
# http (the default) runs server/nixremote-server as the backend; sqlite
# has the hosts open the backend database directly.
set -euo pipefail
[[ -n ${IN_NIX_SHELL:-} ]] || exec nix develop --quiet -c bash "$0" "$@"

cd "$(dirname "$0")/.."
make -s
for lib in "$PWD"/libnixremote.{so,dylib}; do [[ -e $lib ]] && break; done

# Nix refuses store directories under a symlink, such as /tmp on macOS.
work=$(cd "$(mktemp -d)" && pwd -P)
server_pid=
trap '[[ -z $server_pid ]] || kill $server_pid; chmod -R u+w "$work"; rm -rf "$work"' EXIT

case ${1:-http} in
  sqlite)
    backend="file:$work/remote.sqlite"
    ;;
  http)
    server/nixremote-server --db "$work/remote.sqlite" --listen 127.0.0.1:0 --port-file "$work/port" --test-hooks 2>"$work/server.log" &
    server_pid=$!
    for _ in $(seq 100); do
      [[ -e $work/port ]] && break
      sleep 0.1
    done
    [[ -e $work/port ]] || { cat "$work/server.log"; exit 1; }
    backend="http://127.0.0.1:$(cat "$work/port")"
    ;;
  *)
    echo "usage: $0 [http|sqlite]" >&2
    exit 2
    ;;
esac
echo "# backend: $backend"
NIXREMOTE_LIB=$lib scripts/nixremote-mkstate "$work/a" "$backend" deny >/dev/null
NIXREMOTE_LIB=$lib scripts/nixremote-mkstate "$work/b" "$backend" allow >/dev/null
a="local?root=$work/root&state=$work/a"
b="local?root=$work/root&state=$work/b"
control="local?root=$work/control"

failures=0
ok() { echo "ok   $*"; }
not_ok() { echo "FAIL $*"; failures=$((failures + 1)); }

# Run nix with the plugin loaded; the control store runs without it.
nixr() { NIX_CONFIG="plugin-files = $lib" "$@"; }

# same NAME CMD...: CMD, with @ standing for the store URL, prints the same
# thing (and succeeds or fails alike) against host a and the control store.
same() {
  local name=$1 out_a out_c rc_a=0 rc_c=0
  shift
  # The quotes stop bash 5.2 from expanding the & in the URL to the match.
  out_a=$(nixr "${@//@/"$a"}" 2>&1) || rc_a=$?
  out_c=$("${@//@/"$control"}" 2>&1) || rc_c=$?
  if [[ $rc_a == "$rc_c" && $out_a == "$out_c" ]]; then
    ok "$name"
  else
    not_ok "$name"
    diff <(echo "exit $rc_c"; echo "$out_c") <(echo "exit $rc_a"; echo "$out_a") | sed 's/^/     /' || true
  fi
}

# sorted CMD...: CMD with its output sorted, for commands that print in
# nondeterministic order.
sorted() {
  local rc=0 out
  out=$("$@" 2>&1) || rc=$?
  sort <<<"$out"
  return $rc
}

backend_count() { sqlite3 "$work/remote.sqlite" "select count(*) from $1"; }

# A small closure that is already in the local store: sqlite's bin output.
top=$(dirname "$(dirname "$(readlink -f "$(command -v sqlite3)")")")
closure=$(nix path-info -r "$top")
n=$(wc -l <<<"$closure" | tr -d ' ')
echo "# test closure: $top ($n paths)"

echo "# registering paths"
nixr nix copy --no-check-sigs --to "$a" "$top"
nix copy --no-check-sigs --to "$control" "$top"
[[ $(backend_count ValidPaths) == "$n" ]] && ok "backend has $n paths" || not_ok "backend has $(backend_count ValidPaths) paths, want $n"

same "path info (sizes, sigs, refs)" nix path-info --store @ -r --size --closure-size --sigs "$top"
same "all valid paths" nix path-info --store @ --all
for p in $closure; do
  same "referrers of ${p##*/}" nix-store --store @ -q --referrers "$p"
  hash=${p##*/}; hash=${hash%%-*}
  same "path from hash part ${hash}" nix store path-from-hash-part --store @ "$hash"
done
same "path from unknown hash part" nix store path-from-hash-part --store @ 00000000000000000000000000000000
same "verify contents" sorted nix store verify --store @ --all
same "re-copy is a no-op" nix copy --no-check-sigs --to @ "$top"

echo "# derivations"
expr='derivation { name = "nixremote-test"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo hi > $out" ]; }'
drv=$(nixr nix-instantiate --store "$a" -E "$expr")
nix-instantiate --store "$control" -E "$expr" >/dev/null
same "derivation outputs" nix-store --store @ -q --outputs "$drv"
[[ $(backend_count DerivationOutputs) == 1 ]] && ok "backend has the derivation output" || not_ok "backend has $(backend_count DerivationOutputs) derivation outputs, want 1"
# Enough paths that scanning them all takes several pages from the service.
many='builtins.genList (i: derivation { name = "nixremote-many-${toString i}"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo ${toString i} > $out" ]; }) 40'
nixr nix-instantiate --store "$a" -E "$many" >/dev/null 2>&1
nix-instantiate --store "$control" -E "$many" >/dev/null 2>&1
same "all valid paths, across several pages" nix path-info --store @ --all

echo "# a second host sharing the store"
if diff <(nixr nix path-info --store "$b" --all) <(nixr nix path-info --store "$a" --all) >/dev/null; then
  ok "host b sees host a's paths"
else
  not_ok "host b sees different paths than host a"
fi

echo "# garbage collection"
if nixr nix store gc --store "$a" >/dev/null 2>"$work/gc-a.err"; then
  not_ok "gc on host a (deletes=deny) should fail"
else
  grep -q 'deletes=deny' "$work/gc-a.err" && ok "gc on host a is refused" || { not_ok "gc on host a failed for another reason"; sed 's/^/     /' "$work/gc-a.err"; }
fi
[[ $(backend_count ValidPaths) == $((n + 41)) ]] && ok "refused gc deleted nothing" || not_ok "refused gc left $(backend_count ValidPaths) paths"

if nixr nix store delete --store "$b" "$(head -n1 <<<"$closure")" >/dev/null 2>&1; then
  not_ok "deleting a referenced path should fail"
else
  ok "deleting a referenced path fails"
fi
nixr nix-store --store "$b" --realise "$top" --add-root "$work/b-root" >/dev/null
nixr nix store gc --store "$b" >/dev/null 2>&1
[[ $(backend_count ValidPaths) == "$n" ]] && ok "gc on host b keeps the rooted closure, drops the derivation" || not_ok "gc on host b left $(backend_count ValidPaths) paths, want $n"
rm "$work/b-root"
# Paths open in running processes (on macOS, the libraries nix itself has
# mapped) are roots too, so an unrooted gc need not delete everything:
# compare with the control store instead.
nixr nix store gc --store "$b" >/dev/null 2>&1
nix store gc --store "$control" >/dev/null 2>&1
same "valid paths after unrooted gc, seen from host a" nix path-info --store @ --all
if nixr nix path-info --store "$a" "$top" >/dev/null 2>&1; then
  not_ok "host a still thinks ${top##*/} is valid"
else
  ok "host a sees host b's deletion of ${top##*/}"
fi

echo "# concurrent registration of the same closure"
nixr nix copy --no-check-sigs --to "$a" "$top" 2>"$work/copy-a.err" & pid_a=$!
nixr nix copy --no-check-sigs --to "$b" "$top" 2>"$work/copy-b.err" & pid_b=$!
rc_a=0 rc_b=0
wait $pid_a || rc_a=$?
wait $pid_b || rc_b=$?
[[ $rc_a == 0 && $rc_b == 0 ]] && ok "both copies succeed" || { not_ok "copies exited $rc_a and $rc_b"; cat "$work"/copy-*.err; }
nix copy --no-check-sigs --to "$control" "$top" 2>/dev/null
same "path info after concurrent copies" nix path-info --store @ -r --size --closure-size --sigs "$top"

if [[ $backend == http* ]]; then
  echo "# a commit that conflicts with another host is retried by Nix"
  fail_commits() { curl -sf -H 'Content-Type: application/json' -d "{\"count\":$1}" "$backend/v1/test/fail-commits"; }
  fail_commits 1 >/dev/null
  if nixr nix-instantiate --store "$a" -E "${expr/nixremote-test/nixremote-retry}" >/dev/null 2>"$work/retry.err"; then
    [[ $(fail_commits 0) == '{"remaining": 0}' ]] && ok "registration succeeds after an injected conflict" || not_ok "the injected conflict was never hit"
  else
    not_ok "registration after an injected conflict"
    sed 's/^/     /' "$work/retry.err"
  fi
fi

echo "# a path registered behind Nix's back reads as a retryable conflict"
sqlite3 "$work/b/db/db.sqlite" >"$work/conflict.out" 2>&1 <<EOF || true
.load $lib sqlite3_nixremote_init
insert into ValidPaths (path, hash, registrationTime) values ('$(head -n1 <<<"$closure")', 'sha256:00', 0);
EOF
grep -Eq 'registered concurrently|already registered' "$work/conflict.out" && ok "duplicate insert is SQLITE_BUSY" || { not_ok "duplicate insert"; sed 's/^/     /' "$work/conflict.out"; }

echo
if [[ $failures == 0 ]]; then
  echo "all passed"
else
  echo "$failures failed"
  exit 1
fi
