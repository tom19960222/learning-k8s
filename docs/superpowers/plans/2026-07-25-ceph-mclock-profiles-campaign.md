# ceph-mclock-profiles Campaign + Synthesis Plan（Phase 3–5）— v1

> **For agentic workers:** REQUIRED SUB-SKILL: Phase 3–4 用 `skills/researching-system-behavior/SKILL.md` 的 Falsify 迴圈；Phase 5 用 `skills/writing-experiment-reports/SKILL.md`。步驟用 checkbox（`- [ ]`）追蹤。
> **這份 plan 是 Phase 3 開跑 gate 的前置交付物**（harness plan Task 16），不是事後補的紀錄。真機開跑前它必須存在且被核可。

**Goal:** 執行 spec Phase 3（S0/S1）、Phase 4（S2/S3）的真機 campaign，並完成 Phase 5（Synthesize）的完整報告。

**交付語言：** 本 plan 完成 = spec §11 驗收標準 1–5 全數達成、Azure RG 已刪除、報告過 `writing-experiment-reports` 的主管 persona review gate。

**Spec:** `docs/superpowers/specs/2026-07-24-ceph-mclock-profiles-azure-design.md`（rev 8）
**Harness plan:** `docs/superpowers/plans/2026-07-24-ceph-mclock-profiles-harness.md`（v4.5，Phase 1–2 已完成）
**Runbook（執行時的操作手冊）:** `experiments/ceph-mclock-profiles/README.md`
**假說 backlog:** `experiments/ceph-mclock-profiles/HYPOTHESES.md`

---

## Global Constraints

- **README 是操作 SoT**：本 plan 只定義「做什麼、什麼時候停、誰裁決」；「怎麼下指令、機器行長什麼樣、gate 怎麼放行」一律引 README 對應章節，**不在此重述**（避免兩份文件漂移）。
- **停佇列不停機**：任何 gate / 故障 / 裁決期間 15 台 VM 保持 allocated。怠轉 ≈ $8/hr、最壞 12h ≈ $100，是明示接受的 tradeoff。**嚴禁 deallocate**（README §5、§6）。
- **破壞性驗證自己控**：改真叢集的動作（人工 remediation、operator override、手動 unhalt）由主控 session 直接執行、每步可回退，**不丟給無法中斷的背景 subagent**。
- **每個人工 gate 的裁決都要留痕**：能落 amendments journal 的就落 journal（`manifest.py amend`），不能的就寫進 campaign log 並在 Phase 5 的 incidents 一節具名。
- **prediction 先行**：每個 execution 的 prediction 在 bundle 內 freeze（sha256 不可變）。Phase 5 寫報告時**只能引用 freeze 過的 prediction**，不得事後補寫。
- **zero-fabrication**：報告裡每個數字都要能指回 `results/` 的具體檔案；每個機制敘述都要有 v19.2.2 的 source 錨點（`git -C /Users/ikaros/Documents/code/learning-k8s/ceph show v19.2.2:<path>`）。
- 家規：台灣繁中、never-translate 清單保留英文、bash 3.2、`tests/gate.sh` 綠才 commit、`git commit --no-gpg-sign`。

---

## Phase 3 前置：Task 0（開跑前必補）

> harness Phase 1–2 收官時掃出三個「測試綠但真機會擋路」的缺口（README §1.7）。**Task 0 未完成不得進 Task 1。**

### Task 0.1: 實作 profile 切換

**Files:** `experiments/ceph-mclock-profiles/lib/ceph.sh`、`lib/pipeline.sh`、`tests/test-ceph-qos.sh`、`tests/test-pipeline.sh`

**問題**：整個 harness 沒有任何地方執行 `ceph config set osd osd_mclock_profile`。`ceph_qos_gate <profile>` 只**驗證**。第一個非 `balanced` 的 cell 會在 preflight 卡到 `QOS_CONVERGE_SECS` 逾時，佇列直接停。

**設計約束**：
- `osd_mclock_profile` 是 runtime-changeable（`ceph config set osd` 即生效、不需重啟），但**九個衍生參數不寫進 mon config store**（`set_val_default`，H-018）——所以「設 profile」與「qos gate 的來源反向斷言」不衝突：`FORBIDDEN_IN_MON_STORE` 不含 `osd_mclock_profile`。
- 但 `fio_calibrate` 要求「當下 profile = balanced」且判定方式是 `ceph config get osd osd_mclock_profile`。**校準必須在任何 profile 被 set 之前完成**（calibrate 的步驟順序已保證這點：`calibrate-4k`/`calibrate-seq` 在 `manifest` 之前，而 profile 切換發生在 execution preflight）。
- 切換後必須等**八顆同時**收斂才算數——這正是既有 `ceph_qos_gate` 的職責，不要另寫一套。

- [ ] Step 1: 測試先行——`ceph_set_profile <profile>`：(a) 三個合法 profile 之外 die；(b) 已經是目標 profile 時不重下指令（冪等）；(c) 下 `ceph config set osd osd_mclock_profile <p>` 的 argv 逐字斷言；(d) pipeline preflight 的**順序斷言**：`ceph_set_profile` 必須在 `ceph_qos_gate` **之前**呼叫，且 gate 仍是唯一的通過判準。
- [ ] Step 2: 實作 `lib/ceph.sh::ceph_set_profile`，在 `lib/pipeline.sh` 的 preflight 接上（`_PIPE_PROFILE` 已存在）。
- [ ] Step 3: 決定 campaign 收尾是否要把 `osd_mclock_profile` 從 mon store 移除（對稱回退）。**裁決記入本 plan**：建議由 `ceph_campaign_unflags` 一併 `ceph config rm osd osd_mclock_profile`，理由是 campaign flags 的對稱性原則（設什麼就回退什麼），且 teardown 前的最後一次 `ceph config dump` 乾淨才證得了 cleanup stack 對稱。
- [ ] Step 4: `tests/gate.sh` 綠 → commit。

### Task 0.2: descope 的佇列端效果

**Files:** `lib/manifest.py`、`tests/test-manifest.sh`

**問題**：`results/descope.json` 只被 `verdict.py audit` 讀，`manifest.py next` / `view` 不吃它。目前只能靠 `needs-human` amend 擋佇列（README §7.3 的兩步操作），語意錯配（descope 是成本決策，不是「需要人處理」）。

- [ ] Step 1: 測試先行——`descope.json` 列出的 cell 在 `view` 的 status 標 `descoped`（與 `needs-human` 分開的第五種狀態）、`next` 跳過、`counts` 有獨立欄位。
- [ ] Step 2: 實作（`descope.json` 讀取集中在 `expand_schedule`，與 amendments 同一個 merge 視圖）。
- [ ] Step 3: 更新 README §7.3 的操作步驟為單步。
- [ ] Step 4: gate 綠 → commit。

> 若時間壓力大，此 task 可降為「維持兩步操作 + README 已寫清楚」，但**必須在 Phase 3 開跑前明確裁決**（做或不做），不得懸而未決。

### Task 0.3: `halted` 的解除路徑

**Files:** `lib/pipeline.sh`、`tests/test-pipeline.sh`

**問題**：`results/watchdog-state.json` 的 `halted:true` 只寫不清。人工排除問題後只能手改 JSON（README §4.7）。72h campaign 期間預期會用到不只一次，手改 JSON 容易漏掉 `drift_streak` / `counts`。

- [ ] Step 1: 測試先行——`_pipeline_py state <path> unhalt <reason>`：清 `halted`/`halt_reason`、**保留** trigger counts（除非明示 `--clear-counts`）、寫 `unhalted_at` + 理由（留痕，不可無聲清除）；`watchdog_halted` 隨之回 false。
- [ ] Step 2: 實作，並提供 `run/` 層的薄入口或在 README 給定案指令。
- [ ] Step 3: gate 綠 → commit。

### Task 0.4: 開跑前的最後檢查

- [ ] `bash experiments/ceph-mclock-profiles/tests/gate.sh` → `gate: PASS`
- [ ] README §1.1–1.6 全部打勾（使用者刪舊 RG、IaC 交付、verify-provision PASS、HYPOTHESES gate、bastion 前置、harness gate）
- [ ] 本 plan 已過使用者核可（= spec Phase 3 的 gate「說 go」）

---

## Phase 3 — S0/S1：校準與穩態（negative control）

> spec §7：S0 ≈ 6–8h、S1 ≈ 15–17h（累計 ~21–25h）。
> 操作指令一律照 README §3.2 分段執行。

### Task 1: S0 — provision 驗收與校準

**產物：** `results/calibration.json`、`capacity-lock.json`、`capacity-provenance.json`、`manifest.json`（63/147）、活著的 campaign 級 collector

- [ ] Step 1: `azure/verify-provision.sh` PASS（含 az preflight = watchdog 2b 的憑證預檢）。FAIL 一律退回 IaC，**不手動補**。
- [ ] Step 2: `caffeinate -dimsu bash run/calibrate.sh --yes-really-inject`。順序即規格（README §3.2），逐步驟 marker 落在 `results/calibrate/`。
- [ ] Step 3: **raw NVMe 基線 ×8 的 gate**（在 bootstrap 之前）：8 份 per-node JSON 齊備，且跨 node 的 4K randwrite IOPS 離散度先看一眼——這是 capacity 決策表 `raw_fio_iops` 的來源，也是 §Task 2 CoV gate 的對照組。
- [ ] Step 4: **capacity 決策表 gate**：8 顆齊備、五狀態各自出口正確、跨 8 顆 CoV ≤ 0.20。`capacity-dispersion-high` → README §4.4 remediation；`capacity-decide: HUMAN-NEEDED` → README §4.5。**任何 operator override 都要在此步記下 provenance**（誰 / 何時 / 依據 / 理由），Phase 5 的 limitations 要引用。
- [ ] Step 5: **reboot canary gate**：`no-rebench: PASS osd.<N>`。判定必須是 current-boot 合取證據（boot ID 變更 + unit-scoped `journalctl -b -u ceph-<fsid>@osd.N` 無 bench log + effective `skip_benchmark=true` + capacity 值未變 + 至少一條該次 boot 的已知存在 log 當 positive control）。這同時驗證了 watchdog 第二層（reboot 自救）的前提。
- [ ] Step 6: **network baseline gate**：`net-baseline: PASS <server> <worst_gbps>`。低於 `CALIB_NET_MIN_GBPS=1.0` 即 die；低於 `CALIB_NET_WARN_GBPS=5.0` 只警告並記 covariate（README §9）。worst 值進 Phase 5 的 premises 一節。
- [ ] Step 7: **`fio_smoke_real` gate**（parser 對真機輸出的一次性校正）：`fio-smoke-real: PASS ...`。失敗代表本機 fio 版本的 log 格式與 parser 假設不符——**修 parser，不修 golden**（README §10.3）。修完要回頭跑 `tests/gate.sh`。
- [ ] Step 8: **校準 gate**：`fio-calibrate: PASS 4k <ceiling>` 與 `PASS seq <ceiling>`。人工看兩件事：(a) 3 輪無限速 ceiling 的離散度（差太多代表環境本身不穩，先查再往下）；(b) seq 的 ceiling 是否已撞 NIC 天花板（對照 Step 6 的 iperf3 值）——若是，Phase 5 所有 seq 結論都要標「NIC-bound 環境下的結果」。
- [ ] Step 9: `manifest.py generate --assert` → 63 cells / 147 executions；`bg_collect_start` 起來 → `calibrate: PASS`。
- [ ] Step 10: 記錄 S0 實際耗時與此時的累計成本，對照 spec §7 的 6–8h 估算。偏差 > 50% 就在此重估整場時程並通知使用者。

### Task 2: S1 — 穩態 72 executions（negative control）

**預測（HYPOTHESES.md §A）**：三個 profile 的 client `lim` 都是 max，無 recovery 競爭時 client 可借滿 capacity → **穩態組預期 indistinguishable**。這是 negative control：如果穩態就分得出 profile，那量測系統或環境有系統性偏差，後面的故障結論全部不可信。

- [ ] Step 1: `bash run/steady.sh --yes-really-inject` → 停在 **first-cell gate**（exit 10）。
- [ ] Step 2: **first-cell 人工檢查**（README §4.1）：qos.json 八顆收斂且 mon store 乾淨、prediction freeze、fio 三個 log 逐秒連續、coverage-proof 無 taint、achieved 供給對得上 calibration.json。
      **這是整場 campaign 唯一一次「什麼都還沒投入」的檢查點**——這裡放過的問題會複製到 147 個 bundle。
- [ ] Step 3: `bash run/steady.sh --yes-really-inject --resume` 跑完 72 executions。期間每天至少看一次 `queue_progress` 與 log 的 `pipeline: DONE/TAINT/ABORT` 比例。
- [ ] Step 4: **margins gate**：`margins: OK <adequate>/4 <path>`。若出現 `margins: UNDERPOWERED <endpoint> noise=<x> production=<y>`，代表該 endpoint 的**噪音大於預註冊的生產門檻**——`indistinguishable` 在該 endpoint 上只能宣告「靈敏度不足」，不能宣告「等效」。
      **裁決點**：(a) 接受並在 Phase 5 明確標註該 endpoint 的結論等級降級；(b) 提高穩態 n（`extra-replicates` amend）縮小 noise margin；(c) 找出噪音來源（鄰居效應？client 端？）先修再說。裁決記入 journal。
- [ ] Step 5: **negative control 判讀**（不阻塞佇列，但要在此刻做，不要拖到 Phase 5）：跑一次 `verdict.py verdict --group <穩態 group>` 看三 profile 是否如預期 indistinguishable。
      - 如預期 → 量測系統可信，往 Phase 4 走。
      - **不如預期**（穩態就分得出 profile）→ **停下來**。可能成因：profile 沒真的切換（Task 0.1 的實作有問題）、Latin square 沒生效、某台 client 或 OSD 有系統性差異、校準漂移。查清楚再進 Phase 4——這是全 campaign 最重要的一次 falsification 機會。
- [ ] Step 6: 記錄 S1 實際耗時與累計成本；重估 S2 時程。

---

## Phase 4 — S2/S3：故障、chaos 與收資料

> spec §7：S2 ≈ 63–70h 累計、S3 ≈ 72–80h 累計。這是全 campaign 最長也最容易出事的一段。

### Task 3: S2a — 故障 pilot（4 組）與 cap 推導

**目的**：用「預期最慢組合」（最高壓 × `high_client_ops`；node-isolation 退化為中壓 × `high_client_ops`）反偏誤地推導每個故障型的 `measurement_cap`，避免其他 cells 被系統性 censor。

- [ ] Step 1: `bash run/faults.sh --yes-really-inject --pilot` → 四個 pilot 跑完 → `schedule-estimate` → 停在 **pilot gate**（exit 10）或 **PILOT-CENSORED**（exit 11）。
- [ ] Step 2: **PILOT-CENSORED 分支**（README §4.3）：pilot 自己撞 cap → recovery 值只是下界，**禁止**餵進 `2×` 公式。二選一（cap×2 重跑 pilot / 人工指定 cap），**必須先落 `cap-update` amendment 才能 `--resume`**——`--resume` 單獨不足以繞過這一格。
- [ ] Step 3: **pilot gate 人工檢查**（README §4.2）：`results/schedule-estimate.json` 的 `recommended_cap = max(2700, 2×pilot_recovery_time)` 是否合理；`schedule-estimate: OK <n>h` 的總時程是否可接受。
      **裁決點**：估算總時程若 > 96h，此刻就要決定是否預先啟用 descope 階梯（README §7.3），而不是等成本撞天花板才動。
- [ ] Step 4: 記錄四個故障型的 pilot recovery 時間——這是 Phase 5「故障規模 vs 恢復時間」那張表的第一批資料點，也是 H-023（rack-loss × 極端壓 × `high_client_ops` 最慢）的第一次檢驗。
- [ ] Step 5: `bash run/faults.sh --yes-really-inject --pilot --resume` → `faults: PILOT-PASS`。

### Task 4: S2b — 故障全佇列（72 executions）

- [ ] Step 1: 確認前置：`results/margins.json` 存在（Task 2 Step 4 產出）→ `faults: MARGINS-OK <path>`。
- [ ] Step 2: `caffeinate -dimsu bash run/faults.sh --yes-really-inject`，`tee` 到 campaign log。
- [ ] Step 3: **每 12h 回報**（腳本自動印，README §7.1）：`faults: REPORT done=<n>/72 elapsed_h=<h> cost_usd=<c> az=<state>`。人要做的三件事：
      - `az=stale|missing` → **立刻**去 bastion 重新 `az login`（watchdog 2b 的救援憑證，hour 60+ 失效就救不回來）。
      - `budget-warning` → 通知使用者，評估 descope。
      - 進度顯著落後估算（例如 12h 內完成數不到預期的一半）→ 查是不是有 cell 反覆 taint。
- [ ] Step 4: **人工 gate 的隨到隨處理**（都在 README §4）：
      - `baseline-drift`：單次記 covariate；**連續 3 次停佇列** → §4.6 的三分支決策樹（單向漂移 → recalibrate 並把 campaign 切成兩個校準期；抖動 → 接受並重算 noise margin；單一 client → 重做該 client 的 unmap/map + smoke）。
      - `watchdog: HUMAN-NEEDED` → §4.7；修完用 Task 0.3 的 unhalt 解除，**嚴禁 deallocate**。
      - `taint-budget: NEEDS-HUMAN` → §4.8；佇列會跳過該 replicate 續跑，不急，但收官前要處理根因並決定是否移除 journal 那行重跑。
      - `need-more-n` 自動升 n（CoV 超標，上限 5）與**雙 censored 自救**（同 cell 兩 replicate 皆 censored → 自動 `rescue-replicate` cap×2，每 cell 一次為限）都是自動的，只需在 log 確認有發生。
- [ ] Step 5: 每完成一個故障型（flapping / osd-down / node-isolation / rack-isolation / seq-contention）就跑一次 `verdict.py verdict --group <group>` 看趨勢。
      **中途 falsification 的價值**：如果某個故障型三 profile 全部 indistinguishable 且 margin 充足（= 真等效，非靈敏度不足），那是 H-001（reservation 恆和 1.0 → weight 不參與排序）的直接證據，Phase 5 的敘事主軸會隨之改變。不要等到全部跑完才發現。
- [ ] Step 6: `faults: PASS done=72/72`。記錄 S2 實際耗時與累計成本。

### Task 5: S3 — chaos 與補跑

- [ ] Step 1: `bash run/chaos.sh --yes-really-inject`（3 executions，同 seed 跨 profile；入口會斷言 seed / duration 跨 profile 一致）。
      **首跑要有人在旁邊**：chaos 的 min_size 不變條件若失效，PG inactive → krbd 卡 kernel D-state → fio kill 不掉、`rbd unmap` 必敗、watchdog 救不回（README §10.8）。
- [ ] Step 2: 選配（時間與預算允許才做，spec §7 S3）：
      - auto-out 確認組 ×2（OSD down × 中壓 × `balanced` / `high_client_ops`，等真 600s + grace）——驗證「managed-out ≠ 生產再加 600s」這個語意差（spec §5）。
      - gray network failure（`tc netem` 1–5% packet loss，H-021）——與硬故障方向可能相反的假說。
      兩者都是 HYPOTHESES backlog 的項目，做了就進報告、不做就在 open questions 具名。
- [ ] Step 3: 補跑清單：把 S1/S2 期間標 tainted 或明顯異常（Azure 抖動輪）的 replicate 重跑。
- [ ] Step 4: **收尾**（README §8.1）：補齊 stage marker → `bash run/all.sh --yes-really-inject --resume` → reconcile → unflags + tuning restore → 停 collector → `DATASET-SEALED` → `verdict.py audit` → `campaign: DONE`（或 `AUDIT-FAIL`，按 README §8.3 判斷是否為「有記錄的缺件」）。
- [ ] Step 5: **teardown checklist**（README §8.2）——**bundle audit 過才准刪 RG**。特別強調兩條：
      - `results/` 打包備份出 bastion（`tar --no-xattrs`）——刪 RG 之後叢集端沒有任何備份。
      - `EVIDENCE-SUMMARY-<date>.md` commit 進 git（`results/` 是 git-ignored，這份 md 是唯一進 git 的索引）。
- [ ] Step 6: 通知 IaC agent 刪整個 RG；取實際費用數字（Cost Management）對照估算，差異記進報告。

---

## Phase 5 — Synthesize：完整報告

> 用 `skills/writing-experiment-reports/SKILL.md`。**核心原則：讀者只有這一份報告。**
> 交付位置：`experiments/ceph-mclock-profiles/REPORT-<date>.md`（進 git）。

### Task 6: 資料收斂與 evidence ledger

- [ ] Step 1: 從 `results/` 產出跨 cell 的彙總表：每個 cell 的四個 primary endpoint（p99 degradation ratio、max IO stall duration、recovery bytes/s、time-to-recovery-complete）+ n + censored 數 + verdict 三態 + `indistinguishable` 的子型（等效 / 靈敏度不足）。
- [ ] Step 2: **bookkeeping 必須對帳**：planned（147 + extra）= executed + descoped + needs-human。對不上就先查，不要寫報告。對帳結果直接引 `EVIDENCE-SUMMARY-<date>.md`。
- [ ] Step 3: 回填 `HYPOTHESES.md`：每條 H-xxx 標 confirmed / violated / indistinguishable / 未觀測，附證據指標（cell + bundle 路徑）。**所有 P0/P1 條目必須離開 `proposed`**（spec §11.5）。
- [ ] Step 4: **被推翻的預測獨立成清單**——這是報告最高價值的內容，先挑出來，不要混進結果敘述裡。

### Task 7: 報告主體（五欄格式）

- [ ] Step 1: **§0 premises**（是一個 section，不是散落各處）：
      - SUT spec：15 台 VM 的 SKU / vCPU / RAM / NVMe / kernel / Ceph v19.2.2 / fio 版本
      - 拓撲：4 synthetic CRUSH racks × 2 nodes、replica 3、pool / pg_num / autoscaler off
      - 環境常數：campaign flags（noscrub / nodeep-scrub / balancer off / `mon_osd_adjust_heartbeat_grace=false` / `mon_osd_adjust_down_out_interval=false`）、鎖定的 capacity 與其 provenance、seq bandwidth 固定 1200 MiB/s
      - load matrix：每個形態 × 壓力 × 重複次數（穩態 n=3 / 故障 n=2 / chaos n=1，含升 n 與 rescue）
      - 判準門檻：兩層 clean 判準、stall / brownout 定義、**預註冊的 production margin 四個絕對門檻**
      - credibility defenses：noise margin 來源、Latin square counterbalance、within-replicate 基線、network baseline、reboot canary、負控制（穩態）結果
      - **術語 primer**：mClock / dmclock 的 res-wgt-lim 三段式、mClock 的 class 分類、backfill vs recovery、managed-out —— 2–3 行，放在第一次使用之前
- [ ] Step 2: **planning overview 表**（涵蓋每個 planned 實驗，含沒跑的與理由）：一列一個實驗，欄位 = 調整的參數（值域，預設標星）/ 為什麼測 / 預測 / 結果（✅ 命中 ❌ 推翻 ➖ 無法區分）。
- [ ] Step 3: **逐實驗五欄詳述**，章節依實驗目的分組（穩態取捨曲線 / 故障注入 / chaos 極限），五欄固定：
      1. 調整的參數
      2. 為什麼測
      3. **預測（跑之前寫的）** —— 引 freeze 過的 prediction，與結果**分開**
      4. 結果（before → after 數值 + 倍率，例：`p99 7.6→55.8ms（×7.4）`）
      5. 建議
- [ ] Step 4: **效果量一律是數字**。平均掩蓋故事時明說，並報出會顯示故事的那個百分位。
- [ ] Step 5: **每個結論的適用條件寫進同一句**。本實驗必須進句子的條件至少有：
      - 「managed-out backfill」語意（≠ 生產的 auto-out，且 rack 場景生產上根本不會 auto-out——`mon_osd_down_out_subtree_limit=rack`，H-016）
      - 「Ceph 預設 cost model 下」（seq bandwidth 從不量測，固定 1200 MiB/s，H-014）
      - 「synthetic CRUSH-rack」不可外推為 Azure 實體 rack correlated failure
      - seq 形態若 NIC-bound 要標明
      - 極端壓是 closed-loop，tail latency 不可與固定速率組直接比較
- [ ] Step 6: **參數建議總表**（收口）：參數 / 建議值 / 證據（實驗 id）/ 效果量 / 可變更性（runtime / restart / rebuild）。建議必須可執行——給值與條件，不是「應持續監控」。
- [ ] Step 7: **「何時選哪個 profile」裁決樹**。輸入條件用生產語言（例：「client IO 的 p99 是 SLO 且故障期間不得超過 X」「恢復時間視窗有硬上限」「叢集常態負載超過 capacity 的 Y%」），輸出是 profile + 需要一併設定的參數 + 該選擇的已知代價。裁決樹的每個分支都要指回一個實驗 id。
- [ ] Step 8: **誠實區**（不要刪，這是可信度的來源）：
      - limitations：哪些是環境限定（Azure 單 NIC、L8s_v3 的 NVMe、4 rack 拓撲）vs 機制層級（reservation 恆和 1.0、replica 寫繞過 mClock、cost model 刻度）
      - incidents：campaign 期間的 watchdog 事件、operator override、descope、手動 unhalt、移除過的 journal 行——全部具名
      - open questions：沒做的選配（auto-out 確認組 / gray failure）、未觀測的假說

### Task 8: Review gate（必要，不可跳過）

- [ ] Step 1: 開一個**主管 persona 的 reviewer subagent**，**只給它報告**（不給 spec / plan / results）。要它對七個讀者問題逐項評 PASS / WEAK / FAIL 並附引用位置，外加：未定義行話搜捕、內部矛盾、過度外推。
      七問：(1) 前提（系統 / 環境 / 判準）(2) 計畫了哪些實驗、為什麼 (3) 每個實驗調了什麼參數、值域 (4) 事前預測是什麼 (5) 發生了什麼、效果量多大 (6) 每個參數的具體建議 (7) 總結論與下一步。
- [ ] Step 2: 修 → 用**同一個 reviewer** 再 review，iterate 到 ACCEPT。
- [ ] Step 3: **reviewer 找到的內容錯誤**（不只是文字風格）必須**回港到所有做同樣宣稱的 artifact**：`HYPOTHESES.md`、spec、README、以及之後的網站 MDX。
- [ ] Step 4: 補一輪跨模型 review（codex，省 rate limit 的用法見 CLAUDE.md）作為第二意見。verdict 在輸出最後一個 `codex` 區塊。

### Task 9: 收官與整合

- [ ] Step 1: `EVIDENCE-SUMMARY-<date>.md` + `REPORT-<date>.md` + 回填後的 `HYPOTHESES.md` 一起 commit（`--no-gpg-sign`）。
- [ ] Step 2: **spec §11 驗收標準逐條核對**：
      1. `tests/run-tests.sh` 全綠 + shellcheck 0 + `make validate` exit 0
      2. 63 cells / 147 replicate sub-bundles（±descope 記錄）齊備，EVIDENCE-SUMMARY 進 git
      3. 報告落地（三 profile 參數對照 + cost model 機制含 source 錨點、壓力取捨曲線、故障 + chaos 對照、managed-out 語意獨立成節、參數建議總表 + 裁決樹）
      4. Azure RG 已刪除、費用總結回報（≤ US$1000）
      5. HYPOTHESES.md 所有 P0/P1 離開 proposed
- [ ] Step 3: 決定是否把成果轉成網站 feature page（`next-site/content/ceph/features/`）。**若做**，走 `skills/source-first-topic-page/SKILL.md`，並注意：報告是給沒參與的人看的完整文件，feature page 是學習素材，兩者的敘事密度不同，不要直接貼。
- [ ] Step 4: `make validate` exit 0 → push。回報使用者：campaign 完成、總費用、頭牌發現三條、以及 HYPOTHESES 中被推翻的預測清單。

---

## 時程與成本追蹤表（執行時逐列回填）

| Stage | 內容 | 估算累計 wall-clock | 實際累計 | 估算成本 | 實際成本 | 備註 |
|---|---|---|---|---|---|---|
| Task 0 | 開跑前補實作（不計費，本機） | — | | $0 | | profile 切換是 blocker |
| S0 | verify → calibrate（部署 / capacity / canary / 校準） | ~6–8h | | ~$64 | | |
| S1 | 穩態 72 executions + margins | ~15–17h | | ~$136 | | negative control |
| S2a | 故障 pilot ×4 + cap 推導 | ~20–24h | | ~$192 | | PILOT-CENSORED 風險 |
| S2b | 故障全佇列 72 executions | ~63–70h | | ~$560 | | 最長、最容易出事 |
| S3 | chaos 3 + 選配 + 補跑 + 收尾 | ~72–80h | | ~$640 | | |
| Phase 5 | 報告（RG 已刪，不計費） | — | | $0 | | |

天花板 US$1000。跨 96h 通知使用者一聲，**不停機、繼續跑到完**（使用者裁示）。

---

## 風險登記（Phase 3–5 專屬，spec §10 之外的執行面風險）

| 風險 | 徵兆 | 緩解 | 觸發後的動作 |
|---|---|---|---|
| profile 切換未實作 | 第一個非 balanced cell 的 qos gate 逾時 | Task 0.1 | 佇列停 → 補實作 → 重跑該 execution |
| 穩態不是 negative control | 穩態就分得出 profile | Task 2 Step 5 的中途判讀 | **停下來查**，不進 Phase 4 |
| pilot 全部 censored | 四個故障型都 exit 11 | cap×2 重跑 pilot | 若 rack 型連 cap×2 都撞，考慮降低填充量或接受該型只有下界 |
| bastion 睡著 / 換 IP | ssh 全斷、watchdog 誤判成 node 失聯 | README §1.5 前置檢查 | reconcile 會清殘留；受影響 replicate 標 taint 重跑 |
| az 憑證 hour 60+ 失效 | `faults: AZ-LOGIN-STALE` | 12h 回報的唯讀檢查 | 立刻重新 `az login`；未修復期間 watchdog 2b 不可用，等於少一層自救 |
| 校準漂移（72h） | 連續 3 次 baseline-drift | within-replicate 基線當主要分母 | recalibrate 並把 campaign 切成兩個校準期，跨段絕對速率不可比 |
| 成本超標 | `budget-warning` | descope 階梯 ①②③ | 啟用前通知使用者，descope 決策落 journal + descope.json |
| 報告過度外推 | reviewer 標 FAIL | Task 8 的主管 persona gate | 條件寫進句子本身，回港到所有 artifact |
