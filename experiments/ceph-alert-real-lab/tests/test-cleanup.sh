#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

make_fake_kubectl() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
printf 'kubectl-live-noise\n'
EOF
  chmod +x "$path"
}

make_fake_ssh() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
command=''
seen_host=0
for arg in "\$@"; do
  if [[ "\$seen_host" -eq 0 ]]; then
    case "\$arg" in
      *@*)
        seen_host=1
        ;;
    esac
    continue
  fi
  if [[ -n "\$command" ]]; then
    command="\$command \$arg"
  else
    command="\$arg"
  fi
done
printf 'ssh:%s\n' "\$command" >>"$trace_file"
case "\$command" in
  "sudo -n cephadm shell -- ceph osd pool delete alert-slow-ops alert-slow-ops --yes-i-really-really-mean-it")
    printf 'delete-slow-ops-noise\n'
    exit 0
    ;;
  "sudo -n cephadm shell -- ceph osd pool delete alert-pg-availability alert-pg-availability --yes-i-really-really-mean-it")
    printf 'delete-pg-availability-noise\n'
    exit 1
    ;;
  "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs")
    exit 0
    ;;
  "lsblk -no MAJ:MIN /dev/sdb | head -1")
    printf '8:16\n'
    exit 0
    ;;
  *"printf '%s\\n' \"/sys/fs/cgroup"*)
    printf '/sys/fs/cgroup/system.slice/fake/io.max\n'
    exit 0
    ;;
  *"rbps=max wbps=max riops=max wiops=max"* )
    printf 'unthrottle-noise\n'
    exit 0
    ;;
esac
printf 'unexpected ssh command: %s\n' "\$command" >&2
exit 1
EOF
  chmod +x "$path"
}

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trace_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$trace_file"
  rm -rf "$fake_bin_dir"
}

trap cleanup EXIT

make_fake_kubectl "$fake_bin_dir/kubectl" "$trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$trace_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/cleanup.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "cleanup should best-effort succeed, got $rc"
[[ ! -s "$stdout_file" ]] || fail "cleanup polluted stdout"
grep -q '^kubectl:delete namespace ceph-alert-lab --ignore-not-found=true$' "$trace_file" || fail "missing namespace delete"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool delete alert-slow-ops alert-slow-ops --yes-i-really-really-mean-it$' "$trace_file" || fail "missing slow-ops pool delete"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool delete alert-pg-availability alert-pg-availability --yes-i-really-really-mean-it$' "$trace_file" || fail "missing pg-availability pool delete"
grep -q '^ssh:stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs$' "$trace_file" || fail "missing cgroup v2 probe"
grep -q '^ssh:lsblk -no MAJ:MIN /dev/sdb | head -1$' "$trace_file" || fail "missing MAJ:MIN probe"
grep -Eq "^ssh:printf '%s\\\\n' '8:16 rbps=max wbps=max riops=max wiops=max' \\| sudo tee /sys/fs/cgroup/system\\.slice/fake/io\\.max >/dev/null$" "$trace_file" || fail "missing cgroup cleanup command"
if grep -Eq 'kubectl-live-noise|delete-slow-ops-noise|delete-pg-availability-noise|unthrottle-noise' "$stdout_file"; then
  fail "live command stdout leaked into cleanup stdout"
fi

ok "cleanup best-effort and stdout clean"
