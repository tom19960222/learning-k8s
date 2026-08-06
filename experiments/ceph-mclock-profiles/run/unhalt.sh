#!/usr/bin/env bash
# ceph-mclock-profiles — 解除「watchdog 停佇列」的薄入口（Task 0.3）。
#
# 用法：run/unhalt.sh "<理由>" [--clear-counts]
#
#   理由必填，會寫進 results/watchdog-state.json 的 unhalt_log（append-only 留痕）。
#   trigger counts 與 drift streak **預設保留**——沒被排除的累積不該憑空歸零；
#   確定已排除（例如 recalibrate 裁決完）才加 --clear-counts。
#
# 本檔不碰叢集、不動 VM：只改本機的 watchdog 狀態檔。真正的修復是人工做的，
# 流程見 README §4.7；**嚴禁 deallocate 任何 VM**。
#
# 離開碼：0 已解除（或本來就沒停）／1 參數或寫入錯誤
# shellcheck source-path=SCRIPTDIR
set -u

# 這不是佇列入口（不跑 execution），所以直接 source lib/pipeline.sh 取狀態機的
# 狀態檔語意，不經 run/queue.sh。
# shellcheck source=../lib/pipeline.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/pipeline.sh"

[ $# -ge 1 ] || die "用法：run/unhalt.sh \"<理由>\" [--clear-counts]"

pipeline_unhalt "$@"
