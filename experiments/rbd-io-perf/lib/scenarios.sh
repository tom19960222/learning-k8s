#!/usr/bin/env bash
# Scenario building blocks: single-point run with taint detection,
# matrix rounds, A/B interleaving, machine verdict emission.
# Requires common.sh, fio.sh, collect.sh.

write_prediction() {
  printf '%s\n' "$2" > "$1/prediction.txt"
}

run_pattern_once() {
  local bundle="$1" round="$2" ip="$3" dev="$4" entry="$5" host_dev="${6:-}"
  local name="${entry%%:*}" rd="$bundle/$round"
  mkdir -p "$rd"
  collect_ceph_status "$rd/ceph-pre.txt"
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

emit_verdict() {
  local bundle="$1" pattern="$2" metric="$3" expect="$4" cov="$5" base="$6" var="$7"
  local out
  if ! out="$(python3 "$RBDPERF_ROOT/lib/verdict.py" compare \
    --metric "$metric" --expect "$expect" --noise-cov "$cov" \
    --baseline "$base" --variant "$var")"; then
    die "verdict.py 執行失敗（pattern: $pattern）"
  fi
  printf '%s\n' "$out" > "$bundle/verdict-$pattern.json"
  printf '%s\n' "$out"
}
