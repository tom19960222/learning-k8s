#!/usr/bin/env bash
# Full automation-safe chain. Gated cluster-scope experiments do not exist in
# this harness (cut from scope per HYPOTHESES.md charter); cleanup always
# runs at the end regardless of where the chain stops.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
require_flag_ok=0
for a in "$@"; do [ "$a" = "--yes-really-inject" ] && require_flag_ok=1; done
[ "$require_flag_ok" -eq 1 ] || { echo "需要 --yes-really-inject" >&2; exit 1; }

trap 'bash "$here/cleanup.sh" --yes-really-inject || true' EXIT
set -e
bash "$here/preflight.sh"
bash "$here/krbd-check.sh" --yes-really-inject
bash "$here/exp0-host-ceiling.sh" --yes-really-inject
bash "$here/baseline.sh" --yes-really-inject
bash "$here/scenario-exp-axis.sh" --yes-really-inject
bash "$here/scenario-exp1-cache.sh" --yes-really-inject
bash "$here/scenario-exp4-aio.sh" --yes-really-inject
bash "$here/scenario-exp2-iothread.sh" --yes-really-inject
bash "$here/scenario-exp8-queues.sh" --yes-really-inject
bash "$here/scenario-exp9-layout.sh" --yes-really-inject
bash "$here/scenario-exp10-qdepth.sh" --yes-really-inject
bash "$here/scenario-exp11-sched.sh" --yes-really-inject
bash "$here/scenario-exp12-allocsize.sh" --yes-really-inject
bash "$here/scenario-exp13-readahead.sh" --yes-really-inject
bash "$here/scenario-exp14-rxbounce.sh" --yes-really-inject
# exp15 is a documented stub (see scenario-exp15-rbdcache.sh); it exits 2 on
# purpose, which is not a chain failure.
bash "$here/scenario-exp15-rbdcache.sh" --yes-really-inject || [ "$?" -eq 2 ]
