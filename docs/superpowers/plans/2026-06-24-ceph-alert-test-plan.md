# Ceph Prometheus Alert 測試計劃 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **使用者指定的 review 協定（覆蓋預設 two-stage review）：**
> - **建測試階段**：先由 **Experiment Tracker** 把 spec 的測試矩陣具體化成可執行 test-design；每輪規劃完，呼叫 **Test Results Analyzer** + **devils-advocate** review，修正後重跑，直到兩者皆無實質 finding。
> - **寫頁面階段**：由 **Technical Writer** 寫 MDX；每輪寫完交 **/reviewing-source-first-pages** review 並修正，直到無 finding。writer 只改文字，orchestrator 收尾跑一次 `make validate`（[memory: review-loop-no-parallel-validate]）。

**Goal:** 在開發環境逐條驗證 `prometheus-alert-design.mdx` 設計的整套 ceph alert（rules / recording rules / routing / silence），交付可由 AI agent 無人執行的 `experiments/ceph-alert-rules/` harness，並寫一頁 source-first MDX 測試計劃。

**Architecture:** 四層分層測試。Tier A 用 `promtool test rules` 對逐條規則做 deterministic 單元測試（expr/for/label/排除清單）；Tier B 用 `amtool config routes test` 測 routing；Tier C 用真 prometheus+alertmanager 做 live smoke（規則載入、route、silence）；Tier D 把只有真 ceph 能驗的宣稱做成原始碼 oracle 對照表。被測 rules 逐字抽自頁面。

**Tech Stack:** promtool 3.12.0、amtool/alertmanager（`brew install alertmanager`）、prometheus binary、python3（fake webhook sink + scenario 注入）、bash、docker（Tier C 備援）。

## Global Constraints

- 內容語言：zh-TW 台灣用語；技術名詞英文保留（`node`/`cluster`/`Pod`/`OSD`/`MON`/`alert`/`silence`/`label` 等不譯）。
- `rules/*.yml` 必須與 `prometheus-alert-design.mdx` 的 YAML **逐字一致**；不得改寫被測物。
- 測試靠 exit code + 結構化輸出判 PASS/FAIL，無 GUI、無互動（AI agent 可無人執行）。
- experiments/ 不在 Next.js 路由內（位於 `next-site/content` 之外），不受 `make validate` 的 MDX 檢查；但最終 MDX 頁要過 `make validate`。
- 揭露頁面 rule 本身 bug → 記 finding；只有修正明確正確才同步改頁並註明，judgment call 留給使用者。
- commit 一次性在最後做（使用者指定「全部做完以後 commit」）：`git commit --no-gpg-sign`；push 用 `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none'`。
- 被測規則/路由的真實來源：`next-site/content/ceph/features/prometheus-alert-design.mdx`。測試矩陣全文：`docs/superpowers/specs/2026-06-24-ceph-alert-test-plan-design.md` §4。

---

## Task 0: Harness 骨架 + 逐字抽 rules + 防漂移 guard

**Files:**
- Create: `experiments/ceph-alert-rules/README.md`（先放骨架，Task 7 補完）
- Create: `experiments/ceph-alert-rules/env.example.sh`
- Create: `experiments/ceph-alert-rules/rules/ceph-stability-first.yml`
- Create: `experiments/ceph-alert-rules/rules/ceph-scoped-availability.yml`
- Create: `experiments/ceph-alert-rules/rules/alertmanager-route.yml`
- Create: `experiments/ceph-alert-rules/lib/check-rules-match-page.sh`
- Create: `experiments/ceph-alert-rules/results/.gitkeep`

**Interfaces:**
- Produces: `rules/ceph-stability-first.yml`（groups: `ceph-stability-first`）、`rules/ceph-scoped-availability.yml`（groups: `ceph-scoped-availability`，含 2 recording rules）、`rules/alertmanager-route.yml`（route + receivers `pager-ceph`/`slack-ceph`）。後續所有 tier 引用這些路徑。

- [ ] **Step 1：抽 `ceph-stability-first.yml`**，內容逐字取自頁面（5 條 alert：CephClientBlocked/CephClientRisk/CephMonQuorumLost/CephExporterDown/CephLowPriorityNotice，含完整 expr/for/labels/annotations）。

- [ ] **Step 2：抽 `ceph-scoped-availability.yml`**，逐字取自頁面（2 recording rule + CephOSDHostDownScoped/CephOSDDaemonDownScoped/CephMonDownScoped）。

- [ ] **Step 3：抽 `alertmanager-route.yml`**，把頁面 `route:` 區塊補成完整 amtool 可吃的 config（加最小 `receivers:` 清單 `slack-ceph`/`pager-ceph`；route 內容逐字保留 4 條）。

- [ ] **Step 4：`promtool check rules` 驗語法**
Run: `promtool check rules experiments/ceph-alert-rules/rules/ceph-stability-first.yml experiments/ceph-alert-rules/rules/ceph-scoped-availability.yml`
Expected: `SUCCESS` 且列出全部 rule，exit 0。

- [ ] **Step 5：`amtool check-config` 驗 routing 語法**
Run: `amtool check-config experiments/ceph-alert-rules/rules/alertmanager-route.yml`
Expected: exit 0（`amtool` 安裝見 Task 4 Step 0；若尚未裝，先做 Task 4 Step 0）。

- [ ] **Step 6：寫 `lib/check-rules-match-page.sh`**——抽出頁面 ```yaml fenced block 與 `rules/*.yml` 正規化後比對關鍵行（至少比對每條 alert 的 `expr:` 與 `for:`），不符 exit 1。
Run: `bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh`
Expected: `rules match page` exit 0。

## Task 1: Tier A — `ceph-stability-first` 規則單元測試

**Files:**
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/health-error.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/client-blocked.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/client-risk.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/mon-quorum-lost.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/exporter-down.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/low-priority-notice.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/_health-status-rules.yml`（補 CephHealthError/CephHealthWarning 兩條預設規則，逐字取自頁面/ceph-mixin，供 health-error 測試載入）

**Interfaces:**
- Consumes: Task 0 的 `rules/ceph-stability-first.yml`。
- Produces: 6 個 promtool test 檔，覆蓋 spec §4.1–4.7。

- [ ] **Step 1：寫 `client-risk.test.yml`（最關鍵，先寫）**——覆蓋 spec §4.4：正常觸發 1 例、10 條排除逐一不觸發、維護綜合情境（PG_DEGRADED+OSDMAP_FLAGS+OSD_HOST_DOWN+MON_DOWN 同時 active 5m 不 fire）、混合。範例骨架：

```yaml
rule_files:
  - ../../rules/ceph-stability-first.yml
evaluation_interval: 1m
tests:
  # 正常：非排除 name 觸發
  - interval: 1m
    input_series:
      - series: 'ceph_health_detail{name="POOL_NEAR_FULL", severity="HEALTH_WARN"}'
        values: '1x10'
    alert_rule_test:
      - eval_time: 5m
        alertname: CephClientRisk
        exp_alerts:
          - exp_labels: {severity: critical, source: ceph_stability, name: POOL_NEAR_FULL}
            exp_annotations: {summary: "Ceph client-risk check active: POOL_NEAR_FULL"}
  # 維護綜合情境：四個排除 name 同時 active，5m 後仍不得 fire
  - interval: 1m
    input_series:
      - series: 'ceph_health_detail{name="PG_DEGRADED", severity="HEALTH_WARN"}'
        values: '1x10'
      - series: 'ceph_health_detail{name="OSDMAP_FLAGS", severity="HEALTH_WARN"}'
        values: '1x10'
      - series: 'ceph_health_detail{name="OSD_HOST_DOWN", severity="HEALTH_WARN"}'
        values: '1x10'
      - series: 'ceph_health_detail{name="MON_DOWN", severity="HEALTH_WARN"}'
        values: '1x10'
    alert_rule_test:
      - eval_time: 6m
        alertname: CephClientRisk
        exp_alerts: []
```

- [ ] **Step 2：跑 client-risk 測試**
Run: `promtool test rules experiments/ceph-alert-rules/tests/tierA-promtool/client-risk.test.yml`
Expected: `SUCCESS`，exit 0。若 FAIL：先確認是測試 exp_labels 寫錯（如 metric `severity` 被 rule label 覆蓋的細節）還是規則真有問題；前者改測試，後者記 finding。

- [ ] **Step 3：寫其餘 5 個測試檔**（health-error/client-blocked/mon-quorum-lost/exporter-down/low-priority-notice），逐一覆蓋 spec §4.1/4.2/4.3/4.5/4.6/4.7。low-priority-notice 內含「跨規則一致性」測試（同一 input 同時斷言 CephLowPriorityNotice fire + CephClientRisk 不 fire——需在該 test 檔 `rule_files` 載入整組 stability-first）。mon-quorum-lost 涵蓋 `==1` filter 與掉 1/掉 2 邊界。exporter-down 涵蓋 `job` label 選擇與 for-flap。health-error 用 `_health-status-rules.yml`，涵蓋 for 邊界與 flap reset。

- [ ] **Step 4：跑整個 tierA-promtool 目錄**
Run: `promtool test rules experiments/ceph-alert-rules/tests/tierA-promtool/*.test.yml`
Expected: 全 `SUCCESS`，exit 0。把輸出存 `results/tierA-stability.txt`。

## Task 2: Tier A — `ceph-scoped-availability` 規則單元測試

**Files:**
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/recording-rules.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/osd-host-down-scoped.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/osd-daemon-down-scoped.test.yml`
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/mon-down-scoped.test.yml`

**Interfaces:**
- Consumes: Task 0 的 `rules/ceph-scoped-availability.yml`。
- Produces: 4 個 promtool test 檔，覆蓋 spec §4.8–4.12。

- [ ] **Step 1：寫 `osd-daemon-down-scoped.test.yml`（去重邏輯，先寫）**——覆蓋 spec §4.11：單顆 down→只 daemon alert、整台 down→只 host alert（daemon 被 `unless` 壓掉）、混合、值為 0 仍 fire。骨架：

```yaml
rule_files:
  - ../../rules/ceph-scoped-availability.yml
evaluation_interval: 1m
tests:
  # 整台 host-a 全 down：只 CephOSDHostDownScoped，CephOSDDaemonDownScoped 對 host-a 任何 OSD 不 fire
  - interval: 1m
    input_series:
      - series: 'ceph_osd_up{ceph_daemon="osd.0"}'
        values: '0x10'
      - series: 'ceph_osd_up{ceph_daemon="osd.1"}'
        values: '0x10'
      - series: 'ceph_osd_metadata{ceph_daemon="osd.0", hostname="osd-host-a"}'
        values: '1x10'
      - series: 'ceph_osd_metadata{ceph_daemon="osd.1", hostname="osd-host-a"}'
        values: '1x10'
    alert_rule_test:
      - eval_time: 6m
        alertname: CephOSDDaemonDownScoped
        exp_alerts: []
      - eval_time: 6m
        alertname: CephOSDHostDownScoped
        exp_alerts:
          - exp_labels: {severity: critical, source: ceph_scoped, hostname: osd-host-a}
            exp_annotations:
              summary: "Ceph OSD host down: osd-host-a"
              runbook: "ceph osd tree; ceph health detail; check host power/network/systemd"
```

- [ ] **Step 2：跑 osd-daemon-down-scoped**
Run: `promtool test rules experiments/ceph-alert-rules/tests/tierA-promtool/osd-daemon-down-scoped.test.yml`
Expected: `SUCCESS`，exit 0。

- [ ] **Step 3：寫其餘 3 檔**：recording-rules（用 `promql_expr_test` 直接斷言 `ceph:osd_up:with_hostname` 與 `ceph:osd_host_down:scoped` 在各 osd-up 組合下的輸出值與 label；含缺 metadata→series 消失）、osd-host-down-scoped（整台/部分/多 host）、mon-down-scoped（觸發/正常/缺 metadata 不 fire/30s 短 for）。

- [ ] **Step 4：跑整組並存結果**
Run: `promtool test rules experiments/ceph-alert-rules/tests/tierA-promtool/*scoped*.test.yml experiments/ceph-alert-rules/tests/tierA-promtool/recording-rules.test.yml`
Expected: 全 `SUCCESS`。輸出存 `results/tierA-scoped.txt`。

## Task 3: Tier A — 邊界：3-mon 寫死 vs 動態 majority

**Files:**
- Create: `experiments/ceph-alert-rules/rules/ceph-mon-quorum-dynamic.yml`（頁面文末提供的動態式 alert）
- Create: `experiments/ceph-alert-rules/tests/tierA-promtool/mon-quorum-dynamic.test.yml`

**Interfaces:**
- Consumes: 頁面 §邊界的 `count(...) < (floor(count(ceph_mon_metadata)/2)+1)`。
- Produces: 證明 n=3 時動態式與寫死 `<2` 等價、n=5 時門檻=3。

- [ ] **Step 1：寫 `ceph-mon-quorum-dynamic.yml`**：一條 `CephMonQuorumLostDynamic`，expr 用頁面動態式，for 1m，severity critical。

- [ ] **Step 2：寫 `mon-quorum-dynamic.test.yml`**：3-mon 掉 1（不 fire）/ 掉 2（fire）；5-mon 掉 2（count=3，不 fire）/ 掉 3（count=2，fire）。每組附 `ceph_mon_metadata` series 提供 count。

- [ ] **Step 3：跑並存結果**
Run: `promtool test rules experiments/ceph-alert-rules/tests/tierA-promtool/mon-quorum-dynamic.test.yml`
Expected: `SUCCESS`。輸出存 `results/tierA-edge.txt`。

## Task 4: Tier B — Alertmanager routing 測試

**Files:**
- Create: `experiments/ceph-alert-rules/tests/tierB-routing/routes-test.sh`
- Create: `experiments/ceph-alert-rules/tests/tierB-routing/expected-routes.txt`

**Interfaces:**
- Consumes: Task 0 的 `rules/alertmanager-route.yml`。
- Produces: 對 spec §4.13 全部 label set 斷言 receiver 的腳本。

- [ ] **Step 0（前置，全 plan 一次性）：裝 amtool/alertmanager**
Run: `brew install alertmanager && amtool --version && alertmanager --version`
Expected: 兩 binary 皆 exit 0。fallback：`go install github.com/prometheus/alertmanager/cmd/amtool@latest`；alertmanager 用 docker `prom/alertmanager`。

- [ ] **Step 1：寫 `routes-test.sh`**——對每個 label set 跑 `amtool config routes test --config.file=../../rules/alertmanager-route.yml <labels>`，比對輸出 receiver 與預期；任一不符 exit 1。涵蓋全部 pager/slack 斷言，**特別含**「`type=ceph_default` 的 `CephMonDownQuorumAtRisk`/`CephOSDDownHigh` → slack（不得 pager）」。骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail
CFG="$(dirname "$0")/../../rules/alertmanager-route.yml"
fail=0
check() { # $1=expected receiver, rest=labels
  local want="$1"; shift
  local got
  got="$(amtool config routes test --config.file="$CFG" "$@")"
  if [[ "$got" != "$want" ]]; then echo "FAIL: $* -> got '$got' want '$want'"; fail=1
  else echo "ok: $* -> $got"; fi
}
check pager-ceph alertname=CephHealthError type=ceph_default
check pager-ceph alertname=CephClientBlocked source=ceph_stability
check pager-ceph alertname=CephMonDownScoped source=ceph_scoped
check slack-ceph alertname=CephLowPriorityNotice source=ceph_stability
check slack-ceph alertname=CephMonDownQuorumAtRisk type=ceph_default
check slack-ceph alertname=CephOSDDownHigh type=ceph_default
check slack-ceph alertname=CephHealthWarning type=ceph_default
# ...其餘自訂 alertname 全部 -> pager-ceph
exit $fail
```

- [ ] **Step 2：跑 routes-test**
Run: `bash experiments/ceph-alert-rules/tests/tierB-routing/routes-test.sh | tee experiments/ceph-alert-rules/results/tierB-routing.txt`
Expected: 全 `ok:`，exit 0。

## Task 5: Tier C — Live 整合 smoke（prometheus 載入 + alertmanager route/silence）

**Files:**
- Create: `experiments/ceph-alert-rules/tests/tierC-live/webhook-sink.py`（python http server，記錄收到的 alert 與其 receiver group）
- Create: `experiments/ceph-alert-rules/tests/tierC-live/alertmanager-live.yml`（route 指向 webhook sink 的 pager/slack 兩個 URL）
- Create: `experiments/ceph-alert-rules/tests/tierC-live/post-alert.sh`（POST 合成 alert 到 AM `/api/v2/alerts`）
- Create: `experiments/ceph-alert-rules/tests/tierC-live/run.sh`（編排：起 AM → 注入 → 斷言 route → 加 silence → 斷言 suppress → 收尾）
- Create: `experiments/ceph-alert-rules/lib/prometheus-load-check.sh`（起 prometheus 載入 rules，查 `/api/v1/rules` 全 healthy）

**Interfaces:**
- Consumes: Task 0 rules、Task 4 的 amtool/alertmanager。
- Produces: spec §4.10→C / §4.14 的 live 驗證。

- [ ] **Step 1：寫 `prometheus-load-check.sh`**——`prometheus --config.file=<tmp>` 載入兩個 rules 檔（config 內 `rule_files`），背景起，輪詢 `http://localhost:9090/api/v1/rules`，斷言全部預期 rule 出現且 `health=ok`，然後關掉。
Run: `bash experiments/ceph-alert-rules/lib/prometheus-load-check.sh`
Expected: `all rules healthy` exit 0。存 `results/tierC-prom-load.txt`。

- [ ] **Step 2：寫 webhook-sink.py + alertmanager-live.yml + post-alert.sh + run.sh**。run.sh 流程：起 webhook sink（兩 port 或一 port 用 path 分 pager/slack）→ 起 alertmanager 指向 `alertmanager-live.yml` → POST `CephOSDHostDownScoped{hostname=osd-host-a}` → 輪詢 sink 確認 pager group 收到 → `amtool silence add`（指 AM）`alertname=CephOSDHostDownScoped hostname=osd-host-a` → 重 POST → 確認被 suppress（AM `/api/v2/alerts?silenced=true` 或 sink 不再收到）→ POST `hostname=osd-host-b` 同 alert → 確認**未**被 suppress → POST `CephMonQuorumLost` → 確認仍到 pager（生命線）→ 收尾關 process。

- [ ] **Step 3：跑 run.sh**
Run: `bash experiments/ceph-alert-rules/tests/tierC-live/run.sh | tee experiments/ceph-alert-rules/results/tierC-live.txt`
Expected: 全斷言 PASS，exit 0。（flaky 防護：所有等待用「輪詢 + timeout」而非 sleep 定值。）

## Task 6: Tier D — 真 ceph 原始碼 oracle 對照表

**Files:**
- Create: `experiments/ceph-alert-rules/tests/tierD-realceph/README.md`

**Interfaces:**
- Produces: 各維護/故障情境 → ceph 實際升的 health check（附原始碼行號）→ 對應該 page 哪條 alert / 該不該 page，供使用者在真環境對照。

- [ ] **Step 1：寫對照表**：涵蓋「維護單 mon」「維護整台 OSD node」「維護單顆 OSD/換硬碟」「MON quorum 真失守」四情境，每列：觸發動作 → 預期 health check（`MON_DOWN` `HOST_IN_MAINTENANCE` `OSD_HOST_DOWN` `OSD_DOWN` `OSDMAP_FLAGS` `PG_DEGRADED` `PG_AVAILABILITY`）→ 原始碼 oracle（`OSDMap.cc:7316/7342/7493`、`PGMap.cc:2578`、`cephadm/module.py:2126/2131`、`HealthMonitor.cc:820`、`prometheus/module.py:1021`）→ 預期哪條 pager alert 應/不應 fire → 在你環境跑後對照欄。內容與頁面兩個 Callout 對齊，不得矛盾。

- [ ] **Step 2：人工核對行號**：對照 `ceph/` submodule 確認引用行號仍指向所述邏輯（若 submodule 在）；不在則標注以頁面既有引用為準。

## Task 7: run/ 編排 + README

**Files:**
- Create: `experiments/ceph-alert-rules/run/tierA.sh` `tierB.sh` `tierC.sh` `all.sh`
- Modify: `experiments/ceph-alert-rules/README.md`（補完）

- [ ] **Step 1：寫四個 run 腳本**：tierA 跑全部 promtool 測試；tierB 跑 routes-test；tierC 跑 prom-load + live；all.sh 依序 A→B→C，逐 tier 印 PASS/FAIL，任何非 0 即整體非 0。

- [ ] **Step 2：跑 all.sh**
Run: `bash experiments/ceph-alert-rules/run/all.sh`
Expected: `TIER A PASS / TIER B PASS / TIER C PASS / ALL PASS`，exit 0。

- [ ] **Step 3：補完 README**：前提、各 tier 目的與「測什麼/不測什麼」、安裝步驟、一鍵指令、各 tier PASS 判準、Tier C/D 的環境需求與限制、for:-縮短版的說明。鏡像 `experiments/timesyncd/README.md` 風格。

## Task 8: MDX 測試計劃頁 + 整合

**Files:**
- Create: `next-site/content/ceph/features/prometheus-alert-testing.mdx`
- Modify: `next-site/lib/projects.ts`（features[] 加 slug；「監控與告警」群組 slugs 加 slug）
- Modify: `next-site/content/ceph/feature-map.json`（加 node + edge `prometheus-alert-design → prometheus-alert-testing`）
- Modify: `next-site/content/ceph/quiz.json`（加 2–3 題）

**Interfaces:**
- Consumes: 完成且跑綠的 harness + 真實測試輸出（results/）。
- Produces: 讀者向專題頁（由 Technical Writer 寫、/reviewing-source-first-pages review）。

- [ ] **Step 1：Technical Writer 寫 MDX**（frontmatter `layout: doc` + `title:`）。敘事：緣起（為何要驗那套設計）→ 四層方法論（每層測什麼、為何這樣分、dev 能驗到哪、哪些留給真 ceph）→ 逐條「測哪條規則/哪個情境/怎麼測 step-by-step/預期」→ 怎麼跑（指向 experiments/）→ 邊界與限制。引用真實跑出來的結果片段。never-translate 清單遵守。
- [ ] **Step 2：整合 projects.ts / feature-map.json / quiz.json**（見 Files）。
- [ ] **Step 3：/reviewing-source-first-pages review loop**：每輪 review→修正，直到無 finding。writer 只改文字。
- [ ] **Step 4：orchestrator 收尾 `make validate`**
Run: `make validate`
Expected: exit 0。

## Task 9: 收尾 commit + push

- [ ] **Step 1：再跑一次 harness 確認全綠**
Run: `bash experiments/ceph-alert-rules/run/all.sh && make validate`
Expected: 皆 exit 0。
- [ ] **Step 2：commit（no-gpg）**
Run: `git add -A && git commit --no-gpg-sign -m "ceph: 在開發環境逐條驗證 prometheus alert 設計（four-tier 測試 harness + 專題頁）"`
- [ ] **Step 3：push（.ssh key）**
Run: `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push`
Expected: push 成功。

---

## Self-Review

**Spec coverage：** §2 規則清單→Task 0；§4.1–4.7→Task 1；§4.8–4.12→Task 2；§4.15→Task 3；§4.13→Task 4；§4.10/4.14→Task 5；§D oracle→Task 6；§5 harness→Task 0/7；§7 交付頁→Task 8；§8 驗證等級→各 tier run 步驟。無遺漏。
**Placeholder scan：** 無 TBD/TODO；關鍵測試（client-risk、osd-daemon-down、routes、live）給了實際骨架；可列舉的其餘測試以 spec §4 逐條對應，非「similar to」。
**Type consistency：** rule 檔名/路徑、recording rule 名（`ceph:osd_up:with_hostname`/`ceph:osd_host_down:scoped`）、receiver 名（`pager-ceph`/`slack-ceph`）、alert 名全 plan 一致。
