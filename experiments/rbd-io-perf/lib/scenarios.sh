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
    [ -n "$iostat_pid" ] && kill "$iostat_pid" 2>/dev/null
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
  local r entry
  for r in $(seq 1 "$n"); do
    for entry in $FIO_PATTERNS; do
      if ! run_pattern_once "$bundle" "$label-r$r" "$ip" "$dev" "$entry" "$host_dev"; then
        log "tainted，重試一次: $entry ($label-r$r)"
        run_pattern_once "$bundle" "$label-r$r" "$ip" "$dev" "$entry" "$host_dev" ||
          die "連續 tainted，中止（$entry）"
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
  out="$(python3 "$RBDPERF_ROOT/lib/verdict.py" compare \
    --metric "$metric" --expect "$expect" --noise-cov "$cov" \
    --baseline "$base" --variant "$var")"
  printf '%s\n' "$out" > "$bundle/verdict-$pattern.json"
  printf '%s\n' "$out"
}
