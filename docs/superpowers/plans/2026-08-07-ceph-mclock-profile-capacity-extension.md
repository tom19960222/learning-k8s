# Ceph mClock profile declared-capacity 敏感度延伸實驗 Implementation Plan

> **For agentic workers:** 每個 task 使用 fresh context 執行 `/implement`，以 `/tdd` 完成 red-green slice，最後執行 `/code-review`。真實 cluster mutation 只集中在 Task 9，不交給背景 subagent。

**Goal:** 在既有 Ceph mClock harness 上增加一條隔離、可稽核且安全回退的 capacity-sensitivity campaign，回答舊的低 declared capacity 是否遮住 profile gap，並以實際 evidence 產出人類可讀報告。

**Architecture:** 新增一個薄的 extension runner，重用既有 SSH、Ceph、fio、collection 與 replicate pipeline；將 extension schedule、state、ledger、signed verdict 與 reporting policy 收斂在一個 Python policy module。舊 63-cell campaign 保持相容，extension 使用獨立 results namespace 與 strict ownership，不沿用既有 stale-lock takeover 語意。

**Tech Stack:** bash 3.2、Python 3 標準庫、fake SSH/fixture tests、shellcheck、既有 Ceph mClock harness。

**Spec:** `docs/superpowers/specs/2026-08-07-ceph-mclock-profile-capacity-extension-design.md`

## GitHub Tickets

| Task | Issue | Blocked by |
|---|---|---|
| T1 | [#19](https://github.com/tom19960222/learning-k8s/issues/19) | None |
| T2 | [#20](https://github.com/tom19960222/learning-k8s/issues/20) | #19 |
| T3 | [#21](https://github.com/tom19960222/learning-k8s/issues/21) | #20 |
| T4 | [#22](https://github.com/tom19960222/learning-k8s/issues/22) | #21 |
| T5 | [#23](https://github.com/tom19960222/learning-k8s/issues/23) | #22 |
| T6 | [#24](https://github.com/tom19960222/learning-k8s/issues/24) | #23 |
| T7 | [#25](https://github.com/tom19960222/learning-k8s/issues/25) | #24 |
| T8 | [#26](https://github.com/tom19960222/learning-k8s/issues/26) | #25 |
| T9 | [#27](https://github.com/tom19960222/learning-k8s/issues/27) | #26 |
| T10 | [#28](https://github.com/tom19960222/learning-k8s/issues/28) | #27 |

## Global Constraints

- 所有 zh 內容使用台灣繁體中文；never-translate 技術名詞維持英文。
- 以既有 runner entrypoint 為最高測試 seam；外部行為由 fake SSH、環境變數與 artifact assertions 驗證。
- bash 3.2 相容，不使用 `mapfile`、nameref 或 associative arrays。
- stdout 只輸出機器行；log 與 progress 走 stderr。
- 所有 mutating entrypoint 保留 `--yes-really-inject` gate。
- Extension runner 必須顯式取得唯一且起始為空的 `RESULTS_DIR`；不得 fallback 到共用 results。
- 不讀取另一個 agent 的 active results，不搶鎖、不清鎖、不停止其 runner/fio，不操作其 worktree。
- 每個 task 先寫紅測試，再實作最小綠解；完成後跑相關測試與 `bash experiments/ceph-mclock-profiles/tests/run-tests.sh`。
- 修改 shell 後跑 `shellcheck lib/*.sh run/*.sh tests/*.sh`；整合 gate 跑 `make validate`。
- 真實 cluster fault injection 只在 Task 9、exclusive experiment window 成立後執行。
- 不 commit、不 push、不 teardown Azure，除非使用者另行要求。

## Task 1 — 建立隔離且可安全暫停的 extension campaign envelope

**Files:**

- Create: `experiments/ceph-mclock-profiles/run/capacity-extension.sh`
- Create: `experiments/ceph-mclock-profiles/lib/capacity_extension.py`
- Create: `experiments/ceph-mclock-profiles/tests/test-capacity-extension.sh`
- Modify: `experiments/ceph-mclock-profiles/tests/run-tests.sh`
- Modify as needed: `experiments/ceph-mclock-profiles/lib/pipeline.sh`, `lib/common.sh`

- [ ] Red: runner 缺 `--results`、路徑已存在、路徑落在 extension family 外、發現 foreign owner/runner/fio、exclusive preflight 不成立時全部拒絕且不修改 cluster。
- [ ] Red: strict ownership 不得沿用既有 stale takeover；ledger event 必須 append，amendment 不得覆寫歷史。
- [ ] Green: 提供 `init → preflight-wait|owned → paused` 的最小 state path與 local/remote owner proof。
- [ ] Green: 任一等待、錯誤或 signal 觸發 `balanced + capacity A` rollback attempt 並記錄是否驗證成功。
- [ ] Verify: no-op extension runner 在 fake seam 產生唯一 namespace、owner metadata、live ledger 與 immutable paused checkpoint。

## Task 2 — 以 dual-calibration audit 凍結 capacity treatments

**Files:**

- Modify: `run/capacity-extension.sh`, `lib/capacity_extension.py`, `lib/ceph.sh`, `lib/fio.sh`
- Modify: `tests/test-capacity-extension.sh`, `tests/test-ceph-qos.sh`, `tests/test-fio.sh`

- [ ] Red: 缺任何一顆 OSD 的三次 bench、缺 client ceiling round、超過 30 分鐘、單顆 median drift >15%、單顆 CoV >10%、client median drift >15% 或 client CoV >10% 時 audit 失敗且 fault count 為零。
- [ ] Red: audit 不得重啟 OSD；每次 manual bench 必須先 cache drop 並使用 startup-equivalent 4 KiB 參數。
- [ ] Green: 產生 complete audit artifact、capacity A exact vector、capacity B scaled vector、scale factor 與 fresh common target。
- [ ] Green: cluster median／cross-OSD CoV 只作描述性欄位，不得蓋掉 per-OSD failure。
- [ ] Verify: pass/fail/timeout 三條 end-to-end runner 路徑均留下 ledger、artifact 與安全 rollback proof。

## Task 3 — 完成一個安全的 common capacity-A fault execution

**Files:**

- Modify: `run/capacity-extension.sh`, `lib/capacity_extension.py`, `lib/pipeline.sh`, `lib/ceph.sh`, `lib/collect.sh`, `lib/verdict.py`
- Modify: `tests/test-capacity-extension.sh`, `tests/test-pipeline.sh`, `tests/test-collect.sh`, `tests/test-verdict.sh`

- [ ] Red: 驗證 `capacity A + high_client_ops` 的 profile/capacity/nine-QoS/skip-benchmark proof、60 秒 readiness、`ok-to-stop osd.5` 與 pre-fault capacity-bound label。
- [ ] Red: `fault_t0` 必須在 daemon stop 前 append；只有跨過 `fault_t0` 才消耗 fault budget。
- [ ] Green: 完成 osd.5 managed-out、30 分鐘 recovery cap、right-censor、coverage、fio p99、collect、aggregate、schema/DONE 與 final rollback。
- [ ] Green: 未完成 300 秒 fio segment 最多標記五分鐘 p99 interruption exposure；primary endpoints 完整時保留 partial，不把 latency 缺漏視為正常。
- [ ] Verify: complete、censored、partial、preflight rejection 與 rollback failure fixture 都產生正確外部狀態。

## Task 4 — 完成 common capacity 2×2 與 signed verdict

**Files:**

- Modify: `lib/capacity_extension.py`, `run/capacity-extension.sh`, `lib/verdict.py`
- Modify: `tests/test-capacity-extension.sh`, `tests/test-verdict.sh`

- [ ] Red: 固定初始 order，四個 cell 使用相同 offered load，capacity/profile proof 缺漏不得進 routing-ready。
- [ ] Red: client profile gap、recovery profile gap 與 `gap B - gap A` 保留正負號。
- [ ] Green: client 10 percentage-point threshold；recovery threshold 使用 `max(300s, four-cell recovery mean ×20%)`。
- [ ] Green: 產生 supported、refuted、mixed、endpoint-only、not-observed 與 censored-indeterminate fixtures；禁止 equivalent claim。
- [ ] Verify: common 2×2 end-to-end fake run 能輸出 machine-readable capacity-sensitivity verdict。

## Task 5 — 路由並執行完整 maximum-separation profile pair

**Files:**

- Modify: `lib/capacity_extension.py`, `run/capacity-extension.sh`
- Modify: `tests/test-capacity-extension.sh`

- [ ] Red: 任一 common cell partial/invalid 時禁止 routing；不得啟動單邊 extreme execution。
- [ ] Green: 依預註冊 client/recovery standardized scores、weaker-leg selection 與 tie-break 選 capacity。
- [ ] Green: extreme 使用不限速 4K 70/30，profile order 反轉該 capacity 的 common order，並標記 adaptive exploratory selection。
- [ ] Verify: A wins、B wins、雙 tie、common repair 與無法形成 pair 的 fixture 全部可重現。

## Task 6 — 將 paired rounds 有界延伸至 n=3

**Files:**

- Modify: `lib/capacity_extension.py`, `run/capacity-extension.sh`, `lib/pipeline.sh`
- Modify: `tests/test-capacity-extension.sh`, `tests/test-pipeline.sh`

- [ ] Red: n=2 完整反轉 n=1；n=3 schedule 在讀 endpoint 前由 campaign ID deterministic seed freeze，且保留 capacity blocks。
- [ ] Red: 每 cell 第四次 fault injection 不可能發生；complete/partial/post-fault invalid 計 budget，preflight rejection 不計。
- [ ] Green: common n=2 → extreme n=2 → common n=3 → extreme n=3 → common balanced A/B 的 paired-block state machine。
- [ ] Green: known-time admission 為 common 3h、extreme/balanced 1.5h；missing core 阻止 balanced，incomplete common 阻止 extreme。
- [ ] Green: `attempt-budget-exhausted`、planned completion 與 completed-with-gaps 正確收官。
- [ ] Verify: interruption/resume 不改變 frozen order、budget 或 paired-block eligibility。

## Task 7 — 產出 immutable checkpoints 與可讀報告 artifacts

**Files:**

- Modify: `lib/capacity_extension.py`, `run/capacity-extension.sh`
- Modify: `tests/test-capacity-extension.sh`

- [ ] Red: 17:30 與每次 paused 產生不同 timestamp checkpoint，不覆寫；active execution 不被報告中斷。
- [ ] Red: checkpoint 明列 completed/partial/active/not-started、cluster/treatment snapshot、missing segment 與 last trusted timestamp。
- [ ] Green: final report artifact 直接呈現 IOPS、retention percentage points、recovery seconds、combined/read/write/per-client/worst-client p99 milliseconds。
- [ ] Green: worst 30s rolling p99、duration above 2× baseline、missing-artifact appendix、relative raw paths 與 integrity manifest 齊備。
- [ ] Verify: raw data 留在 git-ignored namespace，report 不嵌入 raw JSON，也不把 p99 納入 verdict。

## Task 8 — 整合驗證 extension runner

**Files:**

- Modify as needed: extension implementation and existing regression tests
- Update: experiment README/runbook for the approved execution contract

- [ ] Run: `bash experiments/ceph-mclock-profiles/tests/run-tests.sh` → exit 0。
- [ ] Run: `shellcheck experiments/ceph-mclock-profiles/lib/*.sh experiments/ceph-mclock-profiles/run/*.sh experiments/ceph-mclock-profiles/tests/*.sh` → exit 0。
- [ ] Run: `make validate` → exit 0。
- [ ] Verify: existing legacy manifest/pipeline campaign tests remain green；extension 不能改變舊 default results 或 stale-lock behavior。
- [ ] Run `/code-review` against the implementation fixed point；Standards 與 Spec findings 全數處理或明確記錄。
- [ ] Produce offline-qualified evidence summary；此 task 不連 Azure、不注入 fault。

## Task 9 — 在 exclusive Azure window 執行完整 eligible campaign

**Files:**

- Write only: unique git-ignored campaign results namespace and timestamped reports
- Do not modify: another agent's worktree, results, owner state or workload

- [ ] Read-only preflight 確認另一個 agent/campaign 已停止、無 active runner/fio、cluster `final_clean`、profile/capacity known。
- [ ] 取得 strict campaign ownership；失敗只等待，不搶鎖、不清鎖、不停止對方程序。
- [ ] 執行 30 分鐘 dual-calibration audit；任一 gate 失敗即安全收官，不啟動 matrix。
- [ ] Audit 通過後執行 basic screening；17:30 產 checkpoint，不為 checkpoint 中斷 active execution。
- [ ] 在 block-admission、安全與 hard deadline 規則下繼續所有 eligible paired blocks，直到 planned completion、completed-with-gaps、paused 或人工終止。
- [ ] 每次 exit 驗證 `balanced + capacity A`、八顆 OSD 狀態與 `final_clean`；無證據不得宣稱安全停止。

## Task 10 — 綜合 capacity-sensitivity 最終報告

**Files:**

- Create: final standalone experiment report under the Ceph mClock experiment area
- Read only: campaign raw results and accepted ADR/spec artifacts

- [ ] 正文先回答原假設為 supported、refuted、mixed、not observed 或 censored-indeterminate。
- [ ] 分別呈現 common 與 maximum-separation、capacity A/B 證據邊界、client/recovery signed effects 及 p99 milliseconds。
- [ ] 明列 adaptive selection、n、right-censor、pre-fault capacity-bound、partial/invalid/not-started、last trusted timestamp 與所有 missing artifacts。
- [ ] 不宣稱 21,500、6k、raw NVMe 或 client ceiling 是唯一正確 capacity；把 sustained OSD-path calibration 留作後續研究。
- [ ] 依 manager-facing report gate 做獨立 review，直到結論、證據路徑與限制一致。

## Dependency Frontier

`T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 → T10`

目前只有 T1 可立即開始。每張 ticket 完成並關閉後，下一張才進 frontier。
