#!/usr/bin/env bash
# ceph-mclock-profiles — transport seam（Task 2）。bash 3.2 相容。
# 供 source 使用；stdout 只放機器要抓的那行，log/progress 一律 stderr。
#
# 依賴：inventory（ADMIN_PUBLIC_IP / ADMIN_NAME / inv_ip）由 lib/inventory.sh 提供，
# 該檔會 source 本檔，所以入口腳本只要 `. lib/inventory.sh` 即可拿到全部 helper。
# shellcheck shell=bash

[ -n "${MCLOCK_COMMON_LOADED:-}" ] && return 0
MCLOCK_COMMON_LOADED=1

MCLOCK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCLOCK_ROOT="$(cd "$MCLOCK_LIB/.." && pwd)"
REPO_ROOT="$(cd "$MCLOCK_ROOT/../.." && pwd)"

SSH_USER="${SSH_USER:-ikaros}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/.ssh/id_ed25519}"
RESULTS_DIR="${RESULTS_DIR:-$MCLOCK_ROOT/results}"
INVENTORY_JSON="${INVENTORY_JSON:-$MCLOCK_ROOT/azure/inventory.json}"
VERDICT_PY="${VERDICT_PY:-$MCLOCK_LIB/verdict.py}"
# 遠端背景 process registry（plan Global Constraints：任何遠端背景 process 都要登記）
BG_REGISTRY_DIR="${BG_REGISTRY_DIR:-/run/mclock}"
# 輪詢間隔（測試可注入）
POLL_INTERVAL="${POLL_INTERVAL:-5}"
# node_ssh_to 的 bastion 端寬限：遠端 timeout 之後再等這麼久才 kill 本地 ssh
NODE_SSH_KILL_GRACE="${NODE_SSH_KILL_GRACE:-10}"

# --- log / die ---------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf '[%s] FATAL: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

require_inject_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--yes-really-inject" ] && return 0
  done
  die "此腳本會變更遠端狀態，需要 --yes-really-inject"
}

# --- cleanup stack（唯一 top-level trap、LIFO）---------------------------------

_CLEANUP_STACK=()

cleanup_push() {
  [ $# -eq 1 ] || die "cleanup_push 只收一個指令字串"
  _CLEANUP_STACK[${#_CLEANUP_STACK[@]}]="$1"
}

cleanup_run() {
  local i cmd
  i=$((${#_CLEANUP_STACK[@]} - 1))
  while [ "$i" -ge 0 ]; do
    cmd="${_CLEANUP_STACK[$i]}"
    i=$((i - 1))
    eval "$cmd" || log "cleanup 失敗（續行）：${cmd}"
  done
  _CLEANUP_STACK=()
}

_cleanup_on_signal() { # <exit-code>
  log "收到訊號，執行 cleanup stack"
  cleanup_run
  exit "$1"
}

trap 'cleanup_run' EXIT
trap '_cleanup_on_signal 130' INT
trap '_cleanup_on_signal 143' TERM

# --- ssh transport -----------------------------------------------------------

_require_inventory() {
  [ -n "${ADMIN_PUBLIC_IP:-}" ] && [ -n "${ADMIN_NAME:-}" ] && return 0
  die "inventory 未載入：請先呼叫 inventory_load"
}

# 組出 ssh argv（bash 3.2 沒有 nameref，用固定名稱的全域陣列當 out-param）。
# 選項逐個寫死，不用「一整串變數」展開。
_node_ssh_argv() { # <node-name>
  local name="$1" ip
  _SSH_ARGV=(
    ssh
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=accept-new
  )
  if [ "$name" = "$ADMIN_NAME" ]; then
    _SSH_ARGV[${#_SSH_ARGV[@]}]="${SSH_USER}@${ADMIN_PUBLIC_IP}"
  else
    ip="$(inv_ip "$name")" || die "node_ssh：inventory 查不到 ${name}"
    _SSH_ARGV[${#_SSH_ARGV[@]}]="-o"
    _SSH_ARGV[${#_SSH_ARGV[@]}]="ProxyJump=${SSH_USER}@${ADMIN_PUBLIC_IP}"
    _SSH_ARGV[${#_SSH_ARGV[@]}]="${SSH_USER}@${ip}"
  fi
}

# node_ssh <name> <cmd...>：無額外逾時包裝（連線層仍有 ConnectTimeout/ServerAlive）。
node_ssh() {
  [ $# -ge 2 ] || die "用法：node_ssh <node> <cmd...>"
  local name="$1"; shift
  _require_inventory
  _node_ssh_argv "$name"
  # `< /dev/null` 是這個 bug class 的唯一根治點：ssh 未帶 -n 會讀乾 stdin，
  # 在 `while read ...; do node_ssh ...; done <<< "$list"` 裡會把 herestring 整個
  # 吸走、迴圈只跑第一圈。真機三度踩到（15 台只 probe 到 1 台／N 個 prometheus
  # query 只送第一個／capacity 只鎖到 osd.0）。指令一律以參數傳入、從不從 stdin
  # 讀，所以在此隔離永遠安全；tests/test-common.sh 有斷言守住「沒有呼叫端餵 stdin」。
  "${_SSH_ARGV[@]}" "$@" < /dev/null
}

# node_ssh_to <secs> <name> <cmd...>：遠端包 coreutils timeout（Ubuntu 有；macOS 沒有，
# 所以不在 bastion 端包），bastion 端另設 $SECONDS deadline，逾時 kill 本地 ssh pid。
# 逾時回 124（與 timeout(1) 一致）。遠端 stdout 先落暫存檔再一次吐出（非串流）。
node_ssh_to() {
  [ $# -ge 3 ] || die "用法：node_ssh_to <secs> <node> <cmd...>"
  local secs="$1" name="$2"; shift 2
  case "$secs" in ''|*[!0-9]*) die "node_ssh_to：secs 必須是整數秒（got=${secs}）" ;; esac
  _require_inventory
  local b64 remote outfile pid rc start deadline
  # 指令以 base64 過線，避免多層 shell 的引號地獄
  b64="$(printf '%s' "$*" | base64 | tr -d '\n')"
  remote="_c=\$(printf %s '${b64}' | base64 --decode); timeout ${secs} bash -c \"\$_c\""
  _node_ssh_argv "$name"
  outfile="$(mktemp "${TMPDIR:-/tmp}/mclock-ssh.XXXXXX")"

  "${_SSH_ARGV[@]}" "$remote" >"$outfile" < /dev/null &
  pid=$!
  start=$SECONDS
  deadline=$((secs + NODE_SSH_KILL_GRACE))
  rc=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$deadline" ]; then
      log "node_ssh_to：${name} 超過 bastion deadline ${deadline}s，kill 本地 ssh pid ${pid}"
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rc=124
      break
    fi
    sleep 0.2
  done
  if [ -z "$rc" ]; then
    wait "$pid"
    rc=$?
  fi
  cat "$outfile"
  rm -f "$outfile"
  return "$rc"
}

# with_deadline <secs> <fn> [args...]：輪詢直到 fn 成功或逾時（回 124）。
with_deadline() {
  [ $# -ge 2 ] || die "用法：with_deadline <secs> <fn> [args...]"
  local secs="$1"; shift
  case "$secs" in ''|*[!0-9]*) die "with_deadline：secs 必須是整數秒（got=${secs}）" ;; esac
  local start=$SECONDS
  while :; do
    if "$@"; then return 0; fi
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      log "with_deadline：${1} 在 ${secs}s 內未達成"
      return 124
    fi
    sleep "$POLL_INTERVAL"
  done
}

# --- 遠端背景 process registry ------------------------------------------------

# remote_bg_start <name> <run-id> <cmd...>：以 setsid 起背景 process，
# 於 <registry>/<run-id>.pid 登記 pid（= pgid）、<run-id>.cmd 留 cmdline 指紋。
# stdout = 遠端 pid（機器行）。
remote_bg_start() {
  [ $# -ge 3 ] || die "用法：remote_bg_start <node> <run-id> <cmd...>"
  local name="$1" runid="$2"; shift 2
  _require_inventory
  local b64 remote dir
  dir="$BG_REGISTRY_DIR"
  b64="$(printf '%s' "$*" | base64 | tr -d '\n')"
  remote="$(cat <<REMOTE
set -u
sudo mkdir -p ${dir}
sudo chown ${SSH_USER}: ${dir}
if [ -s ${dir}/${runid}.pid ] && sudo kill -0 "\$(cat ${dir}/${runid}.pid)" 2>/dev/null; then
  echo "remote_bg_start: ${runid} 已在執行（registry 有活著的 pid），拒絕覆蓋" >&2
  exit 2
fi
printf %s '${b64}' | base64 --decode > ${dir}/${runid}.cmd
rm -f ${dir}/${runid}.pid
sudo setsid bash -c 'echo \$\$ > ${dir}/${runid}.pid; exec bash ${dir}/${runid}.cmd' \
  > ${dir}/${runid}.log 2>&1 < /dev/null &
_i=0
while [ \$_i -lt 50 ] && [ ! -s ${dir}/${runid}.pid ]; do sleep 0.1; _i=\$((_i+1)); done
[ -s ${dir}/${runid}.pid ] || { echo "remote_bg_start: ${runid} pidfile 未產生" >&2; exit 1; }
cat ${dir}/${runid}.pid
REMOTE
)"
  node_ssh "$name" "$remote"
}

# remote_bg_stop <name> <run-id>：kill 整個 process group 後清 pidfile；冪等。
remote_bg_stop() {
  [ $# -eq 2 ] || die "用法：remote_bg_stop <node> <run-id>"
  local name="$1" runid="$2"
  _require_inventory
  local remote dir
  dir="$BG_REGISTRY_DIR"
  remote="$(cat <<REMOTE
set -u
_p=${dir}/${runid}.pid
if [ -s "\$_p" ]; then
  _pid=\$(cat "\$_p")
  # **只用 pid，不用 -pgid**：實測 \`sudo kill -TERM -<pgid>\` 會連帶終止我們自己的
  # ssh session（ssh 回 255、stop 被判失敗），於是背景程序留了下來，下一個
  # replicate 的 start 因 registry 有活 pid 而 die。純 pid kill 則乾淨且安全。
  # children（例如迴圈裡的 sleep）另外用 -P 收，那隻旗標只會打到指定 parent 的子代。
  # **順序是 parent 先、children 後**：反過來的話，殺掉前景的 sleep 等於「放行」，
  # 父 shell 會立刻執行腳本的下一行。真機實測 guard（sleep N; flush; 寫標記）就是
  # 這樣被誤觸發的。先送 TERM 給父 shell，非互動 bash 會在前景子程序結束後才處理
  # 該訊號並直接終止，不會再往下走一行。
  sudo kill -TERM "\$_pid" 2>/dev/null || true
  sudo pkill -TERM -P "\$_pid" 2>/dev/null || true
  _i=0
  while [ \$_i -lt 20 ] && sudo kill -0 "\$_pid" 2>/dev/null; do sleep 0.5; _i=\$((_i+1)); done
  sudo pkill -KILL -P "\$_pid" 2>/dev/null || true
  sudo kill -KILL "\$_pid" 2>/dev/null || true
  sudo rm -f "\$_p"
fi
echo "remote_bg_stop: ${runid} stopped"
REMOTE
)"
  node_ssh "$name" "$remote"
}

# remote_bg_list <name>：印出 `<run-id> <pid> alive|dead`，一行一筆。
remote_bg_list() {
  [ $# -eq 1 ] || die "用法：remote_bg_list <node>"
  local name="$1" remote dir
  dir="$BG_REGISTRY_DIR"
  _require_inventory
  remote="$(cat <<REMOTE
set -u
for _f in ${dir}/*.pid; do
  [ -e "\$_f" ] || continue
  _id=\$(basename "\$_f" .pid)
  _pid=\$(cat "\$_f")
  if sudo kill -0 "\$_pid" 2>/dev/null; then _s=alive; else _s=dead; fi
  echo "\$_id \$_pid \$_s"
done
REMOTE
)"
  node_ssh "$name" "$remote"
}

# --- bundle ------------------------------------------------------------------

# new_bundle <cell-id> <rN>：穩定 key = results/<cell>/<rN>，attempt 在 attempts/<ts>。
# stdout = attempt 目錄（機器行）。
new_bundle() {
  [ $# -eq 2 ] || die "用法：new_bundle <cell-id> <rN>"
  local cell="$1" rep="$2" base ts dir n
  base="$RESULTS_DIR/$cell/$rep"
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  dir="$base/attempts/$ts"
  n=1
  while [ -e "$dir" ]; do
    n=$((n + 1))
    dir="$base/attempts/${ts}-${n}"
  done
  mkdir -p "$dir" || die "無法建立 bundle：${dir}"
  printf '%s\n' "$dir"
}

bundle_is_done() { # <bundle-dir>
  [ $# -eq 1 ] || die "用法：bundle_is_done <bundle-dir>"
  [ -f "$1/DONE" ]
}

# bundle_finalize <bundle-dir> <kind>：per-kind required-files schema 由 verdict.py 提供，
# 全過才原子寫 DONE（attempt 級 + replicate 級）。
bundle_finalize() {
  [ $# -eq 2 ] || die "用法：bundle_finalize <bundle-dir> <kind>"
  local dir="$1" kind="$2" req f missing rdir tmpf
  [ -d "$dir" ] || die "bundle 不存在：${dir}"
  [ -f "$VERDICT_PY" ] || die "找不到 verdict.py（${VERDICT_PY}）——bundle_finalize 需要它提供 schema"
  req="$(python3 "$VERDICT_PY" schemas "$kind")" || die "取不到 ${kind} 的 required-files schema"
  [ -n "$req" ] || die "${kind} 的 required-files schema 是空的"

  missing=0
  while IFS= read -r f; do
    case "$f" in ''|'#'*) continue ;; esac
    if [ ! -s "$dir/$f" ]; then
      log "bundle_finalize：缺件 ${f}"
      missing=$((missing + 1))
    fi
  done <<< "$req"
  if [ "$missing" -gt 0 ]; then
    log "bundle_finalize：${kind} schema 未滿足（缺 ${missing} 件），不寫 DONE"
    return 1
  fi

  tmpf="$dir/.DONE.$$"
  printf 'kind=%s\nfinalized_at=%s\n' "$kind" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmpf"
  mv -f "$tmpf" "$dir/DONE" || die "無法寫入 DONE：${dir}"
  # replicate 級 DONE：manifest next / audit 只要掃 results/<cell>/<rN>/DONE 就知道齊備
  case "$dir" in
    */attempts/*)
      rdir="${dir%/attempts/*}"
      tmpf="$rdir/.DONE.$$"
      printf '%s\n' "${dir##*/}" > "$tmpf"
      mv -f "$tmpf" "$rdir/DONE" || die "無法寫入 replicate DONE：${rdir}"
      ;;
  esac
  log "bundle_finalize：${dir} 已封存（kind=${kind}）"
  return 0
}
