#!/usr/bin/env bash
# Task 4 — lib/manifest.py：矩陣產生（63 cells / 147 executions）、Latin 平衡、
# targets 綁 group、四型 amendments 的原子寫入 / merge / resume / audit 視圖、
# cap-update 只影響未執行、pilot 選取（含 node-isolation 退化）。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
MANIFEST_PY="$root/lib/manifest.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-man.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { # eq <got> <want> <desc>
  [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"
  ok
}

mp() { python3 "$MANIFEST_PY" "$@"; }

# pyq <json-file> <expr>：expr 內以 d 存取解析後的 JSON
pyq() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.stdout.write(str(eval(sys.argv[2])))
PY
}

# pyl <jsonl-file> <expr>：expr 內以 d 存取 list of records
pyl() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = [json.loads(x) for x in open(sys.argv[1]) if x.strip()]
sys.stdout.write(str(eval(sys.argv[2])))
PY
}

# 建立 replicate 級 DONE（Task 2 的 bundle_finalize 語意：results/<cell>/<rN>/DONE）
mark_done() { # mark_done <results-dir> <cell-id> <rN>
  mkdir -p "$1/$2/$3"
  printf 'done\n' > "$1/$2/$3/DONE"
}

# =============================================================================
# 1. generate + --assert
# =============================================================================
R1="$tmp/r1"
out="$(mp generate --inventory "$fixture" --results "$R1" --assert)"
eq "$out" "manifest: 63 cells 147 executions" "generate 機器行"
eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "generate stdout 只有一行"
[ -f "$R1/manifest.json" ] || fail "manifest.json 未產生"
ok

M1="$R1/manifest.json"
eq "$(pyq "$M1" 'len(d["cells"])')" "63" "63 cells"
eq "$(pyq "$M1" 'sum(c["base_n"] for c in d["cells"])')" "147" "147 executions"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["base_n"]==3)')" "24" "24 cells × n=3"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["base_n"]==2)')" "36" "36 cells × n=2"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["base_n"]==1)')" "3" "3 cells × n=1"
eq "$(pyq "$M1" 'len(set(c["cell_id"] for c in d["cells"]))')" "63" "cell_id 唯一"

# spec §5 區塊組成
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["kind"]=="steady")')" "24" "穩態 24 cells"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["fault"] in ("flapping","osd-down","rack-isolation"))')" \
   "27" "故障主軸 27 cells"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["fault"]=="node-isolation")')" "3" "node loss 3 cells"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["fault"]=="seq-contention")')" "6" "seq-contention 6 cells"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["kind"]=="chaos")')" "3" "chaos 3 cells"
eq "$(pyq "$M1" 'sorted(set(c["pressure"] for c in d["cells"] if c["kind"]=="steady"))')" \
   "['extreme', 'high', 'low', 'mid']" "穩態 4 壓力等級"
eq "$(pyq "$M1" 'sorted(set(c["pressure"] for c in d["cells"] if c["fault"]=="osd-down" and c["shape"]=="4k"))')" \
   "['extreme', 'low', 'mid']" "故障主軸 3 壓力等級（無 high）"
eq "$(pyq "$M1" 'sorted(set(c["pressure"] for c in d["cells"] if c["fault"]=="seq-contention"))')" \
   "['extreme', 'mid']" "seq-contention 中/極端壓"
eq "$(pyq "$M1" 'sorted(set(c["pressure"] for c in d["cells"] if c["fault"]=="node-isolation"))')" \
   "['mid']" "node-isolation 只有中壓"

# 欄位齊備
eq "$(pyq "$M1" 'sorted(set(k for c in d["cells"] for k in ("cell_id","group_id","profile","shape","pressure","fault","fault_params","base_n","targets") if k not in c))')" \
   "[]" "每個 cell 都有 plan 指定的九個欄位"

# =============================================================================
# 2. group = 排除 profile 的 treatment 組合；cell_id = <group_id>+<profile>
# =============================================================================
eq "$(pyq "$M1" 'len(set(c["group_id"] for c in d["cells"]))')" "21" "21 個 group（63/3）"
eq "$(pyq "$M1" 'sorted(set(sum(1 for c in d["cells"] if c["group_id"]==g) for g in set(x["group_id"] for x in d["cells"])))')" \
   "[3]" "每個 group 恰 3 個 profile"
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] if c["cell_id"]!=c["group_id"]+"+"+c["profile"])')" \
   "0" "cell_id = <group_id>+<profile>"
# group 內除 profile 外的 treatment 必須一致
eq "$(pyq "$M1" 'len(set((c["group_id"],c["shape"],c["pressure"],c["fault"],c["base_n"]) for c in d["cells"]))')" \
   "21" "group 唯一決定 shape/pressure/fault/base_n"

# =============================================================================
# 3. fault_params 各型完整
# =============================================================================
eq "$(pyq "$M1" '[sorted(c["fault_params"].items()) for c in d["cells"] if c["fault"]=="flapping"][0][:3]')" \
   "[('cycles', 10), ('guard_margin_secs', 600), ('measurement_cap', 2700)]" "flapping cycles/cap"
eq "$(pyq "$M1" '[c["fault_params"]["no_out"] for c in d["cells"] if c["fault"]=="flapping"][0]')" \
   "True" "flapping no_out"
eq "$(pyq "$M1" '[c["fault_params"]["per_cycle_gate"] for c in d["cells"] if c["fault"]=="flapping"][0]')" \
   "pgs_active_for_osd" "flapping per_cycle_gate"
eq "$(pyq "$M1" '[c["fault_params"]["manual_out"] for c in d["cells"] if c["fault"]=="osd-down"][0]')" \
   "True" "osd-down manual_out"
eq "$(pyq "$M1" '[c["fault_params"]["nodes"] for c in d["cells"] if c["fault"]=="node-isolation"][0]')" \
   "1" "node-isolation nodes=1"
eq "$(pyq "$M1" '[c["fault_params"]["manual_out"] for c in d["cells"] if c["fault"]=="node-isolation"][0]')" \
   "True" "node-isolation manual_out"
eq "$(pyq "$M1" '[c["fault_params"]["nodes"] for c in d["cells"] if c["fault"]=="rack-isolation"][0]')" \
   "2" "rack-isolation nodes=2"
eq "$(pyq "$M1" '[c["fault_params"]["fault"] for c in d["cells"] if c["fault"]=="seq-contention"][0]')" \
   "osd-down" "seq-contention 底層 fault=osd-down"
eq "$(pyq "$M1" '[c["fault_params"]["shape"] for c in d["cells"] if c["fault"]=="seq-contention"][0]')" \
   "seq" "seq-contention fault_params.shape=seq"
eq "$(pyq "$M1" 'sorted(set(c["shape"] for c in d["cells"] if c["fault"]=="seq-contention"))')" \
   "['seq']" "seq-contention cell shape=seq"
eq "$(pyq "$M1" 'sorted(set(c["fault_params"].get("measurement_cap") for c in d["cells"] if c["kind"]=="fault"))')" \
   "[2700]" "全故障 cell 預設 cap=2700"
eq "$(pyq "$M1" 'sorted(set(c["fault_params"].get("measurement_cap") for c in d["cells"] if c["kind"]=="steady"))')" \
   "[None]" "穩態無 measurement_cap"
# chaos：無 cap、guard = duration + 600（§Cap policy 不變條件）
eq "$(pyq "$M1" '[c["fault_params"].get("measurement_cap") for c in d["cells"] if c["kind"]=="chaos"][0]')" \
   "None" "chaos 無 measurement_cap"
eq "$(pyq "$M1" '[c["fault_params"]["seed"] for c in d["cells"] if c["kind"]=="chaos"][0]')" \
   "4242" "chaos seed=4242"
eq "$(pyq "$M1" '[c["fault_params"]["guard_deadline_secs"]-c["fault_params"]["duration"] for c in d["cells"] if c["kind"]=="chaos"][0]')" \
   "600" "chaos guard = duration + 600"

# =============================================================================
# 4. targets 綁 group（v4.2/F5-6）
# =============================================================================
eq "$(pyq "$M1" 'max(len(set(json.dumps(c["targets"],sort_keys=True) for c in d["cells"] if c["group_id"]==g)) for g in set(x["group_id"] for x in d["cells"]))')" \
   "1" "同 group 內全部 cells 共用同一 target"
eq "$(pyq "$M1" 'sorted(set(len(c["targets"]) for c in d["cells"] if c["kind"]=="steady"))')" \
   "[0]" "穩態無 target"
eq "$(pyq "$M1" 'sorted(set(len(c["targets"]) for c in d["cells"] if c["fault"] in ("flapping","osd-down","node-isolation","seq-contention")))')" \
   "[1]" "單機故障 target 恰 1 台"
eq "$(pyq "$M1" 'sorted(set(len(c["targets"]) for c in d["cells"] if c["fault"]=="rack-isolation"))')" \
   "[2]" "rack-isolation target 2 台"
eq "$(pyq "$M1" 'sorted(set(len(set(t["rack"] for t in c["targets"])) for c in d["cells"] if c["fault"]=="rack-isolation"))')" \
   "[1]" "rack-isolation 兩台同 rack"
# target 必須來自 inventory，且輪替發生在 group 之間
eq "$(pyq "$M1" 'sum(1 for c in d["cells"] for t in c["targets"] if not t["node"].startswith("mclock-osd-"))')" \
   "0" "target node 來自 inventory"
eq "$(pyq "$M1" 'len(set(json.dumps(c["targets"],sort_keys=True) for c in d["cells"] if c["fault"]=="osd-down" and c["shape"]=="4k")) > 1')" \
   "True" "同 fault 的不同 group 之間會輪替 target"

# =============================================================================
# 5. Latin square：全 schedule position balance
# =============================================================================
S1="$tmp/schedule1.jsonl"
mp schedule --results "$R1" > "$S1"
eq "$(pyl "$S1" 'len(d)')" "147" "schedule 展開 147 executions"
eq "$(pyl "$S1" 'sorted(set(e["latin_position"] for e in d))')" "[0, 1, 2]" "latin_position ∈ {0,1,2}"
# 每個 position 的 execution 數必須相等（147/3）
eq "$(pyl "$S1" 'sorted(sum(1 for e in d if e["latin_position"]==p) for p in (0,1,2))')" \
   "[49, 49, 49]" "三個 position 各 49 executions"
eq "$(pyl "$S1" 'sorted(sum(1 for e in d if e["profile"]==p) for p in set(x["profile"] for x in d))')" \
   "[49, 49, 49]" "三個 profile 各 49 executions"
# (profile, position) 的交叉平衡：49 個 group-replicate 三元組無法被 3 整除，
# 完美平衡不可能；容忍 ±1（16/17），超出即 Latin 輪替壞掉。
eq "$(pyl "$S1" 'sorted(set(sum(1 for e in d if e["profile"]==pr and e["latin_position"]==po) for pr in set(x["profile"] for x in d) for po in (0,1,2)))')" \
   "[16, 17]" "每個 (profile, position) 落在 16–17 之間"
eq "$(pyl "$S1" 'len(set((e["cell_id"],e["replicate"]) for e in d))')" "147" "execution key 唯一"
# 同一 group-replicate 內三個 profile 佔滿三個 position（Latin square 定義）
eq "$(pyl "$S1" 'max(len(set(e["latin_position"] for e in d if (e["group_id"],e["replicate_n"])==k)) for k in set((x["group_id"],x["replicate_n"]) for x in d))')" \
   "3" "同 group 同 replicate 的三 profile 佔滿三 position"
eq "$(pyl "$S1" 'min(len(set(e["latin_position"] for e in d if (e["group_id"],e["replicate_n"])==k)) for k in set((x["group_id"],x["replicate_n"]) for x in d))')" \
   "3" "無重複 position"

# 決定性：同 inventory 重跑 → manifest_hash 相同
R2="$tmp/r2"
mp generate --inventory "$fixture" --results "$R2" --assert >/dev/null
eq "$(pyq "$R2/manifest.json" 'd["manifest_hash"]')" "$(pyq "$M1" 'd["manifest_hash"]')" \
   "manifest_hash 對同一 inventory 決定性"

# --assert 失敗路徑
python3 - "$M1" "$tmp/bad-manifest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["cells"] = d["cells"][:-1]
json.dump(d, open(sys.argv[2], "w"))
PY
mkdir -p "$tmp/rbad"
cp "$tmp/bad-manifest.json" "$tmp/rbad/manifest.json"
if mp schedule --results "$tmp/rbad" --assert >/dev/null 2>&1; then
  fail "--assert 對 62 cells 應該 exit 1"
fi
ok

# =============================================================================
# 6. next：DONE 消費 + kind 過濾
# =============================================================================
e1="$(mp next --results "$R1")"
printf '%s\n' "$e1" > "$tmp/e1.json"
eq "$(printf '%s\n' "$e1" | wc -l | tr -d ' ')" "1" "next 只輸出一行 JSON"
eq "$(pyq "$tmp/e1.json" 'd["replicate"]')" "r1" "第一個 execution 是 r1"
eq "$(pyq "$tmp/e1.json" 'd["kind"]')" "steady" "排程從穩態開始"
eq "$(pyq "$tmp/e1.json" 'd["status"]')" "pending" "next 只回 pending"
eq "$(pyq "$tmp/e1.json" 'd["manifest_hash"]')" "$(pyq "$M1" 'd["manifest_hash"]')" \
   "execution 帶 manifest_hash（bundle 交叉核對用）"
first_cell="$(pyq "$tmp/e1.json" 'd["cell_id"]')"
mark_done "$R1" "$first_cell" r1
e2="$(mp next --results "$R1")"
printf '%s\n' "$e2" > "$tmp/e2.json"
if [ "$(pyq "$tmp/e2.json" 'd["cell_id"]+"/"+d["replicate"]')" = "${first_cell}/r1" ]; then
  fail "next 未消費已 DONE 的 execution"
fi
ok
# replicate 級 DONE 為準（不遞迴 attempts/）
mkdir -p "$R1/$(pyq "$tmp/e2.json" 'd["cell_id"]')/r1/attempts/20260101T000000Z"
printf 'x\n' > "$R1/$(pyq "$tmp/e2.json" 'd["cell_id"]')/r1/attempts/20260101T000000Z/DONE"
eq "$(mp next --results "$R1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cell_id"])')" \
   "$(pyq "$tmp/e2.json" 'd["cell_id"]')" "attempt 級 DONE 不算完成"

ef="$(mp next --results "$R1" --kind fault)"
printf '%s\n' "$ef" > "$tmp/ef.json"
eq "$(pyq "$tmp/ef.json" 'd["kind"]')" "fault" "--kind fault 只回故障 execution"
ec="$(mp next --results "$R1" --kind chaos)"
printf '%s\n' "$ec" > "$tmp/ec.json"
eq "$(pyq "$tmp/ec.json" 'd["kind"]')" "chaos" "--kind chaos"
eq "$(pyq "$tmp/ec.json" 'd["measurement_cap"]')" "None" "chaos execution 無 cap"

# 佇列耗盡 → exit 3
R3="$tmp/r3"
mp generate --inventory "$fixture" --results "$R3" >/dev/null
python3 - "$R3/manifest.json" "$R3" <<'PY'
import json, os, sys
man = json.load(open(sys.argv[1]))
root = sys.argv[2]
for c in man["cells"]:
    for n in range(1, c["base_n"] + 1):
        p = os.path.join(root, c["cell_id"], "r%d" % n)
        os.makedirs(p, exist_ok=True)
        open(os.path.join(p, "DONE"), "w").write("done\n")
PY
mp next --results "$R3" >/dev/null 2>&1 && fail "佇列耗盡時 next 應非 0 結束"
rc=$?
eq "$rc" "3" "佇列耗盡 exit 3"

# =============================================================================
# 7. pilot 選取（每故障型最慢組合；node-isolation 退化為中壓）
# =============================================================================
P="$tmp/pilots.jsonl"
mp pilots --results "$R1" > "$P"
eq "$(pyl "$P" 'len(d)')" "5" "五個故障型各一個 pilot"
eq "$(pyl "$P" 'sorted(set(e["fault"] for e in d))')" \
   "['flapping', 'node-isolation', 'osd-down', 'rack-isolation', 'seq-contention']" "pilot 覆蓋五故障型"
eq "$(pyl "$P" 'sorted(set(e["profile"] for e in d))')" "['high_client_ops']" "pilot 一律 high_client_ops"
eq "$(pyl "$P" 'sorted(set(e["replicate"] for e in d))')" "['r1']" "pilot 是 r1"
eq "$(pyl "$P" 'sorted(set(e["pressure"] for e in d if e["fault"]!="node-isolation"))')" \
   "['extreme']" "非 node-isolation 的 pilot 用極端壓"
eq "$(pyl "$P" '[e["pressure"] for e in d if e["fault"]=="node-isolation"][0]')" \
   "mid" "node-isolation pilot 退化為中壓（v4.2.1）"
eq "$(pyl "$P" 'sorted(set(e["kind"] for e in d))')" "['fault']" "chaos 不是故障型 pilot（無 cap）"
ep="$(mp next --results "$R1" --pilot)"
printf '%s\n' "$ep" > "$tmp/ep.json"
eq "$(pyq "$tmp/ep.json" 'd["profile"]')" "high_client_ops" "next --pilot 只回 pilot execution"

# =============================================================================
# 8. amend：四型 + 原子寫入 + resume
# =============================================================================
R4="$tmp/r4"
mp generate --inventory "$fixture" --results "$R4" --assert >/dev/null
M4="$R4/manifest.json"
J="$R4/schedule-amendments.json"
cell_steady="$(pyq "$M4" '[c["cell_id"] for c in d["cells"] if c["kind"]=="steady"][0]')"
cell_osd="$(pyq "$M4" '[c["cell_id"] for c in d["cells"] if c["fault"]=="osd-down" and c["profile"]=="balanced"][0]')"
cell_flap="$(pyq "$M4" '[c["cell_id"] for c in d["cells"] if c["fault"]=="flapping" and c["profile"]=="balanced"][0]')"

out="$(mp amend --results "$R4" --type extra-replicates --key "$cell_steady" --value 2 --source cov-upgrade)"
eq "$out" "amend: extra-replicates ${cell_steady} seq=1" "amend 機器行"
[ -f "$J" ] || fail "amendments journal 未產生"
ok
eq "$(pyl "$J" 'len(d)')" "1" "journal 一筆"
eq "$(pyl "$J" 'sorted(d[0].keys())')" \
   "['key', 'schema_version', 'seq', 'source', 'ts', 'type', 'value']" "versioned schema 欄位"
eq "$(pyl "$J" 'd[0]["schema_version"]')" "1" "schema_version"

mp amend --results "$R4" --type cap-update --key osd-down --value 5400 --source pilot-estimate >/dev/null
mp amend --results "$R4" --type rescue-replicate --key "$cell_flap" --value '{"cap": 5400}' --source double-censored >/dev/null
mp amend --results "$R4" --type needs-human --key "${cell_osd}/r2" --value "taint budget exhausted" --source watchdog >/dev/null
eq "$(pyl "$J" 'len(d)')" "4" "四型各一筆"
eq "$(pyl "$J" '[e["seq"] for e in d]')" "[1, 2, 3, 4]" "seq 單調遞增"
eq "$(pyl "$J" 'sorted(e["type"] for e in d)')" \
   "['cap-update', 'extra-replicates', 'needs-human', 'rescue-replicate']" "四型窮舉"
# 原子寫入：不得留 tmp 檔
eq "$(find "$R4" -maxdepth 1 -name '.amend.*' | wc -l | tr -d ' ')" "0" "amend 不留 tmp 檔"
eq "$(tail -c 1 "$J" | od -An -c | tr -d ' \n')" '\n' "journal 以換行收尾（append-only 安全）"

# 未知 type / 未知 key 一律拒絕
mp amend --results "$R4" --type bogus --key "$cell_steady" --value 1 >/dev/null 2>&1 \
  && fail "未知 amendment type 應失敗"
ok
mp amend --results "$R4" --type extra-replicates --key "no-such-cell+balanced" --value 1 >/dev/null 2>&1 \
  && fail "未知 cell_id 應失敗"
ok
mp amend --results "$R4" --type cap-update --key not-a-fault --value 1 >/dev/null 2>&1 \
  && fail "未知 fault type 應失敗"
ok
eq "$(pyl "$J" 'len(d)')" "4" "被拒的 amend 不得寫入 journal"

# =============================================================================
# 9. merge 視圖：extra-replicates / rescue-replicate 展開
# =============================================================================
V="$tmp/view4.json"
mp view --results "$R4" > "$V"
eq "$(pyq "$V" 'sum(1 for e in d["executions"] if e["cell_id"]=="'"$cell_steady"'")')" \
   "5" "extra-replicates 2 → 該 cell 共 5 executions"
eq "$(pyq "$V" 'sorted(e["replicate"] for e in d["executions"] if e["cell_id"]=="'"$cell_steady"'")')" \
   "['r1', 'r2', 'r3', 'r4', 'r5']" "加跑 replicate 接續編號"
eq "$(pyq "$V" 'sorted(set(e["origin"] for e in d["executions"] if e["cell_id"]=="'"$cell_steady"'"))')" \
   "['base', 'extra-replicates:1']" "加跑 execution 標記來源"
eq "$(pyq "$V" 'sum(1 for e in d["executions"] if e["cell_id"]=="'"$cell_flap"'")')" \
   "3" "rescue-replicate 加一個 replicate"
eq "$(pyq "$V" '[e["measurement_cap"] for e in d["executions"] if e["cell_id"]=="'"$cell_flap"'" and e["replicate"]=="r3"][0]')" \
   "5400" "rescue-replicate 帶自己的 cap"
eq "$(pyq "$V" '[e["measurement_cap_source"] for e in d["executions"] if e["cell_id"]=="'"$cell_flap"'" and e["replicate"]=="r3"][0]')" \
   "rescue-replicate:3" "rescue cap 來源標記"
eq "$(pyq "$V" 'sorted(set(e["measurement_cap"] for e in d["executions"] if e["cell_id"]=="'"$cell_flap"'" and e["replicate"]!="r3"))')" \
   "[2700]" "rescue cap 不污染同 cell 其他 replicate"
eq "$(pyq "$V" 'd["counts"]["total_executions"]')" "150" "147 + 2 extra + 1 rescue"
eq "$(pyq "$V" 'd["counts"]["base_executions"]')" "147" "base 仍是 147"

# rescue-replicate 每 cell 以一次為限
mp amend --results "$R4" --type rescue-replicate --key "$cell_flap" --value '{"cap": 9000}' >/dev/null 2>&1 \
  && fail "同 cell 第二次 rescue-replicate 應被拒"
ok

# =============================================================================
# 10. cap-update 只影響尚未執行者
# =============================================================================
eq "$(pyq "$V" 'sorted(set(e["measurement_cap"] for e in d["executions"] if e["fault"]=="osd-down" and e["status"]=="pending"))')" \
   "[5400]" "cap-update 套用到未執行的 osd-down executions"
eq "$(pyq "$V" 'sorted(set(e["measurement_cap_source"] for e in d["executions"] if e["fault"]=="osd-down" and e["status"]=="pending"))')" \
   "['cap-update:2']" "cap 來源標記"
eq "$(pyq "$V" 'sorted(set(e["measurement_cap"] for e in d["executions"] if e["fault"]=="flapping" and e["status"]=="pending" and e["origin"]=="base"))')" \
   "[2700]" "cap-update 不影響其他 fault type"
eq "$(pyq "$V" 'sorted(set(e["measurement_cap"] for e in d["executions"] if e["fault"]=="seq-contention"))')" \
   "[2700]" "seq-contention 是獨立 fault type，不吃 osd-down 的 cap-update"

# 已執行者：cap 由 bundle 為準，不被 journal 追溯改寫
cell_osd2="$(pyq "$M4" '[c["cell_id"] for c in d["cells"] if c["fault"]=="osd-down" and c["profile"]=="high_recovery_ops"][0]')"
mark_done "$R4" "$cell_osd2" r1
mp view --results "$R4" > "$V"
eq "$(pyq "$V" '[e["status"] for e in d["executions"] if e["cell_id"]=="'"$cell_osd2"'" and e["replicate"]=="r1"][0]')" \
   "done" "DONE 反映在 view"
eq "$(pyq "$V" '[e["measurement_cap_source"] for e in d["executions"] if e["cell_id"]=="'"$cell_osd2"'" and e["replicate"]=="r1"][0]')" \
   "bundle" "已執行者 cap 以 bundle 為準"
eq "$(pyq "$V" '[e["measurement_cap"] for e in d["executions"] if e["cell_id"]=="'"$cell_osd2"'" and e["replicate"]=="r1"][0]')" \
   "None" "已執行者不被 cap-update 追溯改寫"
eq "$(pyq "$V" '[e["measurement_cap"] for e in d["executions"] if e["cell_id"]=="'"$cell_osd2"'" and e["replicate"]=="r2"][0]')" \
   "5400" "同 cell 未執行者吃新 cap"

# =============================================================================
# 11. needs-human：佇列跳過 + audit 呈報
# =============================================================================
eq "$(pyq "$V" '[e["status"] for e in d["executions"] if e["cell_id"]=="'"$cell_osd"'" and e["replicate"]=="r2"][0]')" \
   "needs-human" "needs-human replicate 標記"
eq "$(pyq "$V" '[e["status"] for e in d["executions"] if e["cell_id"]=="'"$cell_osd"'" and e["replicate"]=="r1"][0]')" \
   "pending" "只跳過指定 replicate，不影響同 cell 其他 replicate"
eq "$(pyq "$V" 'len(d["needs_human"])')" "1" "audit 視圖列出 needs-human"
eq "$(pyq "$V" 'd["needs_human"][0]["reason"]')" "taint budget exhausted" "needs-human 原因"
# next 永遠不回 needs-human 的 execution
mark_done "$R4" "$cell_osd" r1
eq "$(mp next --results "$R4" --kind fault | python3 -c 'import json,sys;e=json.load(sys.stdin);print(e["cell_id"]+"/"+e["replicate"])' | grep -c "^${cell_osd}/r2\$" || true)" \
   "0" "next 跳過 needs-human"
# cell 級 needs-human：整個 cell 跳過
mp amend --results "$R4" --type needs-human --key "$cell_flap" --value "systemic" >/dev/null
mp view --results "$R4" > "$V"
eq "$(pyq "$V" 'sorted(set(e["status"] for e in d["executions"] if e["cell_id"]=="'"$cell_flap"'"))')" \
   "['needs-human']" "cell 級 needs-human 跳過整個 cell（含 rescue）"
eq "$(pyq "$V" 'len(d["needs_human"])')" "2" "needs-human 清單累積"

# =============================================================================
# 12. resume：journal 是唯一持久 SoT；壞行不得靜默略過
# =============================================================================
V2="$tmp/view4b.json"
mp view --results "$R4" > "$V2"
eq "$(pyq "$V2" 'json.dumps(d["executions"],sort_keys=True)')" \
   "$(pyq "$V" 'json.dumps(d["executions"],sort_keys=True)')" "重新讀 journal 得到同一視圖（resume）"
cp "$J" "$tmp/journal.bak"
printf 'not-json\n' >> "$J"
mp view --results "$R4" >/dev/null 2>&1 && fail "journal 壞行應該讓 view 失敗（不得靜默略過）"
ok
mp next --results "$R4" >/dev/null 2>&1 && fail "journal 壞行應該讓 next 失敗"
ok
cp "$tmp/journal.bak" "$J"
mp view --results "$R4" >/dev/null || fail "還原 journal 後 view 應恢復"
ok

# 沒有 journal 時（campaign 初期）一切正常
eq "$(pyq "$V" 'd["schema_version"]')" "1" "view schema_version"
V0="$tmp/view0.json"
mp view --results "$R2" > "$V0"
eq "$(pyq "$V0" 'd["counts"]["total_executions"]')" "147" "無 journal 時 = 147"
eq "$(pyq "$V0" 'len(d["amendments"])')" "0" "無 journal 時 amendments 為空"

printf 'test-manifest.sh: %d assertions passed\n' "$asserts"
