# Ceph 內容重構 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 依 `docs/superpowers/specs/2026-07-10-ceph-content-restructure-design.md`（下稱 spec）交付：2 項證據補救、11 篇新文章、archive banner 機制、導覽重構與 10 篇舊文 archive，全程不改舊文章內文。

**Architecture:** 雙軸架構（6 主分類 + Archive × 4 文章類型）。新文章全部先寫好並通過 review，最後一批才做 frontmatter archive + 導覽重排。alert 規則的 single source of truth 從舊 design 頁遷移到新 policy 頁（防漂移 guard 同步遷移）。

**Tech Stack:** Next.js 14 App Router（`output: 'export'`）、next-mdx-remote + gray-matter、Python `scripts/validate.py`（`make validate`）、bash 3.2 相容 shell。

## Global Constraints

- **不改舊文章內文**：`next-site/content/ceph/features/` 下既有 24 個 `.mdx` 的正文一個字都不動。唯一例外是 Task 15 的 archive 階段對 10 篇加兩行 frontmatter（`archived` / `supersededBy`）。
- **語言**：台灣繁中；never-translate 清單（node, cluster, controller, namespace, container, image, workload, Pod, Deployment, Service, PV, PVC, StorageClass, CRD, webhook, reconcile, operator, daemon, sidecar, taint, toleration, affinity…）永遠英文。程式碼註解英文。
- **MDX 硬規則**：不 import 任何元件（`<Callout>`/`<QuizQuestion>` 全域註冊）；不加 Mermaid；測驗不寫進 MDX；圖表只用既有 `/diagrams/ceph/*.png` 或文字表格。
- **版本錨點**：ceph v19.2.3（submodule commit `c92aebb`）、ceph-csi v3.14.0（`0d0e1f8`）。本 worktree 的 ceph submodule **未 checkout**——查 source 一律讀主 checkout 絕對路徑 `/Users/ikaros/Documents/code/learning-k8s/ceph/` 與 `/Users/ikaros/Documents/code/learning-k8s/ceph-csi/`（唯讀）。
- **Zero-fabrication**：新頁每個 `file:line` 引用都要對 pinned source 重新開檔驗過。稽核起點（含逐字引句）在 `docs/superpowers/reviews/2026-07-10-ceph-audit/`（Task 0 入庫），可引用但不可未驗照抄。
- **每篇新文章的開頭契約**（spec §3，逐項必備）：
  1. frontmatter：`layout: doc`、`title: Ceph — <題>`、`description:`、`category:`（`mechanism` | `experiment-report` | `decision-guide` | `runbook` 四選一，小寫原樣）。
  2. 正文第一節前放「## 本頁定位」區塊：文章類型與 as-of 日期（experiment-report 必填）；版本錨點；閱讀前提 ≤2 篇（各附一句為什麼必讀，不得指向 archived 頁）或明寫「本頁可獨立閱讀」；證據層級標示 T1（source）/T2（官方文件）/T3（真機實證）；「本頁取代」宣告。
  3. 「相關閱讀」只放文末。
  4. experiment-report 類另遵循 `skills/writing-experiment-reports/SKILL.md` 全套（七問、規劃總覽表含未跑實驗、逐實驗五欄、參數建議總表、被推翻預測醒目標示、limitations/incidents/open questions）＋主管 persona review gate。
- **Review gate**：mechanism/decision-guide/runbook 頁用 `skills/reviewing-source-first-pages/SKILL.md`；experiment-report 頁用 writing-experiment-reports 的七問 reviewer。reviewer 只讀該頁（不給稽核材料），iterate 到 ACCEPT。
- **Validate 紀律**：寫作 subagent 不跑 `make validate`；orchestrator 在標注「批次收尾」的步驟跑一次。baseline 已確認 exit 0。
- **Commit**：`git commit --no-gpg-sign`，訊息中文。push 用 `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push`。
- **本機限制**：bash 3.2（無 mapfile/nameref；`set -u` 下空陣列要保護）、無 timeout/gtimeout、無 gh；中文字串內變數一律 `${var}`。
- **主 checkout 唯讀**：`/Users/ikaros/Documents/code/learning-k8s/` 本體（含 gitignored 的 `experiments/*/results/`）只讀不寫、不清理。

## 新舊對應總表（Task 3–13、15 共用）

| 新頁 slug | category | 取代（Task 15 archive） |
|---|---|---|
| `slow-ops-detection-mechanisms` | mechanism | `slow-ops-and-bluestore-alerts` |
| `slow-ops-fast-detection-lab` | experiment-report | `slow-ops-and-bluestore-alerts` |
| `ceph-alert-policy-current` | decision-guide | `prometheus-alert-design` |
| `ceph-alert-validation-methodology` | mechanism | `prometheus-alert-testing` |
| `ceph-alert-real-lab-report` | experiment-report | `prometheus-alert-real-lab-findings`、`prometheus-alert-real-cluster` |
| `mon-quorum-loss-io-lab` | experiment-report | `mon-quorum-loss-impact` |
| `clock-skew-failure-modes` | mechanism | `clock-skew-magnitude-ladder` |
| `recovery-throttle-and-mclock` | mechanism | `recovery-throttle-runtime` |
| `rbd-datapath-and-csi` | mechanism | `rbd-and-csi` |
| `incident-bundle-operator-runbook` | runbook | `incident-bundle-runbook` |
| `incident-bundle-validation-report` | experiment-report | `incident-bundle-runbook` |

---

### Task 0: 稽核證據入庫

**Files:**
- Create: `docs/superpowers/reviews/2026-07-10-ceph-audit/*.json`（11 檔）
- Create: `docs/superpowers/reviews/2026-07-10-ceph-audit/README.md`

- [ ] **Step 1: 複製 11 份查證 JSON**

```bash
mkdir -p docs/superpowers/reviews/2026-07-10-ceph-audit
cp "/private/tmp/claude-501/-Users-ikaros-Documents-code-learning-k8s--claude-worktrees-loving-colden-a17bc3/bfd2f221-19d8-4a0a-a46f-256d4b673578/scratchpad/verify-results/"*.json docs/superpowers/reviews/2026-07-10-ceph-audit/
ls docs/superpowers/reviews/2026-07-10-ceph-audit/ | wc -l   # 預期 11
```

- [ ] **Step 2: 寫 README.md**（內容：本目錄是 2026-07-10 對 Codex 盤點的逐條查證產物，workflow `wf_0d2aa12c-e42`，11 agent；每檔一行說明——`claim_*.json` 三條 source-level 指控、`findings_*.json` 三組頁面比對、`datapoints.json` 六個實驗數據點、`navigation.json` 導覽稽核、`articles_*.json` 24 篇逐篇體檢、`experiments.json` 8 個實驗目錄證據狀態；並註明「引用需對 pinned source 重驗」）

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/reviews/2026-07-10-ceph-audit/
git commit --no-gpg-sign -m "reviews: Ceph 內容稽核證據入庫（11 份查證 JSON，wf_0d2aa12c-e42）"
```

---

### Task 1: W1a — alert real-lab 22 場 evidence ledger 補救（只能在本機跑）

**Files:**
- Create: `experiments/ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md`
- Test: 人工斷言（本 task 是資料整理，無 harness 測試）

**Interfaces:**
- Produces: `EVIDENCE-INDEX-2026-07.md`——Task 7（N2c 文章）唯一允許引用的 22 場總帳。

- [ ] **Step 1: 先盤點既有工具與 raw 結構**——讀 `experiments/ceph-alert-real-lab/lib/evidence.sh`、`lib/scenario-framework.sh`、`README.md` 的 22 場景表、`rendered/` 目錄；再抽 3 個 raw run 目錄看實際檔案結構：

```bash
ls /Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/results/ | sed 's/-[0-9T]*Z\..*//' | sort | uniq -c | sort -rn | head -30
ls /Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/results/ | grep -v -E '^(baseline|smoke|capacity-forecast)' | head -40
```

若 `lib/evidence.sh` 已有 render/index 函式，優先重用；沒有才寫一支一次性 python 彙整腳本（放 scratchpad，不進 repo）。

- [ ] **Step 2: 建 ledger**——`EVIDENCE-INDEX-2026-07.md` 必含：(a) 範圍宣告（lab 拓樸、rule 集版本=`experiments/ceph-alert-rules/rules/` 當時 HEAD、raw 檔只存本機的說明）；(b) 22 列總表：scenario id（對齊 README 的 S1–S22）、run 目錄名（含時戳）、注入方式、ceph 端證據檔名+關鍵行、Prometheus/Alertmanager/receiver 證據檔名+`activeAt`、negative assertions、rollback 與 `HEALTH_OK` 確認、verdict；(c) 每場一小節列 raw 目錄內實際檔案清單（檔名+一句話）。**每個欄位都要從 raw 檔逐一讀出，不可從 README 或 MDX 反推**；raw 缺某欄就在該欄寫 `missing in raw`（誠實斷鏈記錄）。
- [ ] **Step 3: 對帳**——22 場中若有場景在 raw 裡找不到完整 run（或只有失敗重試），在 ledger 開頭「缺口」節逐條列出；不得默默湊數。
- [ ] **Step 4: Commit**

```bash
git add experiments/ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md
git commit --no-gpg-sign -m "evidence: alert real-lab 22 場 machine-readable ledger（raw 只存本機，補齊 git 可稽核索引）"
```

---

### Task 2: W1b — incident-bundle --prom-url 真機驗證證據

**Files:**
- Create: `experiments/ceph-incident-bundle/PROM-VALIDATION-2026-07.md`
- Modify: `experiments/ceph-incident-bundle/README.md:142`（僅時效句）

**Interfaces:**
- Produces: `PROM-VALIDATION-2026-07.md`——Task 13（N7b）引用。

- [ ] **Step 1: 先找本機既有 artifacts**：

```bash
ls /Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/results/ 2>/dev/null
```

找到含 `cluster/prometheus/` 的 bundle 就直接引用（記 bundle 名、dump-info.txt 內容、metric 檔數）。

- [ ] **Step 2: 找不到才重跑（read-only）**：從主 checkout 用真 lab inventory 跑 `run/collect.sh --prom-url <lab prometheus>`（lab 的 monitoring stack 仍在，見 memory/專案記錄；收集是唯讀操作）。產出 bundle 後記錄驗證要點：exit code、`cluster/prometheus/<job>/` 檔數、dump-info.txt、URL credential 遮蔽行為。bundle 本體不進 git。
- [ ] **Step 3: 寫 `PROM-VALIDATION-2026-07.md`**：驗證日期、指令全文、環境（Prometheus 版本/target 數）、逐項斷言結果表（dump 結構、budget 截斷、遮蔽、缺 curl/python3 的 SKIPPED 路徑引 tests/ 佐證）、bundle 存放位置（本機路徑）。
- [ ] **Step 4: 更新 README 時效**——把 `README.md:142` 的「尚未對真 Prometheus 驗證（lab 機器備妥後補跑）」改為指向 `PROM-VALIDATION-2026-07.md` 的一句話。
- [ ] **Step 5: Commit**

```bash
git add experiments/ceph-incident-bundle/PROM-VALIDATION-2026-07.md experiments/ceph-incident-bundle/README.md
git commit --no-gpg-sign -m "evidence: incident-bundle --prom-url 真機驗證證據落 git，README 時效同步"
```

---

### Task 3: N1a `slow-ops-detection-mechanisms`（mechanism）

**Files:**
- Create: `next-site/content/ceph/features/slow-ops-detection-mechanisms.mdx`
- Modify: `next-site/lib/projects.ts:314`（ceph `features` 陣列 append `'slow-ops-detection-mechanisms'`）

**Interfaces:**
- Produces: 頁面 slug `slow-ops-detection-mechanisms`——Task 4 的 prerequisite、Task 15 的 supersededBy 目標。

**素材（writer 必讀）：**
- 舊頁 `slow-ops-and-bluestore-alerts.mdx`（上半機制章節正確可移植：兩個 SLOW_OPS metric 來源鏈 OpTracker→DaemonHealthMetric→mgr→prometheus、七缺口表、BLUESTORE_SLOW_OP_ALERT 機制與對照表、n2 無人 export、summary 字串解析脆弱耦合、stalled-read 三兄弟、absent() 兜底）。
- `experiments/ceph-slow-ops-detection/{REPORT-2026-07-09.md,HYPOTHESES.md}`：三層盲區（H-001 暫態／H-024 sub-30s 持續劣化——150s 節流 op_w 峰值 15.2s 而 SLOW_OPS 全程 0／H-023 採樣漏失——44.7s 真事件兩路全默）、H-025 怪錯人（卡 osd.0 亮別台 primary osd.4/6/7/8）、H-011 完成才記帳、H-014 counter 只覆蓋 5+1 呼叫點與 omap/scrub 盲區、H-019 Squid 版本依賴、H-017 idle 盲區。
- 稽核檔 `docs/superpowers/reviews/2026-07-10-ceph-audit/findings_slowops.json`（哪些舊段落保留/替換/新增的逐條對照）。

- [ ] **Step 1: 寫文章**。結構：本頁定位（category: mechanism；前提：無——自帶場景；證據層級 T1+T3；取代 slow-ops-and-bluestore-alerts 的機制部分）→ 場景 → 兩個 SLOW_OPS metric 來源鏈 → BLUESTORE_SLOW_OP_ALERT 平行路徑 → 三層盲區（各附真機實證數字與 E-xx 錨點）→ H-025 定位陷阱 → 訊號邊界表（H-011/H-014/H-017/H-019，含 Squid vs Reef 可用性）→ 文末相關閱讀（指向 N1b、pg-health-states、bluestore-deep-dive）。
- [ ] **Step 2: 重數呼叫點**——舊頁寫「22 處」、研究枚舉 29 處，writer 必須自己數：

```bash
grep -cE 'log_latency(_fn)?\(' /Users/ikaros/Documents/code/learning-k8s/ceph/src/os/bluestore/BlueStore.cc
```

以實數為準寫進文章（並在行文說明口徑：log_latency + log_latency_fn）。

- [ ] **Step 3: 驗證所有 file:line**——文章引用的每個錨點（`OSD.cc:7825-7832`、`BlueStore.cc:18476-18484`、`TrackedOp.cc` 等）逐一開主 checkout 檔案對行。
- [ ] **Step 4: 加 slug 進 projects.ts features 陣列**（只動陣列，group 留 Task 15）。
- [ ] **Step 5: Review gate**——dispatch reviewing-source-first-pages reviewer，iterate 到 satisfied。
- [ ] **Step 6: Commit**

```bash
git add next-site/content/ceph/features/slow-ops-detection-mechanisms.mdx next-site/lib/projects.ts
git commit --no-gpg-sign -m "ceph: 新增 slow-ops-detection-mechanisms——SLOW_OPS/BLUESTORE 訊號機制與三層盲區（真機實證版）"
```

---

### Task 4: N1b `slow-ops-fast-detection-lab`（experiment-report，as-of 2026-07-09）

**Files:**
- Create: `next-site/content/ceph/features/slow-ops-fast-detection-lab.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**Interfaces:**
- Consumes: Task 3 的 slug（唯一 prerequisite：「先讀 slow-ops-detection-mechanisms——本頁的規則設計都建立在那頁的訊號機制上」）。

**素材：** `experiments/ceph-slow-ops-detection/` 全套（REPORT-2026-07-09.md、EVIDENCE-SUMMARY-2026-07-09.md 12 run 索引、HYPOTHESES.md 25 條=19 confirmed/4 violated/2 proposed、rules/ceph-slow-ops-fast.yml R1–R4、tests/）。核心數字：R1 +14s、R2 +20s（firmware 指紋：同 node ≥3 OSD）、R3/R4 +45~60s vs 舊 ~120s；E-03 idle 全靜默；H-015 純負載也觸發（FP 心理預期）；H-016 `bluestore_log_op_age` runtime 調低。

- [ ] **Step 1: 寫文章**，完整走 writing-experiment-reports 模板（`skills/writing-experiment-reports/report-template.md`）：§0 前提（緣起=firmware 事件形態、SUT=真 lab 拓樸、判準、scrape 10s）→ 規劃總覽表（25 條 hypothesis 對帳：executed/merged/T1-only）→ 逐實驗五欄（12 run）→ 被推翻的 4 條預測醒目節 → R1–R4 規則與偵測延遲表 → 參數建議總表（`bluestore_log_op_age`、rule thresholds、keep_firing_for，含變更方式 runtime/restart）→ limitations（版本依賴、idle 盲區、FP 條件）→ open questions。
- [ ] **Step 2: 驗證數字**——每個 before→after 數字對 REPORT/HYPOTHESES/EVIDENCE-SUMMARY 原文（raw bundle 在本機，repo 內以這三檔為準；文中註明 raw 存放狀態）。
- [ ] **Step 3: 加 slug 進 projects.ts。**
- [ ] **Step 4: Review gate**——主管 persona 七問 reviewer（只給文章），iterate 到 ACCEPT。
- [ ] **Step 5: Commit**（訊息：`ceph: 新增 slow-ops-fast-detection-lab——R1-R4 快速偵測真機研究報告（as-of 2026-07-09）`）
- [ ] **Step 6: 批次收尾（orchestrator）**——跑 `make validate`，預期 exit 0。

---

### Task 5: N2a `ceph-alert-policy-current`（decision-guide）+ 防漂移 guard 遷移

**Files:**
- Create: `next-site/content/ceph/features/ceph-alert-policy-current.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）
- Modify: `experiments/ceph-alert-rules/lib/check-rules-match-page.sh:8-9`
- Test: `bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh`

**Interfaces:**
- Produces: 全站 alert 規則唯一的「現行版」頁；guard 改指向本頁後，舊 design/findings 頁脫離 single-source-of-truth 角色。

**素材：** `experiments/ceph-alert-rules/rules/`（7 檔、29 條 rule=6 stability + 3 scoped + 18 coverage + 1 dynamic + 1 external）、`rules/alertmanager-route.yml`（4 個 source 含 `ceph_external`）、舊 design 頁的三角色分類/silence SOP/`ceph_health_detail` 無 host label 機制（正確可移植）、`findings_alertseries.json`（哪些數字是現行版：排除清單 26 個 name、LowPriority 8 個）、slow-ops 研究的 R1–R4（列為「並存的快速偵測層」引 N1b）、quorum 盲區緩解欽定 canonical：**Blackbox 版**（`CephMonQuorumLostBlackbox` + blackbox_exporter，理由：最新真機驗證+標準 exporter；`CephMonQuorumLostExternal`/mon-tcp-probe.py 註記為同機制的第一版實作）。

- [ ] **Step 1: 寫文章**。結構：本頁定位（category: decision-guide；「隨 rules/ 目錄更新」；前提：無；取代 prometheus-alert-design）→ 設計原則濃縮（三角色、無 host label 機制、scoped 去重）→ 29 條 rule 全列（YAML 逐字引自 `rules/`，附每條的驗證狀態欄：promtool/Tier B/C/真機 S-編號，證據連結指向 N2c 與 `EVIDENCE-INDEX-2026-07.md`）→ routing 現行版 → silence SOP 三粒度 → quorum 生命線一節（mgr 路徑先天盲 → Blackbox canonical）→ 文末相關閱讀（N2b、N2c、N1b、mon-quorum-detection-blind-spot）。
- [ ] **Step 2: 遷移 guard**——`check-rules-match-page.sh` 第 8–9 行改為：

```bash
DESIGN_PAGE="$ROOT/next-site/content/ceph/features/ceph-alert-policy-current.mdx"
FINDINGS_PAGE="$ROOT/next-site/content/ceph/features/ceph-alert-policy-current.mdx"
```

（invariants 兩組檢查同指新頁；如 script 對兩檔有不同斷言集，改成都對新頁跑。）

- [ ] **Step 3: 跑 guard 驗證**

```bash
bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh; echo "exit=$?"   # 預期 exit=0
```

失敗＝新頁 YAML 與 rules/ 有漂移，修文章不修 rules。

- [ ] **Step 4: 跑 alert-rules 既有測試**（如 `experiments/ceph-alert-rules/` 有 run-tests 入口就跑；至少 `promtool test rules` 那層不受影響）。
- [ ] **Step 5: 加 slug 進 projects.ts；Review gate（source-first reviewer，重點：29 條與 rules/ 逐字一致、驗證狀態欄不誇大）。**
- [ ] **Step 6: Commit**（`ceph: 新增 ceph-alert-policy-current——現行 29 條 rule 的 single source of truth；防漂移 guard 遷移`）

---

### Task 6: N2b `ceph-alert-validation-methodology`（mechanism）

**Files:**
- Create: `next-site/content/ceph/features/ceph-alert-validation-methodology.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** 舊 testing 頁的可保留骨架（四層 Tier A–D 分工表、「Tier A 證明的是 IF」哲學、三個 PromQL gotcha、F1 完整故事含 `or vector(0)` 與 F1b trade-off、綠燈不可過度解讀清單）；`findings_alertseries.json` 的過時清單（必須全部修正後收錄：Tier D 已完成且 `tierD-realceph/` 是可執行 harness、排除清單 26 個 name、LowPriority 8 個、maintenance fixture 用 `OSD_FLAGS`）；注入手法目錄（cgroup v2 `io.max`、stop mon/osd、rados bench——出自 real-lab README 與 16 發現）。

- [ ] **Step 1: 寫文章**（category: mechanism；前提 ≤1：`ceph-alert-policy-current`——「規則本體與名詞在那頁」；取代 prometheus-alert-testing）。F1 故事保留歷史敘事但明標時間線（06-25 發現 → 06-26 真機修正）。
- [ ] **Step 2: 對 harness 現況逐字驗證**——文中引用的 fixture/測試檔名與內容（`maintenance-thesis.test.yml` 用 `OSD_FLAGS`、`client-risk.test.yml` 26 個 name、`mon-external.test.yml` 存在）全部開檔核對。
- [ ] **Step 3: 加 slug；Review gate；Commit**（`ceph: 新增 ceph-alert-validation-methodology——四層驗證方法論（同步到 harness 現況）`）

---

### Task 7: N2c `ceph-alert-real-lab-report`（experiment-report，as-of 2026-07）〔依賴 Task 1〕

**Files:**
- Create: `next-site/content/ceph/features/ceph-alert-real-lab-report.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `experiments/ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md`（Task 1 產出，22 場總帳——**本頁數字唯一來源**）、`experiments/ceph-alert-rules/tests/tierD-realceph/results/observations.md`（S1–S5 真機觀測）、舊 real-lab-findings 頁的 16 發現與 22 場景表、舊 real-cluster 頁的發現一/二機制與逐欄對帳表、`EVIDENCE-SUMMARY-2026-07-04.md`（最初 3 場）。

- [ ] **Step 1: 統一場景編號**——舊兩頁的 S1–S5（real-cluster）與 S1–S22（real-lab-findings）撞名：本頁全部改用 `RL-01…RL-22`（real lab）與 `TD-01…TD-05`（tier D 先導），並附新舊編號對照表。
- [ ] **Step 2: 寫文章**，writing-experiment-reports 模板：§0 前提（6-host lab 拓樸——**不再稱 3-node**、rule 集版本、receiver 鏈）→ 規劃總覽表（22 場對帳，含 ledger 缺口誠實列出）→ 逐場五欄（注入/預期/實際/rollback/verdict，全部引 EVIDENCE-INDEX）→ 16 發現（保留原敘事、標 as-of）→ 發現一/二機制節（OSD_FLAGS、mgr 凍結）→ v1→v2 演進與最終規則指向 N2a（**不內嵌完整 YAML**——就是舊頁「內嵌快照過時」教訓）→ limitations/incidents。
- [ ] **Step 3: 加 slug；主管 persona 七問 review gate；Commit**（`ceph: 新增 ceph-alert-real-lab-report——22 場真機注入收官報告（ledger 可稽核）`）
- [ ] **Step 4: 批次收尾（orchestrator）**——`make validate` exit 0。

---

### Task 8: N3 `mon-quorum-loss-io-lab`（experiment-report，as-of 2026-07-08）

**Files:**
- Create: `next-site/content/ceph/features/mon-quorum-loss-io-lab.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `experiments/ceph-mon-quorum-blind-spot/`（REPORT.md §4 真機時序表+fio IO 矩陣、HYPOTHESES.md H-A/H-B、results/ **已進 git** 的 raw：`results/mon-quorum-2down-20260708T154019Z/` 14 檔+baseline）；舊 mon-quorum-loss-impact 頁正確可移植的 T1：quorum 數學（`MonMap.h:193`）、lease 時序常數鏈（3s renew/5s expire/10s timeout）、dataplane vs control plane 分界、A1/A2/B/C 情境時間軸。修正點（`datapoints.json` #5）：「新 PVC 會失敗」→ 真機實測新 PVC 反而 Bound（CSI provisioner 是既有連線），卡的是 node 端全新 kernel `rbd map`；「既有 I/O 可能持續」→ fio 實證全 pattern ≈ baseline。

- [ ] **Step 1: 寫文章**（category: experiment-report；前提 ≤1：architecture——「MON/Paxos 角色」；取代 mon-quorum-loss-impact；相關閱讀指 mon-quorum-detection-blind-spot——偵測面在那頁，本頁是 I/O 衝擊面）。結構：§0 前提（3 mon lab、注入=停 2/3 mon、fio 矩陣定義）→ T1 機制底（quorum 數學/lease/分界——from 舊頁驗證後移植）→ 規劃與逐實驗五欄（fio baseline vs window、新 PVC、新 pod、ground truth `748 slow ops`）→ 反直覺發現節（PVC Bound）→ 建議（quorum 失守期間不要 drain node 等）→ H-B5 未驗證項誠實列 open question。
- [ ] **Step 2: raw 對數**——文中數字對 `results/mon-quorum-2down-20260708T154019Z/` 內檔案（此實驗 raw 在 git，逐檔可稽核——在文中明寫這點）。
- [ ] **Step 3: 加 slug；七問 review gate；Commit**（`ceph: 新增 mon-quorum-loss-io-lab——quorum 失守的 I/O 衝擊真機報告（取代 T1 推演版）`）

---

### Task 9: N4 `clock-skew-failure-modes`（mechanism）

**Files:**
- Create: `next-site/content/ceph/features/clock-skew-failure-modes.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `claim_clock-skew-source.json`（完整反證錨點）；舊 ladder 頁可移植部分（三線框架、mono/wall clock 心智模型、client ticket 免疫、方向 A OSD 快→`OSD.cc:4068` exit(1)、line 323 的 OSD 端 need_new_secrets 正確邏輯）。**兩處必須改寫**：
1. 線 1（MON↔MON）：>5s 穩態 skew 的真實後果=該 peon 的 lease 到手即過期→`is_lease_valid()` false→**永久不可讀**（讀請求堆積、derr 洗 log）；`handle_lease` 照樣 ACK+重設 10s timer（`Paxos.cc:1123-1144`）、leader 每 3s renew（`mon.yaml.in` renew factor 0.6）→ `lease_timeout()`（唯一 bootstrap 路徑，`Paxos.cc:1215-1221`）永不觸發。election churn 的真實條件=lease 訊息斷流 ≥10s 或時鐘跳變瞬間。
2. 線 2 方向 B（mon 先快再跳回）：`need_new_secrets(now)` 條件（`Auth.h:324-326`）→ 跳回後 `current().expiration > now` → **完全不 rotate、rotation 凍結長達偏移量**；未來 key 不被淘汰、`secret_id` 仍查得到 → 「校時跳回那一刻在線 OSD 大量掉線」不成立。原「校時跳回是高風險操作」警告降級為「未經真機驗證的假說」或刪除（writer 判斷，但不得保留為斷言）。

- [ ] **Step 1: 寫文章**（category: mechanism；前提 ≤2：cluster-time-skew-impact——「毫秒級刻度在那頁」、mon-clock-skew-detection——「WARN 偵測鏈在那頁」；取代 clock-skew-magnitude-ladder）。
- [ ] **Step 2: 逐錨點重驗**——上述每個 file:line 開主 checkout 原檔核對（這頁就是因 source 錯誤被退場的，review 標準最嚴）。
- [ ] **Step 3: 加 slug；source-first review gate（reviewer 需獨立對 Paxos.cc/Auth.h 查證）；Commit**（`ceph: 新增 clock-skew-failure-modes——修正 election churn 因果鏈與 cephx 方向 B 機制`）

---

### Task 10: N5 `recovery-throttle-and-mclock`（mechanism + decision-guide 成分）

**Files:**
- Create: `next-site/content/ceph/features/recovery-throttle-and-mclock.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `claim_recovery-throttle-injectargs.json`；舊 recovery-throttle-runtime 頁正確可移植部分（`_recover_now` 單向閘門、四層 gate 表、config set 的 mon db rollback 與 ping-pong 兩輪止血、`osd_max_backfills` reserver 差異、自然收斂時序、`/diagrams/ceph/recovery-throttle-dynamics.png`）。**必須改寫**：injectargs 寫入 `CONF_OVERRIDE`（`config.cc:851`）最高優先層（`config.h:30-38`、`config_values.cc:60-62`）；mClock 防寫分支只做 `config rm`（mon db）+ clog warning（`OSD.cc:10229-10239`），不動本機 cct；mon push 只操作 `CONF_MON` 層（`config.cc:308,334`）→ **injectargs 的值在該 OSD 生效直到重啟**；clog「did not take effect」在 injectargs 情境是 source 自身的誤導文案（值得專節點出）；injectargs（生效但 ephemeral+誤導 warning）vs `config set`（真被 rollback）拆成對照軸心。

- [ ] **Step 1: 寫文章**（category: mechanism；前提 ≤1：mclock-osd-scheduler——「profile 與三桶在那頁」；取代 recovery-throttle-runtime）。加「在你環境驗證」節：`ceph daemon osd.N config show | grep -A2 osd_max_backfills` 應顯示 injectargs 後值來源為 override（此指令標「在你環境跑後對照」等級；有真 lab 時間就實跑一次把輸出貼進文章升級為 T3）。
- [ ] **Step 2: 逐錨點重驗；加 slug；source-first review gate；Commit**（`ceph: 新增 recovery-throttle-and-mclock——injectargs/CONF_OVERRIDE 真實行為修正版`）

---

### Task 11: N6 `rbd-datapath-and-csi`（mechanism）

**Files:**
- Create: `next-site/content/ceph/features/rbd-datapath-and-csi.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `claim_rbd-csi-datapath.json`；舊 rbd-and-csi 頁正確可移植部分（RBD 三類 object 與 thin-provision、`rbd_default_order=22`→4MiB、cls_rbd/omap、feature dependency 硬檢查、PVC 責任邊界判讀表、rook vs ceph-csi 職責、controller/node plugin 分工）。**必須改寫/新增**：
1. 兩條 data path 分開畫：userspace（rbd-nbd/QEMU librbd → `ImageRequest.cc` striping → librados/Objecter）vs kernel（krbd：`rbd map` 產生 `/dev/rbdX`，striping 在 kernel 內，**不經過** librbd 碼）。
2. ceph-csi 預設 mounter=krbd（`rbd_util.go:54-55`、`nodeserver.go:213-214`）→ 預設部署下 librbd 節只適用 rbd-nbd/QEMU 情境（明講）。krbd 不支援 feature 時預設報錯、要 `tryOtherMounters:true` 才 fallback（`nodeserver.go:253-261`）。
3. volumeMode 正確流程：Filesystem = NodeStage `FormatAndMount` 到 stagingPath（`nodeserver.go:840-844`）→ NodePublish bind-mount stagingPath（`:875`）；Block = bind device 檔、Pod 看到 raw device（KubeVirt VM disk 即此路徑）。
4. 版本錨（全篇 v19.2.3 + ceph-csi v3.14.0——舊頁是 24 篇唯一沒版本錨的）。
5. 量化結論以連結引用 vm-storage-perf（如 `rbd-io-production-tuning` 的 krbd/librbd CoV 差異、qd 建議），不重寫。

- [ ] **Step 1: 寫文章**（category: mechanism；前提 ≤2：architecture、crush-and-placement；取代 rbd-and-csi）。移除舊頁的 lab Day 18 對齊敘述與「收穫檢查」自測題（quiz 站規已改）。
- [ ] **Step 2: 逐錨點重驗（ceph-csi 檔案行號 v3.14.0）；加 slug；source-first review gate；Commit**（`ceph: 新增 rbd-datapath-and-csi——krbd/librbd 雙路徑與 volumeMode 修正版`）
- [ ] **Step 3: 批次收尾（orchestrator）**——`make validate` exit 0。

---

### Task 12: N7a `incident-bundle-operator-runbook`（runbook）

**Files:**
- Create: `next-site/content/ceph/features/incident-bundle-operator-runbook.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `findings_incident.json` 的 (a)-(n) 能力清單（全部附 file:line，writer 逐項對 `experiments/ceph-incident-bundle/` 現行碼重驗）；舊 runbook 頁可移植部分（「先保留現場」定位、inventory 欄位表、exit code 0/2/1 語意、bundle 六入口檔、三份收集清單、安全界線五條）。**5 處與現行為不符的舊描述不得沿用**：rook 層預設 `--kube-mode remote`；cephadm 層 runner 三階擇優（direct→sudo→cephadm shell，`collect-cluster-cephadm.sh:10-20`）；大 log 收 tail+`.TRUNCATED`；bsdtar xattr 已修（`--no-xattrs`+`COPYFILE_DISABLE=1`）；environment.txt 含 `ceph_source/ceph_runner/rook_source`（+prom 欄位）。

- [ ] **Step 1: 寫文章**（category: runbook；前提：無——目標讀者維持「只懂基本 Linux」；取代 incident-bundle-runbook）。結構：定位 → 前置需求（SSH known_hosts/BatchMode）→ inventory（SEED_HOST 選填）→ 執行（--mode auto 行為與限制、--seed 何時指定）→ 參數全表（timeout 分層、kube-mode/context、operator-namespace、prom-url 四參數、redact 開關、out/keep-workdir/quiet）→ 進度與 stdout 契約 → exit code 語意（含「叢集故障本身不算收集失敗」）→ bundle 結構（含 CONTENTS.md、ssh-debug/、cluster/prometheus/）→ 失敗處理（verify 失敗保留 workdir、Ctrl-C exit 130、ssh-debug 判讀）→ 安全界線（redaction 現行範圍、verify 雙層把關）。
- [ ] **Step 2: 逐項對工具現行碼重驗（usage 文字、預設值、測試斷言）；加 slug；source-first review gate（重點：一個不懂 Ceph 的人能照著跑完）；Commit**（`ceph: 新增 incident-bundle-operator-runbook——v3 工具全能力操作手冊`）

---

### Task 13: N7b `incident-bundle-validation-report`（experiment-report）〔依賴 Task 2〕

**Files:**
- Create: `next-site/content/ceph/features/incident-bundle-validation-report.mdx`
- Modify: `next-site/lib/projects.ts:314`（append slug）

**素材：** `experiments/ceph-incident-bundle/README.md` 的 multi-fault 驗證表（2026-06-30，5 情境）、`docs/superpowers/reviews/2026-06-30-lab-validation.md`、Task 2 產出的 `PROM-VALIDATION-2026-07.md`、`tests/` 7 個測試的行為背書。

- [ ] **Step 1: 寫文章**（category: experiment-report；as-of 2026-06-30 + 2026-07 兩波，分節明標；前提 ≤1：incident-bundle-operator-runbook；取代 incident-bundle-runbook 的實測章節）。結構：§0 前提（驗證環境、判準=exit code 與 bundle 內容斷言）→ 規劃總覽（健康收集/OSD down/MON down/node 不可達/seed 不可達/prom dump）→ 逐場五欄 → 發現與邊界（partial failure 仍產 bundle 的設計驗證）→ limitations（redaction 非 DLP 等）。
- [ ] **Step 2: 加 slug；七問 review gate；Commit**（`ceph: 新增 incident-bundle-validation-report——multi-fault 與 prom dump 驗證報告`）
- [ ] **Step 3: 批次收尾（orchestrator）**——`make validate` exit 0。

---

### Task 14: Archive banner 元件擴充

**Files:**
- Modify: `next-site/app/[project]/features/[slug]/page.tsx:48-61`
- Test: `make validate`（含 next build）+ 臨時 fixture 手驗

**Interfaces:**
- Consumes: frontmatter `archived: true`、`supersededBy: <slug> | [<slug>, ...]`（Task 15 寫入）。
- Produces: archived 頁自動渲染 banner；非 archived 頁零變化。

- [ ] **Step 1: 修改 page.tsx**——在 `<div>`（line 48）之後、`{data.title && (` 之前插入：

```tsx
          {data.archived && (
            <div className="mb-6 rounded-md border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-200">
              本頁為歷史版本，內容保留當時狀態、不再更新。
              {(() => {
                const targets: string[] = Array.isArray(data.supersededBy)
                  ? data.supersededBy
                  : data.supersededBy ? [data.supersededBy] : []
                if (targets.length === 0) return null
                return (
                  <>
                    {' '}現行版本請看：
                    {targets.map((t, i) => (
                      <span key={t}>
                        {i > 0 && '、'}
                        <Link href={`/${project.id}/features/${t}`} className="underline text-amber-100 hover:text-white">
                          {t}
                        </Link>
                      </span>
                    ))}
                  </>
                )
              })()}
            </div>
          )}
```

- [ ] **Step 2: 手驗**——臨時把某一頁（例如 `rbd-and-csi.mdx`）frontmatter 加 `archived: true` / `supersededBy: rbd-datapath-and-csi`，跑 `cd next-site && npx next build` 確認無 type error，**然後還原該 frontmatter**（Task 15 才正式加）。
- [ ] **Step 3: `make validate` exit 0；Commit**（`site: feature 頁支援 archived/supersededBy frontmatter banner`）

---

### Task 15: 導覽重構 + 10 篇 archive + feature-map 重建

**Files:**
- Modify: `next-site/lib/projects.ts:315-323`（featureGroups）、`:340-364`（learningPaths）、ceph `story.highlights`（`:343` 的 `rbd-and-csi` 連結目標）
- Modify: 10 篇舊 MDX 的 frontmatter（各加 2 行，內文不動）
- Modify: `next-site/content/ceph/feature-map.json`（重建）

**前置條件：Task 3–13 全部完成且 review ACCEPT。**

- [ ] **Step 1: 10 篇 frontmatter archive**——對「新舊對應總表」的 10 篇，在 frontmatter `title:` 行後各加（以 rbd-and-csi 為例）：

```yaml
archived: true
supersededBy: rbd-datapath-and-csi
```

多目標的兩篇：`slow-ops-and-bluestore-alerts` → `supersededBy: [slow-ops-detection-mechanisms, slow-ops-fast-detection-lab]`；`incident-bundle-runbook` → `supersededBy: [incident-bundle-operator-runbook, incident-bundle-validation-report]`；`prometheus-alert-real-lab-findings` 與 `prometheus-alert-real-cluster` → 皆 `supersededBy: ceph-alert-real-lab-report`。**diff 檢查：每檔恰好 +2 行（或 +2 行含 list），零刪改。**

- [ ] **Step 2: featureGroups 重排**——替換 `projects.ts:315-323` 為：

```ts
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '核心模型與資料路徑', icon: '🧮', slugs: ['crush-and-placement', 'crush-straw-straw2', 'pool-pgnum-pgpnum', 'osd-and-bluestore', 'bluestore-deep-dive', 'rbd-datapath-and-csi'] },
      { label: '故障模型與時間', icon: '💥', slugs: ['osd-flapping', 'pg-health-states', 'mon-clock-skew-detection', 'cluster-time-skew-impact', 'clock-skew-failure-modes', 'mon-quorum-loss-io-lab', 'mon-quorum-detection-blind-spot'] },
      { label: '效能與參數決策', icon: '⚙️', slugs: ['mclock-osd-scheduler', 'recovery-throttle-and-mclock'] },
      { label: '可觀測性與 alerting', icon: '📡', slugs: ['slow-ops-detection-mechanisms', 'slow-ops-fast-detection-lab', 'ceph-alert-policy-current', 'ceph-alert-validation-methodology', 'ceph-alert-real-lab-report'] },
      { label: '維運命令與事故處理', icon: '🛠️', slugs: ['osd-ok-to-stop', 'osd-safe-to-destroy', 'incident-bundle-operator-runbook', 'incident-bundle-validation-report'] },
      { label: 'Archive（歷史版本）', icon: '📦', slugs: ['slow-ops-and-bluestore-alerts', 'prometheus-alert-design', 'prometheus-alert-testing', 'prometheus-alert-real-lab-findings', 'prometheus-alert-real-cluster', 'mon-quorum-loss-impact', 'clock-skew-magnitude-ladder', 'recovery-throttle-runtime', 'rbd-and-csi', 'incident-bundle-runbook'] },
    ],
```

同時把 `features` 陣列重排成上述順序（active 25 篇在前、archived 10 篇在後——`features` 順序決定上一篇/下一篇導覽）。

- [ ] **Step 3: learningPaths 重寫**——替換 `projects.ts:340-364`：

```ts
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '先建立全貌：3 類 daemon + RADOS' },
        { slug: 'crush-and-placement', note: 'CRUSH 為什麼不需要中央 NameNode' },
        { slug: 'rbd-datapath-and-csi', note: '從 PVC 反推 ceph：krbd/librbd 兩條 data path' },
      ],
      intermediate: [
        { slug: 'crush-straw-straw2', note: 'straw2 如何降低 reweight 時的資料移動' },
        { slug: 'pool-pgnum-pgpnum', note: 'pg_num/pgp_num 調整在 mgr 端如何收斂' },
        { slug: 'osd-and-bluestore', note: 'replication / recovery / scrubbing flow' },
        { slug: 'mclock-osd-scheduler', note: 'client I/O、recovery、scrub 的 QoS 三桶' },
        { slug: 'recovery-throttle-and-mclock', note: 'runtime 調 recovery 參數：injectargs 與 config set 的真實差異' },
        { slug: 'pg-health-states', note: 'PG 危險狀態的四類風險與現場判讀' },
      ],
      advanced: [
        { slug: 'bluestore-deep-dive', note: 'TransContext 狀態機、deferred write、checksum' },
        { slug: 'osd-flapping', note: 'flap pattern 對 mark-down / mark-out 的觸發路徑' },
        { slug: 'cluster-time-skew-impact', note: '毫秒級 clock offset 對四條通道的實際影響' },
        { slug: 'clock-skew-failure-modes', note: '秒級以上 skew：peon 不可讀與 cephx rotation 凍結' },
        { slug: 'mon-quorum-loss-io-lab', note: 'quorum 失守時 I/O 怎麼受影響（真機實測）' },
        { slug: 'mon-quorum-detection-blind-spot', note: 'mgr metric 凍結盲區與 blackbox 補法' },
        { slug: 'slow-ops-detection-mechanisms', note: 'SLOW_OPS 訊號鏈與三層盲區' },
        { slug: 'slow-ops-fast-detection-lab', note: 'R1-R4：偵測延遲從 ~120s 壓到 14~60s' },
        { slug: 'ceph-alert-policy-current', note: '現行 29 條 alert rule 與 silence SOP' },
        { slug: 'incident-bundle-operator-runbook', note: '出事第一步：先保留現場再判讀' },
      ],
    },
```

並把 `story.highlights` 中 `{ slug: 'rbd-and-csi', ... }` 的 slug 改為 `rbd-datapath-and-csi`（note 不變）。grep 確認 story/problemStatement 無其他 archived slug 引用。

- [ ] **Step 4: feature-map 重建**——寫一支一次性 python（scratchpad）：讀舊 `feature-map.json`；保留 active 14 舊頁 node；新增 11 個新頁 node（category 沿用組別：infra/algorithm/storage/failure/ops/monitoring；position 依組排格）；edges：保留兩端皆 active 的舊 edge；舊 edge 一端是 archived 頁者改指對應新頁（按新舊對應總表 remap，去重）；新增新頁間的關鍵語意 edge（至少：policy→methodology「驗證方法」、methodology→real-lab-report「真機收官」、mechanisms→fast-detection-lab「規則設計依據」、quorum-io-lab→blind-spot「偵測面」、operator-runbook→validation-report「驗證」）。輸出後人工檢查 node 數 = 25。
- [ ] **Step 5: 全站互鏈檢查**——(a) 新 11 篇的 prerequisite 宣告不指向 archived 頁且無環（人工核對——共 ≤11 條邊，直接畫）；(b) `grep -rn "features/<archived-slug>" next-site/content/*/features/*.mdx` 確認**新文章**沒有連到 archived 頁（舊文互連不管）；(c) archived 10 篇每篇 frontmatter 都有 `supersededBy` 且目標 slug 存在。
- [ ] **Step 6: 批次收尾（orchestrator）**——`make validate` exit 0。
- [ ] **Step 7: Commit**（`ceph: 導覽重構（6+1 組、learningPaths 全覆蓋）+ 10 篇 archive + feature-map 重建`）

---

### Task 16: 最終驗證 + push + PR

- [ ] **Step 1: 全量驗證**

```bash
make validate; echo "exit=$?"          # 預期 exit=0
bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh; echo "exit=$?"   # 預期 exit=0
```

- [ ] **Step 2: 驗收清單走查**（spec §8）：24 舊篇處置=14 active+10 archived；11 新篇各有 category frontmatter 與「本頁定位」；experiment-report 頁 as-of 齊；guard 指向新頁；ledger 可稽核。逐項寫進 PR 描述。
- [ ] **Step 3: 多視角 review 迴圈**——平行 dispatch Code Reviewer（TSX/JSON 改動）與 SRE persona（新監控/runbook 頁生產可用性）各掃一輪，triage 修正（writer 只改文字），再 `make validate`。
- [ ] **Step 4: Push + PR**

```bash
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push -u origin claude/ceph-content-restructure-dfa625
```

用輸出的 `pull/new/...` URL 開 PR（無 gh）。PR 描述：spec/plan 連結、驗收清單、archive 對應表、「使用者需 review spec 的 §4 對應表與 archive 名單」提醒。
