#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/scenarios.sh
source "$ROOT/lib/scenarios.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

[[ "$(osd_service_name "$LAB_FSID" 7)" == "ceph-${LAB_FSID}@osd.7.service" ]] || fail "bad OSD service"
[[ "$(mon_service_name "$LAB_FSID" ceph-lab-mon-03)" == "ceph-${LAB_FSID}@mon.ceph-lab-mon-03.service" ]] || fail "bad mon service"

io_path_cmd="$(cgroup_io_max_path_command "ceph-${LAB_FSID}@osd.4.service")"
printf '%s\n' "$io_path_cmd" | grep -q 'systemctl show -p ControlGroup --value ceph-.*@osd.4.service' || fail "io.max discovery missing systemctl"
expected_cgroup_path="/sys/fs/cgroup\${cg}/io.max"
printf '%s\n' "$io_path_cmd" | grep -Fq "$expected_cgroup_path" || fail "io.max discovery missing cgroup path"

fake_bin_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$fake_bin_dir"
}
trap cleanup EXIT

cat >"$fake_bin_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_SYSTEMCTL_CGROUP:-present}" in
  present) printf '/system.slice/ceph-osd.slice/ceph@test.service\n' ;;
  empty) : ;;
  fail) exit 1 ;;
esac
EOF
chmod +x "$fake_bin_dir/systemctl"

resolved_path="$(PATH="$fake_bin_dir:$PATH" bash -c "$io_path_cmd")" ||
  fail "io.max discovery should succeed when ControlGroup is present"
[[ "$resolved_path" == "/sys/fs/cgroup/system.slice/ceph-osd.slice/ceph@test.service/io.max" ]] ||
  fail "bad resolved io.max path: $resolved_path"

empty_output="$(FAKE_SYSTEMCTL_CGROUP=empty PATH="$fake_bin_dir:$PATH" bash -c "$io_path_cmd" 2>/dev/null || true)"
[[ -z "$empty_output" ]] || fail "io.max discovery should print nothing for empty ControlGroup"
if FAKE_SYSTEMCTL_CGROUP=empty PATH="$fake_bin_dir:$PATH" bash -c "$io_path_cmd" >/dev/null 2>&1; then
  fail "io.max discovery should fail for empty ControlGroup"
fi
if FAKE_SYSTEMCTL_CGROUP=fail PATH="$fake_bin_dir:$PATH" bash -c "$io_path_cmd" >/dev/null 2>&1; then
  fail "io.max discovery should fail when systemctl fails"
fi

throttle="$(io_throttle_command '8:16' 65536 '/sys/fs/cgroup/x/io.max')"
[[ "$throttle" == "printf '%s\n' '8:16 rbps=65536 wbps=65536 riops=max wiops=max' | sudo tee /sys/fs/cgroup/x/io.max >/dev/null" ]] || fail "bad throttle command: $throttle"

unthrottle="$(io_unthrottle_command '8:16' '/sys/fs/cgroup/x/io.max')"
[[ "$unthrottle" == "printf '%s\n' '8:16 rbps=max wbps=max riops=max wiops=max' | sudo tee /sys/fs/cgroup/x/io.max >/dev/null" ]] || fail "bad unthrottle command: $unthrottle"

pool_cmds="$(pool_create_commands alert-test)"
printf '%s\n' "$pool_cmds" | grep -q 'ceph osd pool create alert-test 1' || fail "missing pool create"
printf '%s\n' "$pool_cmds" | grep -q 'ceph osd pool set alert-test min_size 2' || fail "missing min_size"

cleanup_cmds="$(pool_cleanup_commands alert-test)"
printf '%s\n' "$cleanup_cmds" | grep -q 'ceph osd pool delete alert-test alert-test --yes-i-really-really-mean-it' || fail "missing pool delete"

ok "scenario command generation"
