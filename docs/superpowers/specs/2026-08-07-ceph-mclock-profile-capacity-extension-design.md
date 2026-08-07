# Ceph mClock profile declared-capacity 敏感度延伸實驗 — 設計 spec

> 日期：2026-08-07
>
> 狀態：已完成 grill 並取得 shared understanding
>
> 範圍：實驗 harness 延伸、執行契約與報告；不包含本 spec 撰寫期間的 Azure cluster 操作

## Problem Statement

前一輪 Ceph mClock profile 實驗沒有清楚觀察到 `high_client_ops`、`balanced` 與 `high_recovery_ops` 的差異。當時每顆 OSD 採用 Ceph OSD startup bench 接受的約 6,057–6,646 IOPS 作為 declared capacity；同一批 NVMe 裝置在 raw fio 約為 276k–304k IOPS，cluster client ceiling 則約為 63.6k aggregate IOPS。三者量測的是不同 datapath，不能互相直接取代，但巨大的數值差距使人無法排除 capacity scale 已影響 mClock 仲裁與前一輪結論。

原始問題不是「把 raw NVMe IOPS 寫進 mClock 是否會更快」，而是：舊 campaign 使用的低 declared capacity，是否讓 profile gap 變小，以致看不出 application client 保護與 recovery 速度的取捨？也必須容許實驗指出相反結果：低 declared capacity 可能讓每筆 IO 的 scheduler cost 更高，反而提早或放大 profile 仲裁。

可用的首要實驗時間約六小時，2026-08-07 17:30（Asia/Taipei）是 report checkpoint 而不是 campaign stop。若沒有明確 hard deadline、exclusive experiment window 持續成立且 cluster 安全，實驗可繼續到預註冊上限；任何不完整資料都必須持續保存，不能等到最後才補紀錄。

Application 對 latency 敏感，因此 p99 必須完整收集並直接以毫秒呈現。不過目前沒有正式 SLO，p99 不得被臨時升格為實驗成功或失敗條件。

另一個 agent 可能仍在同一 Azure lab 執行工作。本實驗不得讀取或採用它的 active 結果，不得共用 results state，也不得停止、清鎖或改動它的 workload。新的 calibration 與 fault injection 只能在 exclusive experiment window 成立後開始。

## Solution

建立一個 capacity-sensitivity screening campaign，在相同 Azure lab、固定 OSD fault、固定 workload 與相同 Ceph mClock profile 參數下，只改變 declared capacity scale：

- Capacity A 重現舊 campaign 實際鎖定的 per-OSD startup bench 向量。
- Capacity B 保留 A 的 per-OSD 相對比例並等比放大，使中位數為 Ceph SSD 預設 21,500 IOPS。
- Raw NVMe throughput 與 fresh client ceiling 只作不同 datapath 的診斷與 workload 參考，不直接寫入 declared capacity。

Campaign 先在 `balanced + capacity A` 下執行最多三十分鐘的 dual-calibration audit，逐顆重驗 OSD startup bench 並重跑三次 client ceiling。Audit 通過後，common scenario 使用 fresh client ceiling 中位數的 50% 作固定 offered load；maximum-separation scenario 使用不限速 4K 70/30 workload。

基本 screening 先完成 common capacity A/B × `high_client_ops`／`high_recovery_ops` 的 2×2，再依預註冊 routing score 選一個 capacity 執行 maximum-separation profile pair。若時間與安全條件允許，按 paired、counterbalanced rounds 把核心 cell 擴充到每個最多三次 fault injection，最後才補 common `balanced` capacity A/B reference。

裁決使用 signed difference-in-differences：先計算每個 capacity 的 profile gap，再計算 `gap B − gap A`。正向 signal 支持較高 declared capacity 放大 profile 分離，負向 signal 反駁原方向並顯示低 declared capacity 放大差異；client 與 recovery 不同向則報告 mixed capacity sensitivity。Client IOPS retention 與 recovery time 是 verdict endpoints，p99 是必要但描述性的 application latency observation。

整個 campaign 由單一 runner state machine 管理 audit、paired-block admission、attempt、rollback、checkpoint 與 terminal state。所有 evidence 即時 append 到 live evidence ledger，raw data 留在唯一且起始為空的 campaign results namespace。正常結束、attempt budget 用完、人工終止或安全 pause 都必須保留可追溯狀態並產生人類可讀報告。

## User Stories

1. As an experiment owner, I want to compare capacity A and capacity B under the same workload, so that I can isolate declared-capacity sensitivity from workload changes.
2. As an experiment owner, I want capacity A to reproduce the old per-OSD vector exactly, so that the extension remains comparable with the prior campaign configuration.
3. As an experiment owner, I want capacity B to preserve per-OSD relative differences while changing only the scale, so that device heterogeneity is not erased by the treatment.
4. As an experiment owner, I want raw NVMe throughput treated as a diagnostic upper bound, so that a different datapath is not mistaken for OSD capacity.
5. As an experiment owner, I want a dual-calibration audit before screening, so that stale startup-bench or client-ceiling values do not invalidate the full campaign.
6. As an operator, I want the audit to finish within a fixed thirty-minute cap, so that partial calibration cannot silently consume the experiment matrix.
7. As an operator, I want calibration to avoid OSD restarts, so that the audit does not create additional cluster disruption or change the other agent's environment.
8. As an experiment owner, I want all treatments to receive the same common offered load, so that failure to reach target remains an observation rather than an excuse to change dose.
9. As an experiment owner, I want both the common scenario and maximum-separation scenario, so that the report covers operationally common behavior and the place most likely to reveal a profile trade-off.
10. As an experiment owner, I want `high_client_ops` and `high_recovery_ops` tested before `balanced`, so that limited time first measures the largest theoretical contrast.
11. As an experiment owner, I want paired and counterbalanced rounds, so that time drift and execution order are less likely to be mistaken for a profile effect.
12. As an operator, I want a maximum of three actual fault injections per cell, so that incomplete evidence cannot cause unlimited repeated OSD disruption.
13. As an operator, I want preflight rejection before `fault_t0` not to consume fault budget, so that safe refusal is not penalized as an experiment run.
14. As an application owner, I want client p99 reported directly in milliseconds for baseline and fault windows, so that latency cost is understandable without ratio conversion.
15. As an application owner, I want read, write, combined, per-client and worst-client p99 views, so that aggregate throughput cannot hide a latency hotspot.
16. As an experiment owner, I want p99 excluded from the formal verdict while no SLO exists, so that an important observation is not converted into an arbitrary success threshold.
17. As an experiment owner, I want signed capacity effects, so that evidence against the original hypothesis is as visible as supporting evidence.
18. As an experiment owner, I want right-censored recovery results preserved as bounds, so that a slow profile is not discarded or falsely recorded as exactly thirty minutes.
19. As an operator, I want every execution to use the same OSD-down target and managed-out fault semantics, so that target placement and CRUSH differences do not confound profile comparisons.
20. As an operator, I want an exclusive experiment window and campaign ownership lock, so that this campaign cannot interfere with another agent or inherit its active workload.
21. As an operator, I want any loss of exclusivity or rollback proof to pause the campaign, so that autonomous continuation never outranks cluster safety.
22. As an evidence reviewer, I want an append-only live evidence ledger, so that partial and interrupted executions remain reconstructable.
23. As an evidence reviewer, I want immutable checkpoint reports, so that the 17:30 state and every safety pause remain auditable even if the campaign later resumes.
24. As a report reader, I want one human-readable final report with missing artifacts disclosed, so that I can understand the conclusion without reading raw runner output.
25. As a report reader, I want raw data retained locally but kept out of the Markdown report and git history, so that evidence remains available without making the report unreadable or the repository unnecessarily large.
26. As an experiment owner, I want a `completed-with-gaps` terminal state, so that exhausted attempt budgets produce an honest report instead of an experiment that never finishes.

## Implementation Decisions

### Research boundary and treatments

- The campaign answers whether profile separation is sensitive to declared-capacity scale. It does not determine the single correct mClock capacity for the cluster.
- Capacity A is the exact old per-OSD vector, approximately 6,057–6,646 IOPS.
- Capacity B is the same vector multiplied by one common factor so its median is 21,500 IOPS. Capacity B is a sensitivity treatment, not a corrected truth.
- Raw NVMe fio, OSD startup bench and client ceiling remain separate domain measurements. Neither raw NVMe throughput nor aggregate client ceiling is directly assigned to `osd_mclock_max_capacity_iops_ssd`.
- A later sustained OSD-path calibration study is required before claiming a production capacity value.

### Exclusive-window and audit gates

- The runner may start calibration only after read-only preflight proves no other active runner or fio, `final_clean`, and known profile/capacity state.
- The campaign does not consume another agent's active results and does not stop, modify or clear its process or ownership markers.
- Audit reference state is `balanced + capacity A`.
- Each of eight OSDs receives three manual, startup-equivalent 4 KiB bench runs. Every run first drops the OSD cache. OSD restart is prohibited for this audit.
- The audit also runs three warmed client-ceiling rounds.
- All 24 OSD bench observations and all three client-ceiling observations must complete within thirty minutes. Missing any observation fails the audit; partial calibration does not start the matrix.
- An OSD fails audit when its three-run median differs from its own old value by more than 15%, or its within-OSD CoV exceeds 10%.
- Client ceiling fails audit when its median differs from the old reference by more than 15%, or its three-run CoV exceeds 10%.
- Cluster OSD median and cross-OSD CoV are descriptive only and cannot hide a single-OSD failure.
- Audit failure stops the planned matrix and requires a new capacity or workload decision outside this campaign.

### Workload and fault semantics

- Common offered load equals 50% of the fresh client-ceiling median, rounded to integer aggregate IOPS. The exact same target applies to both capacities and both extreme profiles.
- If a treatment achieves less than 85% of target but produces a stable sixty-second pre-fault window with IOPS CoV at or below 10%, it remains valid and is labeled `pre-fault capacity-bound`.
- Maximum-separation workload is the same 4K 70/30 shape in unlimited closed-loop mode.
- Every execution uses `mclock-osd-6`, mapped to `osd.5`, as the single OSD-down target.
- Before mutation, `ceph osd ok-to-stop osd.5` must pass. Failure remains a read-only preflight rejection.
- The runner records `fault_t0` immediately before stopping the daemon, waits for down, then marks the OSD out.
- Recovery endpoint occurs while the target is still down and out, when PGs for the current up set are all `active+clean`.
- Measurement ends after thirty minutes if recovery has not completed. The result remains a valid right-censored `>30m` observation.
- Rollback starts the OSD, verifies up, marks it in and waits for full `final_clean` before any next execution.

### Matrix, routing and repetitions

- Basic screening order is common A/`high_client_ops`, common A/`high_recovery_ops`, common B/`high_recovery_ops`, common B/`high_client_ops`.
- Basic slots five and six run maximum-separation `high_client_ops` and `high_recovery_ops` at the capacity selected after the complete common 2×2.
- Routing score standardizes the expected-direction client profile gap by 10 percentage points and the recovery profile gap by `max(300 seconds, 20% of pair mean)`. Each capacity uses the weaker of its two standardized endpoint scores. Higher score wins; ties use client score, then capacity A.
- Routing is adaptive exploratory selection, not a confirmatory claim. It is forbidden until all four common screening executions are complete.
- Missing, partial or invalid common screening cells are repaired before routing. The runner never starts a one-sided maximum-separation pair.
- Extension proceeds by complete paired rounds: common 2×2 to n=2, maximum-separation pair to n=2, common 2×2 to n=3, then maximum-separation pair to n=3.
- After all core cells reach n=3, the campaign runs common `balanced` at capacity A and B once each. It does not run maximum-separation `balanced`.
- Each cell has a maximum of three actual fault injections beginning at `fault_t0`. Complete, partial and post-fault invalid attempts all consume budget; preflight rejection does not.
- A cell that consumes three injections without the required complete samples becomes `attempt-budget-exhausted`.
- n=2 reverses the full n=1 order. n=3 uses a deterministic campaign-ID seed, fixed before reading endpoints, while retaining capacity blocks. Maximum-separation repetitions follow the same rule.
- Missing or invalid cells are repaired before increasing the paired round, without exceeding their fault budget.

### Schedule and block admission

- Each execution reserves 45 minutes: up to 30 minutes measurement plus 15 minutes setup, rollback and health verification.
- Basic screening plus the audit fits a conservative six-hour priority window; 17:30 is a report checkpoint, not an automatic stop.
- Planned completion contains 20 executions: 12 common extreme-profile executions, six maximum-separation executions and two common `balanced` references.
- Planned completion is conservatively estimated at 15.5 hours including audit but excluding exclusive-window waits and safety anomalies.
- A common round is admitted only with at least three known hours remaining. A maximum-separation pair or `balanced` A/B block is admitted only with at least 1.5 known hours remaining.
- With no known hard deadline, the runner may continue. Once a deadline becomes known, it does not start a paired block that cannot fit before it.

### Verdict and evidence interpretation

- Client profile gap is client IOPS retention under `high_client_ops` minus retention under `high_recovery_ops` at the same capacity.
- Recovery profile gap is recovery time under `high_client_ops` minus recovery time under `high_recovery_ops` at the same capacity. Positive values mean `high_recovery_ops` recovered faster.
- Signed capacity effect is profile gap B minus profile gap A.
- Client capacity effect needs an absolute magnitude of at least 10 percentage points to become a screening signal.
- Recovery capacity effect uses the average of the four common-cell recovery medians as its relative denominator. Its materiality threshold is `max(300 seconds, 20% of that average)`.
- Both endpoints materially positive support the hypothesis that low declared capacity hid profile separation. Both materially negative refute that direction and show low capacity amplified separation.
- Different endpoint directions produce `mixed capacity sensitivity`. Only one endpoint crossing threshold is reported as an endpoint-specific signal.
- Neither endpoint crossing threshold is reported as “not observed,” never as A/B equivalent.
- A right-censored recovery result is never substituted with 1,800 seconds. If available bounds cannot decide the threshold, recovery verdict is `censored-indeterminate`.
- n=1 screening and adaptively selected maximum-separation results remain exploratory.

### Application latency observation

- P99 is mandatory evidence but not a verdict endpoint because no formal SLO exists.
- Reports show milliseconds for combined overall, read, write, every client, worst client, baseline, fault and delta.
- Reports also show the worst thirty-second rolling p99 and cumulative duration above two times the execution's own baseline. The two-times trigger is descriptive, not an SLO.
- Existing 300-second fio segments remain unchanged. Abrupt interruption can lose the unfinished segment's p99, creating up to five minutes of p99 interruption exposure.
- Completed fio segments and five-second Ceph/recovery samples remain preserved. Missing current-segment p99 makes the execution partial when primary endpoints remain valid; it does not prove latency was normal and does not rewrite primary verdicts.
- Fault telemetry permits no single gap of 25 seconds or more and no more than 30 seconds total gap. All four clients require baseline and fault latency evidence.

### Campaign state, isolation and safety

- Every campaign uses a unique, initially empty results namespace below the extension campaign family. The runner must receive it explicitly and must reject an existing campaign ID.
- Old campaign data and another agent's artifacts are read-only. Their markers and replicates are never treated as resumable state for this campaign.
- Local and remote ownership locks are created only after exclusive-window preflight. They record campaign ID, runner ID, owner and creation time.
- Encountering another owner, runner or fio causes waiting and reporting only. The runner never steals or clears a lock and never stops the other workload.
- The campaign becomes `paused` and stops starting new executions when exclusivity disappears, an unexplained cluster health issue appears, `final_clean` cannot be verified, `balanced + capacity A` rollback cannot be verified, the user asks to stop, or a hard deadline arrives.
- A paused campaign cannot auto-resume. It must repeat the full exclusive-window preflight and reacquire ownership.
- Any error, interruption, wait or terminal state attempts rollback to `balanced + capacity A` across all eight OSDs. A failed rollback verification cannot be described as a safe stop.
- If a core cell exhausts budget, remaining independently useful eligible cells continue. Incomplete common 2×2 prevents adaptive maximum-separation runs; any core gap prevents the final `balanced` references.
- The campaign terminates as `planned completion` when all planned evidence is complete, or `completed-with-gaps` when every eligible cell is complete or budget-exhausted.

### Evidence and reporting

- A live NDJSON ledger appends prediction freeze, schedule seed, config proof, capacity proof, gates, `fault_t0`, state transitions, endpoint availability, rollback and partial/aborted reasons at event time.
- Existing ledger events are immutable. Corrections are new amendment events.
- `DONE` is written atomically only after bundle schema validation. Directory presence never means completion.
- A timestamped immutable checkpoint report is produced at 17:30 and each time the campaign pauses. Active execution is not interrupted solely to produce a checkpoint.
- Checkpoints identify completed, partial, active and not-started work, cluster/treatment snapshot, missing current fio segment and last trusted timestamp.
- Final reporting occurs on planned completion, `completed-with-gaps` or manual termination.
- The final report uses direct client IOPS, retention percentage points, recovery seconds and p99 milliseconds in the main tables. Statistical detail, execution order and missing-artifact ledger live in appendices.
- Raw fio JSON, Ceph samples, attempt bundles and machine-readable verdicts remain locally available in the git-ignored campaign namespace. The Markdown report cites summaries, relative paths and an integrity manifest; raw data is not committed.

## Testing Decisions

- The primary test seam is the single campaign runner entrypoint. Tests assert externally visible state transitions, exit status, ledger events, bundle markers, lock behavior and generated reports rather than internal helper calls.
- Existing fake SSH and command fixtures remain the external-system seam. Tests inject command output, timing, health state, ownership conflict and failure conditions without accessing Azure or a real Ceph cluster.
- Runner tests cover the successful path from exclusive preflight through audit, paired-block execution, rollback and planned completion.
- Runner tests cover audit timeout, missing OSD observations, OSD median drift, within-OSD CoV, client ceiling drift and client ceiling CoV.
- Runner tests verify that audit failure performs no fault injection and does not borrow the first execution slot.
- Isolation tests verify explicit unique results namespace, rejection of an existing campaign ID, no fallback to shared results, no old-marker resume and no foreign lock deletion.
- Fault-budget tests verify that only attempts crossing `fault_t0` count, that partial and invalid attempts count, and that a fourth injection is impossible.
- Scheduling tests verify basic order, routing prerequisites, tie-breaking, paired repair, n=2 reversal, deterministic n=3 schedule and paired-block admission deadlines.
- Safety tests verify no mutation after `ok-to-stop` failure, pause on lost exclusivity or unexplained health, mandatory rollback and prohibition on auto-resume.
- Artifact tests verify append-only ledger behavior, amendment events, atomic `DONE`, partial/aborted persistence, immutable checkpoints and last-trusted timestamps.
- P99 tests verify nanosecond-to-millisecond conversion, combined/read/write/per-client/worst-client views, rolling worst, elevated duration and five-minute unfinished-segment exposure.
- Verdict fixture tests verify signed client and recovery capacity effects, positive/negative/mixed/not-observed outcomes, right-censored bounds and `censored-indeterminate` without substituting 1,800 seconds.
- Terminal-state tests verify planned completion, attempt-budget-exhausted, completed-with-gaps and omission of ineligible maximum-separation or `balanced` blocks.
- Shell changes remain compatible with macOS bash 3.2, keep machine output on stdout and progress on stderr, and pass the repository's existing shell test, shellcheck and full validation gates before commit.
- Real Azure execution is qualification evidence after offline tests pass; it is not a substitute for automated tests. Real mutation requires exclusive-window proof and the explicit experiment execution phase.

## Out of Scope

- Declaring capacity A, capacity B, raw NVMe fio or client ceiling to be the uniquely correct production mClock capacity.
- Writing the approximately 287k raw NVMe IOPS directly into mClock.
- Building a sustained OSD-path calibration study; that is a separate future experiment.
- Defining or enforcing a formal application latency SLO.
- Using p99 as a profile success/failure verdict in this campaign.
- Re-running the prior full profile/fault/IO-shape campaign.
- Running maximum-separation `balanced` or a full three-profile matrix at every scenario.
- Changing the OSD target, fault type, CRUSH topology, replica policy, client shape or Ceph version during the capacity A/B comparison.
- Consuming another agent's active results, modifying its worktree, stopping its process, clearing its lock or changing its cluster state.
- Provisioning, deleting or resizing Azure VMs as part of spec creation or runner offline tests.
- Automatically publishing this spec to GitHub, committing it or pushing it without a separate user request.

## Further Notes

- The accepted decisions are recorded in [ADR-0001](../../adr/0001-prioritize-extreme-mclock-profiles-in-six-hour-screening.md), [ADR-0002](../../adr/0002-gate-mclock-screening-on-dual-calibration-audit.md), [ADR-0003](../../adr/0003-pre-register-capacity-effect-verdict.md), [ADR-0004](../../adr/0004-isolate-extension-campaign-results-and-ownership.md) and [ADR-0005](../../adr/0005-persist-live-evidence-and-human-readable-reports.md).
- Domain terminology and avoided synonyms are defined in [CONTEXT.md](../../../CONTEXT.md).
- The next repo workflow phase is a separate implementation plan. It must identify the smallest TDD changes to the existing calibration, fault, collection, verdict and supervisor modules before any real-lab execution.
- This spec is local-only. No GitHub issue was created because the user authorized clarification and local documentation, not external publication.
