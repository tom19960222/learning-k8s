#!/usr/bin/env bash
# 單一 commit gate（plan Global Constraints）：run-tests → shellcheck → make validate。
# 每次 commit 前必跑，三段全綠才算過。
set -u

here="$(cd "$(dirname "$0")" && pwd)"
exp_root="$(cd "$here/.." && pwd)"

# make validate 需要 next-site/node_modules，而 git worktree 內沒有（只有主 checkout 有），
# 所以第三段固定在主 checkout 跑；路徑寫死，不隨 worktree 位置變動。
MAIN_CHECKOUT="${MAIN_CHECKOUT:-/Users/ikaros/Documents/code/learning-k8s}"

step() { printf '\n=== gate: %s ===\n' "$*" >&2; }
die() { printf 'gate: FAIL — %s\n' "$*" >&2; exit 1; }

# --- 1. 單元測試 --------------------------------------------------------------
step "run-tests"
bash "$here/run-tests.sh" >&2 || die "run-tests.sh 未全綠"

# --- 2. shellcheck（含 info 級）------------------------------------------------
step "shellcheck"
command -v shellcheck >/dev/null 2>&1 || die "shellcheck 未安裝"
files=()
# 用 find 列「實際存在」的 .sh，避免未展開的 glob 被當成檔名傳進 shellcheck。
while IFS= read -r f; do
  files+=("$f")
done < <(find "$exp_root" -type f -name '*.sh' -not -path '*/results/*' | sort)
# fake ssh 沒有 .sh 副檔名（必須叫 ssh 才能被 PATH 覆蓋），但一樣是 bash 腳本。
[ -f "$here/fakes/ssh" ] && files+=("$here/fakes/ssh")
if [ "${#files[@]}" -gt 0 ]; then
  # -x：跟進 source 的檔案（各檔已標 source-path=SCRIPTDIR）；-S style：含 info/style 級。
  shellcheck -x -S style "${files[@]+"${files[@]}"}" >&2 || die "shellcheck 有發現"
else
  die "找不到任何 shell 腳本"
fi

# --- 3. 網站 validate（主 checkout）--------------------------------------------
step "make validate（${MAIN_CHECKOUT}）"
[ -d "$MAIN_CHECKOUT/next-site/node_modules" ] || die "主 checkout 缺 node_modules：${MAIN_CHECKOUT}"
make -C "$MAIN_CHECKOUT" validate >&2 || die "make validate 未過"

printf 'gate: PASS\n'
