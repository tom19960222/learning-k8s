#!/usr/bin/env bash
# Scenario building blocks: single-point run with taint detection,
# matrix rounds, A/B interleaving, machine verdict emission.
# Requires common.sh, fio.sh, collect.sh. run_qm_variant_scenario also
# requires pve.sh (vm_set/vm_cold_restart/vm_assert_cmdline/vm_guest_ip).

write_prediction() {
  printf '%s\n' "$2" > "$1/prediction.txt"
}

run_pattern_once() {
  local bundle="$1" round="$2" ip="$3" dev="$4" entry="$5" host_dev="${6:-}"
  local name="${entry%%:*}" rd="$bundle/$round"
  mkdir -p "$rd"
  collect_ceph_status "$rd/ceph-pre.txt"
  [ -e "$bundle/ceph-baseline.txt" ] || cp "$rd/ceph-pre.txt" "$bundle/ceph-baseline.txt"
  guard_check "$rd/ceph-pre.txt" "$bundle/ceph-baseline.txt"
  local iostat_pid=""
  if [ -n "$host_dev" ]; then
    sample_iostat_host "$host_dev" 75 "$rd/iostat-host-$name.txt" &
    iostat_pid=$!
  fi
  guest_ssh "$ip" "sudo $(fio_cmd "$entry" "$dev")" > "$rd/$name.json" || {
    # No job control (set -m unavailable in this harness), so kill only
    # reaches the backgrounded sample_iostat_host subshell, not its remote
    # ssh child — that would leave an orphaned iostat on the PVE host.
    # iostat -x 1 75 self-terminates within 75s, so waiting here is
    # bounded and guarantees no orphan survives.
    [ -n "$iostat_pid" ] && wait "$iostat_pid" 2>/dev/null
    die "fio $name 執行失敗"
  }
  [ -n "$iostat_pid" ] && wait "$iostat_pid" 2>/dev/null
  collect_ceph_status "$rd/ceph-post.txt"
  guard_check "$rd/ceph-post.txt" "$bundle/ceph-baseline.txt"
  if ! taint_check "$rd/ceph-post.txt"; then
    mv "$rd/$name.json" "$rd/$name.json.tainted"
    return 1
  fi
  return 0
}

run_matrix_rounds() {
  local bundle="$1" label="$2" ip="$3" dev="$4" n="$5" host_dev="${6:-}"
  local r entry name retry_round
  for r in $(seq 1 "$n"); do
    for entry in $FIO_PATTERNS; do
      if ! run_pattern_once "$bundle" "$label-r$r" "$ip" "$dev" "$entry" "$host_dev"; then
        # Retry writes to its own round dir so the first attempt's
        # .tainted evidence is never clobbered by the retry's run.
        retry_round="$label-r$r-retry"
        # NOTE: bash 3.2 under a UTF-8 locale mis-parses "$var" as part of
        # the identifier when immediately followed by full-width CJK
        # punctuation (e.g. "，"/"）") with no ASCII separator, crashing
        # under set -u ("unbound variable"). Always brace ${var} when a
        # CJK punctuation mark follows directly.
        log "tainted，重試一次: $entry ($label-r${r}，重試寫入 $retry_round)"
        if ! run_pattern_once "$bundle" "$retry_round" "$ip" "$dev" "$entry" "$host_dev"; then
          name="${entry%%:*}"
          die "連續 tainted，中止（${entry}）；證據保留於 $bundle/$label-r$r/$name.json.tainted 與 $bundle/$retry_round/$name.json.tainted"
        fi
      fi
    done
  done
}

ab_rounds() {
  local bundle="$1" n="$2" setup_a="$3" setup_b="$4" run_a="$5" run_b="$6"
  local r
  for r in $(seq 1 "$n"); do
    log "=== A/B round $r/$n: A ==="
    "$setup_a"; "$run_a" "$r"
    log "=== A/B round $r/$n: B ==="
    "$setup_b"; "$run_b" "$r"
  done
}

run_qm_variant_scenario() {
  # Shared A/B engine for the "qm set <disk-spec>" style variants (E-04..
  # E-08). A = baseline_spec, B = variant_spec (verified via QEMU cmdline
  # after cold restart). Rounds are interleaved (A/B/A/B...) via ab_rounds so
  # cluster background-load drift doesn't get misread as a knob effect
  # (H-029). Ends by restoring the disk to baseline_spec (no restart — the
  # caller's next scenario restarts as part of its own A setup, or does a
  # final restart itself if it needs a running guest without restarting).
  local scen="$1" pred="$2" base_spec="$3" var_spec="$4" verify="$5" rounds="$6"
  local b
  b="$(new_bundle "$scen")"
  write_prediction "$b" "$pred"

  # shellcheck disable=SC2329  # invoked indirectly by ab_rounds via "$setup_a"
  _rqvs_setup_a() {
    vm_set --virtio1 "$base_spec"
    vm_cold_restart
  }
  # shellcheck disable=SC2329  # invoked indirectly by ab_rounds via "$setup_b"
  _rqvs_setup_b() {
    vm_set --virtio1 "$var_spec"
    vm_cold_restart
    vm_assert_cmdline "$verify"
  }
  # shellcheck disable=SC2329  # invoked indirectly via _rqvs_run_a/_rqvs_run_b
  _rqvs_run_side() {
    local side="$1" rnd="$2" ip entry
    ip="$(vm_guest_ip)"
    for entry in $FIO_PATTERNS; do
      if ! run_pattern_once "$b" "$side-r$rnd" "$ip" /dev/vdb "$entry"; then
        run_pattern_once "$b" "$side-r$rnd-retry" "$ip" /dev/vdb "$entry" ||
          die "連續 tainted（${entry}）"
      fi
    done
  }
  # shellcheck disable=SC2329  # invoked indirectly by ab_rounds via "$run_a"
  _rqvs_run_a() { _rqvs_run_side A "$1"; }
  # shellcheck disable=SC2329  # invoked indirectly by ab_rounds via "$run_b"
  _rqvs_run_b() { _rqvs_run_side B "$1"; }

  ab_rounds "$b" "$rounds" _rqvs_setup_a _rqvs_setup_b _rqvs_run_a _rqvs_run_b
  vm_set --virtio1 "$base_spec"
  printf '%s\n' "$b"
}

emit_verdict() {
  local bundle="$1" pattern="$2" metric="$3" expect="$4" cov="$5" base="$6" var="$7"
  local out
  if ! out="$(python3 "$RBDPERF_ROOT/lib/verdict.py" compare \
    --metric "$metric" --expect "$expect" --noise-cov "$cov" \
    --baseline "$base" --variant "$var")"; then
    die "verdict.py 執行失敗（pattern: ${pattern}）"
  fi
  printf '%s\n' "$out" > "$bundle/verdict-$pattern.json"
  printf '%s\n' "$out"
}
