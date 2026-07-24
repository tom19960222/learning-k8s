# ceph-mclock-profiles Harness Implementation Plan（Phase 1–2）— v4

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> v3：§Replicate Pipeline 成為唯一流程 SoT（workload 先行、注入發生在量測中）。v4：round 3 的 6 條設計級 findings 修正——bootstrap keypair 完整落地、消除「同 v2」懸空引用（本文件自包含）、cap/guard policy 定義、capacity 決策表 total function、sampler 順序修正、rack 兩台 barrier。v4.1：round 4 必改 6 條——key fanout 11 台契約、cap amendment versioned schema、no-rebench 統一 current-boot 證據、coverage supervisor 固定 cadence + continuity proof 入 schema、bg_collect_start 接上 calibrate 收尾、跨 8 顆 CoV gate 恢復。v4.2（round 5 雙 Claude reviewer 皆 APPROVE_WITH_CHANGES 後修正）：chaos min_size 不變條件、pilot 反偏誤（最慢組合）+ PILOT-CENSORED 分支 + per-replicate cap pooling 規則 + 雙 censored 自救、雙軌 margin + 預註冊生產門檻、drift gate（baseline-check）、taint 重試預算、target 綁定 group、ADMIN_PRIVATE_IP 介面、flapping noout、unit-scoped journalctl、12h az 登入態檢查、bastion 前置檢查與怠轉成本聲明。

**Goal:** 完成 spec Phase 1（Frame）與 Phase 2（Automate）。**本 plan 完成 ≠ spec 完成**：交付語言 = 「Phase 1–2 harness ready」；Phase 3–5 的 campaign+synthesis plan 是 Phase 3 開跑 gate 的**前置交付物**（Task 16 產出草案）。

**Architecture:** bash 3.2 orchestrator（macOS bastion）+ python3；ssh（ProxyJump 過 admin）駆動 15 台 VM。測試靠可程式化 fake ssh + fixtures。campaign 期間零 az 依賴（僅兩個例外：watchdog 2b 的 `az vm restart`、12h 回報循環的唯讀 `az account show` 登入態檢查；campaign 開跑前 az preflight）。

**Spec:** `docs/superpowers/specs/2026-07-24-ceph-mclock-profiles-azure-design.md`（**rev 7**——兩層 clean 判準、workload 先行、fault_t0 絕對時間軸、within-replicate 基線、雙軌 margin）
**Provisioning 契約:** `experiments/ceph-mclock-profiles/PROVISIONING-REQUIREMENTS.md`（v3——netcat/fping、attestation 驗值）
**Ceph 原始碼讀取**：一律用主 checkout 絕對路徑 `git -C /Users/ikaros/Documents/code/learning-k8s/ceph show v19.2.2:<path>`（本 worktree 的 `ceph/` submodule 未初始化，**不可用**）。

## Global Constraints

- bash 3.2 相容（禁 mapfile/declare -A/nameref；空陣列 `"${arr[@]+"${arr[@]}"}"`；中文字串內 `${var}`）。
- **單一 commit gate**：`tests/gate.sh` = run-tests + shellcheck（`find` 實際存在的 `*.sh`）+ `make validate`；每次 commit 前必跑；`git commit --no-gpg-sign`。
- stdout 只放機器行；log 一律 stderr。
- **遠端指令一律有界**：`node_ssh` 內建 `-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4`；`node_ssh_to <secs> <name> <cmd>` 在**遠端**包 coreutils `timeout <secs>`（Ubuntu 有；macOS 沒有所以不在 bastion 端包）+ bastion 端 `$SECONDS` deadline 後 kill 本地 ssh pid。輪詢一律 `with_deadline`。
- **遠端背景 process一律登記**：任何遠端背景 process（fio、sampler、ping mesh、isolation 自動回退 guard）啟動時寫 `/run/mclock/<run-id>.pid` + cmdline 指紋；reconciler（§Reconciler）可按 registry 強制清理。
- mutating run/ 腳本必須 `--yes-really-inject`。
- **常數**：ssh user=`ikaros`、key=repo `.ssh/id_ed25519`；campaign 專用 cephadm keypair 由 harness 產生（見 Task 5）；inventory=`azure/inventory.json` + `azure/attestation.json`（皆 git-ignored）；image `quay.io/ceph/ceph:v19.2.2`；pool=`mclock`（replica 3、rule `mclock-rack`、pg_num 128、autoscaler off）；client auth=`client.mclock-fio`；RBD image `fio-c1..c4` 各 300 GiB；chaos seed=4242。
- **fio 常數**：krbd、`ioengine=libaio`、`direct=1`、`randseed=4242`；4K randrw 70/30 `iodepth=16 numjobs=4`；1M seq write `iodepth=8 numjobs=2`；穩態單段 300s+ramp 30s；故障/chaos 連續 300s segment；time-series 契約 `log_avg_msec=1000` + `write_iops_log`/`write_lat_log`/`write_hist_log`（`log_hist_msec=1000`）+ `log_unix_epoch=1`；**fio 版本記入 env snapshot 並在 first-cell 前用真機 raw log 校正 parser**（Task 7/12）。
- **clean 判準（spec rev 7，全 plan 唯一引用）**：`recovery_complete`（當下 up set 下 PG 100% active+clean）｜`final_clean`（OSD 全 up+in + PG 100% active+clean + health 僅允許自設 noscrub/nodeep-scrub）。
- campaign 固定設定：noscrub、nodeep-scrub、balancer off、autoscaler off、`mon_osd_adjust_heartbeat_grace=false`；**設定當下即以 cleanup stack 註冊對稱 unset**（abort path 也會執行）。

## Replicate Pipeline（所有 execution 的唯一流程 SoT）

所有 run 腳本（steady/faults/chaos）共用 `lib/pipeline.sh` 的同一狀態機；差異只在 manifest 的 `fault_params`。**順序不可變**：

```
claim（原子取得 cell+replicate 的 lease）
→ preflight：qos gate（含 osd_op_queue=mclock_scheduler、skip_benchmark=true）+ final_clean + bg-collector alive
→ prediction freeze（寫入 bundle 後不可變）
→ sampler_start（replicate 級）→ sampler_assert_alive（v4：先 start 才 assert——順序不可倒）
→ fio 啟動（背景、segment 模式）→ readiness barrier（ramp 完成 + **60s throughput 穩定窗；此窗即 within-replicate 的注入前健康基線，逐秒 log 進 schema**——primary endpoint「p99 degradation ratio」的分母優先用它，跨日穩態 cell 降為次要對照（v4.2/F5-4 漂移防線））
→ [fault 類] 記錄 fault_t0（絕對 epoch）→ 計算並持久化 measurement_deadline=fault_t0+cap（cap policy 見下）→ 注入（fio 持續跑）
→ 量測窗：fio segment 續跑至 stop-condition = recovery_complete 或 measurement_deadline
   （穩態 = 單段 300s；chaos = chaos_run 事件序列與 fio 平行至 duration 結束）
   量測全程 **coverage supervisor（v4.1：固定 30s cadence，獨立於 segment 邊界）**：檢查 sampler heartbeat + fio 各 client heartbeat；
   finalize 前另做**時間軸連續性驗證**（sampler 樣本與 fio 逐秒 log 覆蓋整個量測窗，容忍單點 <10s 缺口並記錄）→ 產 `coverage-proof.json`（進 required-files schema）；
   任一持續 gap → 該 attempt 標 taint（禁止 finalize 為有效 replicate），量測繼續以保 cluster 安全回收
→ 停 fio（收 exit proof）→ 回歸（heal/daemon start + osd in）
→ safety gate：等 final_clean（progress deadline：PG 10min 零進展 → watchdog；censor 已在量測窗判定，不因此階段改變）
→ baseline 復測（60s）+ `verdict.py baseline-check`（drift gate，見 Task 10）→ sampler_stop → collect_cell → aggregate → verdict → bundle_finalize（per-kind schema）
→ release claim
```

**Cap policy（v4.2 修訂，全部持久化進 manifest fault_params 與 bundle）**：
- `measurement_cap`：pilot 前預設 **2700s**（45min——對單 OSD backfill 寬裕、對 rack loss 預期偏緊，operator 應有心理準備）；每故障型 pilot 完成後改為 `max(2700, 2×pilot_recovery_time)`（`schedule-estimate` 輸出 → `manifest.py amend` cap-update）。
- **pilot 反偏誤（v4.2/F5-2）**：pilot cell 固定選該故障型的**預期最慢組合**（極端壓 × `high_client_ops`；seq-contention 用極端壓），cap 由最慢者推導 → 其他 cells 不會被系統性 censor。
- **censored pilot 分支（v4.2/O-F1）**：pilot 自己撞 cap → `schedule-estimate` **必須偵測**並輸出機器行 `schedule-estimate: PILOT-CENSORED <fault> <cap>`，**禁止**拿 censored 值進 `2×` 公式；此時人工 gate 二選一：以 cap×2 重跑 pilot、或人工指定 cap（決策記入 journal）。
- **per-replicate cap 記錄與 pooling 規則（v4.2/O-F2）**：每個 replicate 的實際 cap 記入 bundle；`verdict` **拒絕合併不同 cap 的 replicates**（標記 → 觸發 extra-n 補齊同 cap 樣本）。
- **雙 censored 自救（v4.2/F5-2）**：同 cell 兩 replicate 皆 censored → 自動 `amend` 一次 cap×2 的加跑 replicate（每 cell 以一次為限），否則該 cell 對 time-to-recovery 的 profile 解析度歸零。
- **不變條件（測試斷言）**：`guard_deadline >= measurement_deadline + 600s`；**chaos 的 guard deadline = chaos duration + 600s**（chaos 無 measurement_cap，v4.2/F5-9）——guard 是「bastion 失聯時的最後安全網」，絕不可先於正常 heal 觸發；guard 觸發即該 attempt 標 taint。
- **taint/abort 重試預算（v4.2/F5-5）**：同一 replicate 連續 3 次 taint/abort → 寫入 amendments journal 標 `needs-human`，佇列**跳過**該 replicate 續跑其餘 cells（防系統性成因造成同 cell 無限重試空轉）；HUMAN-NEEDED 彙總時一併呈報。

任何出口（成功/失敗/中斷）都走同一 cleanup stack：停 fio（by PID registry）→ 回退注入（heal/start/in）→ sampler_stop → lease 釋放。

### Reconciler（crash-resume 的前置步）

`lib/pipeline.sh::reconcile`——每個 run 腳本啟動時必跑：
1. **單 runner lock**：`results/.runner.lock`（mkdir 原子建立 + pid + 心跳；stale 判定後接管）。
2. 掃描殘留：全 node `MCLOCK-ISO` chain（flush）、非預期 down/out OSD（start+in）、`/run/mclock/` registry 的殘留 fio/sampler/guard（kill + 清 pidfile）、未 finalize 的 attempt（標 aborted）。
3. 等 final_clean 後才允許 `manifest next` 取下一 execution。

## File Structure

```
experiments/ceph-mclock-profiles/
├── HYPOTHESES.md / PROVISIONING-REQUIREMENTS.md / README.md
├── .gitignore                     # results/、azure/inventory.json、azure/attestation.json
│                                  #（EVIDENCE-SUMMARY-*.md 在根目錄，不受影響）
├── azure/verify-provision.sh
├── lib/
│   ├── inventory.sh  common.sh    # Task 2
│   ├── manifest.py                # Task 4
│   ├── ceph.sh                    # Task 5–6
│   ├── fio.sh                     # Task 7
│   ├── inject.sh                  # Task 8
│   ├── collect.sh                 # Task 9
│   ├── verdict.py                 # Task 10
│   └── pipeline.sh                # Task 11（Replicate Pipeline + Reconciler）
├── run/
│   ├── calibrate.sh               # Task 12
│   ├── steady.sh                  # Task 13
│   ├── faults.sh                  # Task 13
│   └── chaos.sh / all.sh          # Task 14
├── tests/（gate.sh、run-tests.sh、fakes/ssh、fixtures/、test-*.sh）
└── results/                       # git-ignored
```

---

### Task 1: Frame — HYPOTHESES.md

**Files:** Create `HYPOTHESES.md`

- [ ] Step 1: **dmclock 錨點（F27 修正）**：`git -C /Users/ikaros/Documents/code/learning-k8s/ceph ls-tree v19.2.2 src/dmclock` 取 gitlink SHA →（必要時先在主 checkout `git fetch origin tag v19.2.2 --no-tags`）→ 於 dmclock submodule（初始化後 fetch 該 SHA）讀 `src/dmclock_server.h`；錨點格式 `dmclock@<sha>:path:line`。禁止以 v19.2.3 working tree 冒充。
- [ ] Step 2: cost model（`mClockScheduler.cc:152-185,250-283,427-436`）+ 1M IO cost 算例。
- [ ] Step 3: mClock bypass 邊界（`mClockScheduler.cc:476-499`、`OpSchedulerItem.h:243-278`）。
- [ ] Step 4: `maybe_override_options_for_qos`（`OSD.cc`）——backfills/recovery 鎖定值（明列 `osd_max_backfills=1`、`osd_recovery_max_active_ssd=10`）。
- [ ] Step 5: capacity 全路徑（`OSD.cc:10020-10122`）含 skip-if-value≠default 陷阱與 `osd_op_queue` 前提（`OSD.cc:10024-10026`）。
- [ ] Step 6: `mon_osd_adjust_heartbeat_grace` / laggy 更新語意（`OSDMonitor.cc:3195-3239,3692-3714`——**關閉 adaptive grace 只是不用 laggy 算 grace，laggy 值仍會更新**；記錄為 covariate 的依據）與 `down_out_subtree_limit`（`OSDMonitor.cc:5160-5187`）。
- [ ] Step 7: charter + 全 cells prediction 骨架（穩態 = negative control）+ **預註冊生產門檻（v4.2/F5-3）**：四個 primary endpoint（p99 degradation ratio、max IO stall duration、recovery bytes/s、time-to-recovery-complete）各定一個「生產有感」絕對門檻（例：stall > 5s = 事故級、p99 ratio > 3× = 顯著），寫死進 HYPOTHESES.md——`indistinguishable` 之後必須能區分「等效（差異 < 生產門檻）」vs「靈敏度不足（noise margin > 生產門檻）」，不然 Azure 噪音大會讓一切 indistinguishable 卻被誤讀成「profile 沒差」。
- [ ] Step 8: Gate：貼給使用者過目（不阻塞 harness；Phase 3 前必過）。

### Task 2: transport seam — inventory + common + fake ssh v2 + gate.sh

**Files:** Create `.gitignore`、`lib/inventory.sh`、`lib/common.sh`、`tests/gate.sh`、`tests/run-tests.sh`、`tests/fakes/ssh`、`tests/fixtures/inventory.json`、`tests/test-inventory.sh`、`tests/test-common.sh`

**Interfaces:**
- `lib/inventory.sh`：python3 解析 → `inv_names/inv_ip/inv_rack/inv_nvme/ADMIN_PUBLIC_IP/**ADMIN_PRIVATE_IP**`（v4.2/O-F3：Task 5 bootstrap `--mon-ip` 與 Task 8 隔離規則的 `-s/-d` 都依賴它，缺了在 `set -u` 下當場死、或更糟——空字串讓隔離規則 match 全部流量）；結構不符 die。
- `node_ssh <name> <cmd>`（固定選項見 Global）；`node_ssh_to <secs> <name> <cmd>`（遠端 `timeout` + bastion deadline kill）。
- `with_deadline <secs> <fn> [args...]`（`$SECONDS`；`POLL_INTERVAL` 可注入）。
- `remote_bg_start <name> <run-id> <cmd>` / `remote_bg_stop <name> <run-id>` / `remote_bg_list <name>`：遠端背景 process + `/run/mclock/<run-id>.pid` registry。
- `log/die/require_inject_flag`；`cleanup_push`（唯一 top-level trap、LIFO）。
- `new_bundle <cell-id> <rN>`（穩定 key；attempts/ 內層時間戳）；`bundle_finalize <dir> <kind>`（per-kind required-files schema 由 verdict.py 提供清單，見 Task 10；全過才原子 DONE）；`bundle_is_done`。
- fake ssh v2：`FAKE_SSH_SCRIPT` FIFO 協定（pattern|rc|delay|stdout-file 順序消費、同 pattern 先敗後成、delay 模擬 hang、非預期指令 fail、呼叫計數）。
- `tests/gate.sh`。

- [ ] Step 1: 測試先行（含 node_ssh_to 的遠端 timeout 包裝與 bastion kill、remote_bg registry 生命週期、fake ssh v2 全協定）。
- [ ] Step 2: 實作至 gate 綠。

### Task 3: azure/verify-provision.sh（R §9 全覆蓋 + attestation 驗值）

**Files:** Create `azure/verify-provision.sh`、`tests/test-verify-provision.sh`

R §9 全部條目 + **attestation 驗值**（非驗存在）：boolean=期望值、費率>0、`generated_at` <24h、`subscription_id` 與 bastion `az account show` 一致（此為 campaign 前唯一的 az 唯讀呼叫之一，同時完成 watchdog 2b 的 az preflight：登入態/subscription/RG 權限）。工具檢查含 `nc`（netcat-openbsd）、`fping`。任一 FAIL exit 1；機器行 `verify-provision: PASS|FAIL <n>/<total>`。

- [ ] Step 1: 測試先行（attestation 值不符 FAIL、時戳過期 FAIL、az preflight fixture）。
- [ ] Step 2: 實作至 gate 綠。

### Task 4: lib/manifest.py

**Files:** Create `lib/manifest.py`、`tests/test-manifest.sh`

- `generate`：63 cells → `{cell_id, group_id, profile, shape, pressure, fault, fault_params, base_n, targets}`；`fault_params` 完整 per-type：flapping `{cycles:10, no_out:true, per_cycle_gate:"pgs_active_for_osd"}`、osd-down `{manual_out:true}`、node-isolation `{nodes:1, manual_out:true}`、rack-isolation `{nodes:2, manual_out:true}`、seq-contention `{fault:"osd-down", shape:"seq", manual_out:true}`；**targets 綁定 group（v4.2/F5-6）**：同一 group（同 shape × pressure × fault）內全部 executions 用**同一 target**（profile 對照不被 target 異質性污染），輪替只發生在 group 之間。Latin：`LATIN[(group_index + replicate_n) % 3]`，測試斷言全 schedule position balance。`--assert` 63/147。**pilot = 每故障型「預期最慢組合」cell（極端壓 × high_client_ops）的 r1**（合格即 r1；v4.2 cap 反偏誤）；node-isolation 只有中壓 cells → 其 pilot 退化為**中壓 × high_client_ops**（v4.2.1 明文）。
- `next`：讀 results/（DONE bundles）+ **`results/schedule-amendments.json`**（need-more-n 的持久化 journal，F18）→ 下一 execution；與 runner lock 配合單一消費者。
- `amend`（v4.2.1 versioned schema）：journal 為 append-only JSONL，每筆 `{schema_version, type, key, value, source, seq}`；type 四型窮舉：
  - `extra-replicates`（key=cell_id, value=加跑數）——CoV 升級用；
  - `cap-update`（key=fault type, value=新 measurement_cap 秒數，source=pilot estimate）——影響同 fault type 的**尚未執行** executions，已執行者保留原 cap 於 bundle；
  - `rescue-replicate`（key=cell_id, value={cap: 秒數}）——雙 censored 自救專用，**攜帶 per-replicate cap override**（不污染同型其他 cells）；
  - `needs-human`（key=cell_id/replicate, value=原因）——taint 重試預算耗盡的標記，佇列跳過、audit 呈報清單。
  寫入 = tmp 檔 + mv 原子 append；`next` 與 `audit` 以同一 merge 視圖運作（四型都有定義的視圖語意）。resume：journal 是唯一持久 SoT，crash 後重讀即恢復。

- [ ] Step 1: 測試先行（63/147、Latin balance、amendments **四型** schema（extra-replicates / cap-update / rescue-replicate / needs-human）各自的原子寫入/merge/resume/audit 視圖、cap-update 只影響未執行 executions、pilot 語意）。
- [ ] Step 2: 實作至 gate 綠。

### Task 5: lib/ceph.sh（一）— 部署鏈

**Files:** Create `lib/ceph.sh`、`tests/test-ceph-deploy.sh`、fixtures

**序列（每步冪等 + 驗證）：**
1. `ceph_gen_campaign_key`（v4.1 修正）：bastion 產 campaign 專用 ed25519 keypair → pubkey 冪等 append 到 **11 台全部 Ceph host（admin ×1 + mon ×2 + osd ×8）** 的 `ikaros` authorized_keys（admin 也要——不依賴 bootstrap 自行 authorize 的行為）→ **keypair 兩個檔案都** scp 到 admin（`/home/ikaros/.ssh/mclock_campaign` `0600` + `mclock_campaign.pub` `0644`）→ 驗 owner=`ikaros`、mode、**內容與 bastion 端逐位元一致**（cephadm 對 `--ssh-private-key`/`--ssh-public-key` 皆 `FileType('r')` 直接開檔，缺任一檔 bootstrap 直接失敗，`cephadm.py:5241-5247`）。
2. `ceph_bootstrap`（完整 argv，F1）：
   `sudo cephadm --image quay.io/ceph/ceph:v19.2.2 bootstrap --mon-ip ${ADMIN_PRIVATE_IP} --ssh-user ikaros --ssh-private-key /home/ikaros/.ssh/mclock_campaign --ssh-public-key /home/ikaros/.ssh/mclock_campaign.pub --skip-dashboard`
   （用預備好的 keypair → 不依賴 cephadm 自產 key 的散布時序）。
3. `ceph_add_hosts`：**先** `ceph orch host add <name> <ip>` ×10，**後** 逐台 `ceph cephadm check-host <name>`（round2/F2：check-host 對未納管 host 回 Host not found）。
4. `ceph_apply_mons`：placement 明列三台 → 輪詢 quorum 恰為指定 3 名。
5. `ceph_apply_osds`：逐台 `ceph orch daemon add osd <host>:<inv_nvme>`（禁 all-available-devices）→ 8 OSD up+in、一 host 一顆。
6. `ceph_verify_versions`（F1）：`ceph versions` 全部 daemon = 19.2.2 + `ceph orch ps` image 相符，否則 die。
7. `ceph_setup_crush`：4 rack bucket → move root/host → rule `mclock-rack` → 驗證 4×2 + rule。
8. `ceph_create_pool`：pool + size 3 + autoscaler off + `rbd pool init`。
9. `ceph_setup_client_auth` + **smoke gate（round2/F5 修正）**：auth/conf/keyring 分發後，每 client 建**拋棄式** image `smoke-<client>`（1GiB）→ `rbd ls → map → dd 讀寫 → unmap → rbd rm`（正式 fio-c* image 由 Task 7 建）。
10. `ceph_campaign_flags` / `ceph_campaign_unflags`（set 當下 cleanup_push 註冊 unset）。

- [ ] Step 1: 測試先行（argv 完整性含 key 參數、**admin 上兩個 key 檔存在 + owner/mode/內容一致、pubkey fanout 覆蓋 11 台全部斷言**、add→check 順序、versions gate、smoke 用拋棄式 image 並清除、冪等）。
- [ ] Step 2: 實作至 gate 綠。

### Task 6: lib/ceph.sh（二）— QoS gate、capacity、健康判準

**Files:** Extend `lib/ceph.sh`、`tests/test-ceph-qos.sh`

- `ceph_qos_gate <profile>`（每 execution preflight）：驗證集合 = **`osd_op_queue=mclock_scheduler`（round2 新 blocker 2）** + profile + 九參數 + 鎖定 capacity + seq bw 1200MiB/s + `osd_max_backfills=1` + `osd_recovery_max_active_ssd=10` + `override_recovery_settings=false` + **`osd_mclock_skip_benchmark=true`**；八顆同時收斂 → settle 30s → 結構化 JSON 入 bundle。
- `ceph_capacity_provenance` + `ceph_capacity_decide`（round2/F6 + v4 total function）：per-OSD 決策表 `results/capacity-lock.json`——`{osd, bench_iops, bench_status, raw_fio_iops, decision, locked_value}`。**決策規則窮舉（每個狀態都有出口，無隱含分支）**：

  | bench_status | 條件 | decision |
  |---|---|---|
  | `accepted-consistent` | bench 被 Ceph 採用且 bench/raw_fio ∈ [0.5, 2] | 鎖 bench 值 |
  | `accepted-inconsistent` | bench 被採用但比值出界 | 鎖 `min(raw_fio, 72000)`、標 `fio-derived`、報告註明 |
  | `rejected-out-of-range` | bench 值超出 1000–80000 被 Ceph 丟棄 | 鎖 `min(raw_fio, 72000)`、標 `fio-derived` |
  | `skipped-existing-nondefault` | mon store 已有非預設值、bench 未跑 | 對 stored 值做同一比值檢查：consistent → 鎖 stored；inconsistent → 鎖 fio-derived |
  | `failed / no-result` | bench 執行錯誤或 log 缺失 | **die**（`capacity-decide: HUMAN-NEEDED`，不得自動選值） |

  決策表齊 8 顆 + **跨 OSD dispersion gate**（8 顆 `locked_value` 的 CoV > 20% → die `capacity-dispersion-high`，不得 lock、不得開跑——spec §4 的異質 NVMe 防線；die 訊息指向 README 的 remediation 步驟：outlier OSD 以 `force_run_benchmark_on_init` + restart 重測、或 operator override 帶 provenance 記錄）才可 `ceph_lock_capacity`（逐顆 set + `skip_benchmark=true`）。
- `ceph_verify_no_rebench`（v4.2 精確化）：reboot canary 後以**新 boot 證據的合取**判定——boot ID 已變更 + **`journalctl -b -u ceph-<fsid>@osd.N`**（fsid 取自部署步驟；cephadm OSD 在 podman 內、log 走 fsid-scoped unit，裸 `journalctl -b` 撈不到等於空集合假通過）內**無 `osd bench result` 行** + effective `skip_benchmark=true` + capacity 值未變。注意：v19.2.2 的 skip 路徑（`OSD.cc:10024` early return）**沒有**正向「skipped」log 可斷言，只能靠上述合取。
- `ceph_wait_recovery_complete <deadline-epoch>`（相對當下 up set 的 active+clean；絕對 deadline）與 `ceph_wait_final_clean <progress-deadline>`（up+in 全員 + clean + flags 白名單；PG 10min 零進展 → exit 3 交 watchdog）。
- `ceph_osd_state`（up/down 以 `up_from`/`down_at` vs pre-state 判定）、`ceph_wait_pgs_active_for_osd <id>`（round2/F23：`pg ls-by-osd` 全 active）、`ceph_daemon_stop|start`（orch）、`ceph_osd_out|in`、`ceph_check_laggy`（**僅記錄 covariate，不 gate**——round2 REGRESSED 修正）。

- [ ] Step 1: 測試先行（qos_gate 含 op_queue/skip_benchmark、capacity 決策表**全五狀態**各自出口、**跨 8 顆 CoV gate**、no-rebench 以 **current-boot 合取（boot ID 變更 + `journalctl -b -u ceph-<fsid>@osd.N` unit-scoped）** 證據斷言——**不得**使用 pre-reboot cursor 或裸 `journalctl -b`、兩層 clean 各自語意、laggy 只記不擋）。
- [ ] Step 2: 實作至 gate 綠。

### Task 7: lib/fio.sh

**Files:** Create `lib/fio.sh`、`tests/test-fio.sh`、fixtures

- `fio_setup_images/map_all/unmap_all`、`fio_precondition`（`ceph df` 驗 20–30%）。
- `client_tuning_apply/verify/restore`（round2/F20）：scheduler=none、readahead 固定值；apply 後驗、campaign 收尾 restore。
- `fio_render_job <shape> <mode> <rate>`：完整 time-series 契約（三 log + `log_unix_epoch=1`）。
- `fio_start_bg <bundle> <mode>`（經 `remote_bg_start`，per-client run-id）+ `fio_readiness_barrier`（ramp 完成 + **60s** throughput 穩定窗——與 pipeline SoT 一致，此窗即注入前健康基線；round2 blocker 4 的前置）+ `fio_stop <bundle>`（收 exit code 檔 + 每 client heartbeat log = exit proof，round2/F12）+ `fio_wait_segments <stop-fn> <deadline>`。
- `fio_run_steady <bundle>`：單段 300s（4 client 平行、收 JSON + 三 log）。`fio_run_baseline <bundle>`：60s 短對照（同形態同壓力）。`fio_calibrate <shape>`：balanced + final_clean 下 rate sweep——無限速 3 輪取中位為 ceiling，反推 25/50/80% per-job rate，**並在各壓力等級各跑一段 60s 記錄參考 p99** → `results/calibration.json`（rate、ceiling、**per-pressure 參考 p99**——`baseline-check` 的比較基準來源）。
- `fio_raw_nvme_baseline <name>`（**只准在 OSD 建立前**）：OSD node 本機 fio 4K randwrite 直打 `inv_nvme` 60s → per-node 基線 JSON；內建 guard：blkid/`ceph-volume inventory` 偵測到該裝置已有 BlueStore/分割 → die。
- `fio_smoke_real <bundle>`（round2/F12）：first-cell 前跑 60s 真 fio → raw 三 log 存為 golden → `verdict.py aggregate --validate-schema` 過才放行（parser 對真輸出的一次性校正；windowed log 的重複 timestamp/不完整尾窗由 parser 處理）。

- [ ] Step 1: 測試先行（render 契約、readiness barrier 判定、exit proof、raw guard、smoke-real 流程）。
- [ ] Step 2: 實作至 gate 綠。

### Task 8: lib/inject.sh — 各故障狀態機

**Files:** Create `lib/inject.sh`、`tests/test-inject-*.sh`

- `fault_flapping <osd-id>`：attempt 開始先設 **`noout`**（cleanup stack 對稱 unset；v4.2/F5-8——某輪 start 卡住超過 `mon_osd_down_out_interval=600s` 會觸發 auto-out，非計畫 backfill 讓整個 attempt 變質）→ 10 輪 {stop → 等 down（超 grace 顯式 `ceph osd down`）→ start → 等 up → **`ceph_wait_pgs_active_for_osd`** + **斷言該 OSD 未被 out**（被 out 即 taint）}→ unset noout；laggy 逐輪記錄（covariate）。
- `fault_osd_down <osd-id>`：pre-state 存檔 → `ceph_daemon_stop` → 等 down（`ceph_osd_state` 判定）→ **立即 `ceph osd out`**（fault_t0 已由 pipeline 記錄）。`fault_osd_down_recover <osd-id>`：`ceph_daemon_start` → 等 up → `ceph osd in`。
- `fault_node_isolate <name>`（round2/F16 + blocker 9 修正）：
  - 規則檔：專用 chain `MCLOCK-ISO`，**ESTABLISHED,RELATED 只允許 admin_private_ip 的 tcp/22 flow**（`-s/-d ${ADMIN_PRIVATE_IP} -p tcp --dport/--sport 22 -m state --state ESTABLISHED,RELATED,NEW`）；其餘 subnet 流量雙向 DROP（**既有 Ceph messenger/heartbeat 連線因無 general ESTABLISHED accept 而立即斷流**）。`iptables-restore --noflush` 原子套用。
  - **自動回退 guard（v4 順序與期限定義）**：guard 於**套用 chain 之前**先武裝（`remote_bg_start` 一支 `sleep ${GUARD_DEADLINE_SECS} && flush MCLOCK-ISO`；`GUARD_DEADLINE_SECS = measurement_cap + 600`，不變條件見 §Cap policy）——避免「chain 套了、guard 沒起來」的窗口；heal 時先 kill guard 再 flush。guard 觸發 = 該 attempt 標 taint（guard 是安全網不是 heal 路徑）。
  - **驗證三段**：注入前從 client 對 `ceph osd metadata <id>` 取得的**實際 addr:port** `nc -z` 通 → 注入後不通 + node_ssh 仍通 + OSD 判 down → heal 後恢復通。
- `fault_rack_isolate <rack>`（v4：**prepare/commit 兩階段 barrier**）：
  - **prepare**：兩台各自武裝 guard → 兩台各自 `iptables-restore --noflush` 套 chain（間隔 <5s）。
  - **verify barrier**：兩台**都**通過（endpoint closed + node_ssh 存活 + 該台 OSD 判 down）才算注入成功；**任一台失敗 → 立即回退兩台 + 該 attempt 標 taint**，不得降級成單 node fault 續量。
  - **commit**：兩台都 verified 後**一次** `ceph osd out` 兩顆 OSD（backfill 起點單一），此刻才進量測終點判定。
  - `fault_rack_heal`：兩台 kill guard → flush → 驗流量恢復 → 等兩 OSD up → 一次 `osd in` 兩顆。
- `chaos_run <seed> <duration> <bundle>`：python3 PRNG（seed=4242）產固定事件序列（事件 ∈ {osd stop/start, node isolate/heal}、目標、間隔）。**min_size 安全不變條件（v4.2/F5-1）**：generator 產生每個事件前檢查展開後的併發故障狀態，**任一時刻不得使任何 PG 低於 min_size=2**——實作規則：同時 down/isolated 的 node 限同一 rack、且不與跨 rack 的 osd-stop 疊加（否則 PG inactive → krbd client IO 卡 kernel D-state，fio kill 不掉、unmap 必敗，watchdog 救不回）。seed 固定 → 測試對**展開後的完整事件序列**斷言此不變條件 + 同 seed 重播一致；chaos 內 isolate 事件的 guard deadline = duration + 600s；結束全回退。
- 全部：`require_inject_flag`、cleanup_push、事件時間軸（epoch + OSDMap epoch）。

- [ ] Step 1: 測試先行（規則檔逐行斷言含 ESTABLISHED 範圍 + **`-s/-d` 為具體 IP 非空字串（來源 = inventory，不得 fixture 硬編碼繞過）**、**guard 先於 chain 武裝 + deadline 不變條件（含 chaos 的 duration+600）**、metadata endpoint 三段驗證、heal 冪等、**rack prepare/verify/commit barrier 與單台失敗回退兩台**、**chaos 展開序列的 min_size 不變條件** + 重播一致、flapping **noout 對稱設/解 + 未被 out 斷言** + per-cycle gate）。
- [ ] Step 2: 實作至 gate 綠。

### Task 9: lib/collect.sh

**Files:** Create `lib/collect.sh`、`tests/test-collect.sh`

**Interfaces:**
- replicate 級 sampler：`sampler_start <bundle>`（admin 上背景迴圈 5s 粒度收 `ceph pg dump --format json` 差分、`ceph -s`、OSDMap epoch；lock + PID registry + heartbeat 檔）；`sampler_assert_alive`（heartbeat 新鮮度檢查，pipeline 於 start 後與每 segment 邊界呼叫）；`sampler_stop <bundle>` 冪等。
- campaign 級：`bg_collect_start|stop`——1s ping mesh（`fping`，各 node 落檔）、NIC 差分（sar 10s）、SLOW_OPS/health 事件 log；同樣 lock/PID/heartbeat/resume 契約。
- `collect_cell <bundle>`：量測窗收尾——fio 輸出回收、sampler 資料截斷歸檔、逐 OSD config show 快照、`ceph df`、prometheus 時窗 export；產出物清單依 per-kind schema（Task 10）。
- env snapshot 三段：`env_snapshot_provision`（版本/套件/kernel/fio 版本）、`env_snapshot_cluster`（ceph versions/crush tree/pool/flags）、`env_snapshot_map`（krbd options/rbdX 對應/client scheduler+readahead）；各自檢查前置狀態存在才收。

- [ ] Step 1: 測試先行。
- [ ] Step 2: 實作至 gate 綠。

### Task 10: lib/verdict.py

**Files:** Create `lib/verdict.py`、`tests/test-verdict.sh`、fixtures

- `aggregate`：跨 segment 合併；stall（秒完成=0）/brownout（hist p99>1s）；**log gap（工具中斷）≠ stall**；windowed-log 重複 timestamp / 不完整尾窗正規化；`--validate-schema` 模式供 `fio_smoke_real`。
- `margins`：**雙 margin（v4.2/F5-3）**——noise margin（穩態 CoV 導出；故障 cells 另以 pilot + 首輪故障資料補正，穩態噪音不可直接移植）與 production margin（HYPOTHESES.md 預註冊門檻）並存；`verdict` 同時報兩者，`indistinguishable` 必須標明是「等效」還是「靈敏度不足」。
- `verdict`（prediction freeze；censor 相對 recovery_complete；**拒絕合併不同 cap 的 replicates** → 觸發 extra-n）。
- `need-more-n`（→ `manifest.py amend`，journal 持久化）：**含 censored 觀測的 cell，CoV 無定義 → 不走 CoV 升級**，改由「雙 censored 自救」規則處理（§Cap policy）；此 case 必須有測試。
- `schedule-estimate`（含 PILOT-CENSORED 偵測，§Cap policy）。
- **drift gate（v4.2/F5-4 + v4.2.1/N2 基準修正）**：`baseline-check <bundle>` 消費每 replicate 的 60s baseline 復測（同形態**同壓力固定速率**）。**比較基準 = 該 cell 的目標速率與校準時同壓力的參考 latency**，兩項判定：(a) 供給達成率（achieved/target）< 85% → drift 徵兆；(b) baseline p99 相對校準時同壓力參考值偏移 > ±15% → drift 徵兆。**不得拿固定速率 cell 的 achieved 去比 calibration ceiling**（低/中壓本來就只跑 25/50% ceiling，恆超標假陽性會把 campaign 假性暫停）。任一徵兆 → 機器行 `baseline-drift <metric> <pct>`、記 covariate；連續 3 個 replicate 超標 → 佇列暫停要求 recalibrate 裁決（HUMAN gate）；audit 標記受影響時段。漂移不允許「悄悄」存在。
- `schemas <kind>`（round2/F21）：輸出 steady/fault/chaos 各自的 **versioned required-files schema**（steady: prediction/qos/fio/aggregate/verdict；fault: + fault-timeline/sampler/censor-status/final-clean-proof/cleanup-proof/**coverage-proof**；chaos: + event-seq，**同樣要 prediction/verdict/coverage-proof**）；`bundle_finalize` 據此驗，並交叉核對 cell/profile/manifest-hash/時間窗一致。
- `audit`：對照 manifest + amendments journal → 63/147+extra 齊備度、缺件、duplicate、censored/tainted/descope 清單 → 產 `EVIDENCE-SUMMARY-<date>.md`（根目錄）。

- [ ] Step 1: 測試先行（segment 合併跨界 stall、gap 語意、schema 三 kind 差異、finalize 交叉核對失敗路徑、audit 含 amendments、**雙 margin 與 indistinguishable 兩型判別、censored cell 不走 CoV 升級、不同 cap replicates 拒絕合併、baseline-check 漂移分級（單次 covariate / 連續 3 次暫停）**）。
- [ ] Step 2: 實作至 gate 綠。

### Task 11: lib/pipeline.sh — Replicate Pipeline + Reconciler（round2 blockers 3/4/7/8 的核心修正）

**Files:** Create `lib/pipeline.sh`、`tests/test-pipeline.sh`

- `pipeline_run_execution <execution-json>`：實作 §Replicate Pipeline 全序列（claim → preflight → freeze → sampler → **fio 先行 + readiness** → fault_t0 → 注入 → stop-condition=recovery_complete|measurement_deadline → 停 fio → 回歸 → final_clean → baseline → collect → aggregate → verdict → finalize → release）；per-fault 行為由 `fault_params` 分派到 Task 8 狀態機；穩態/chaos 為同一機的參數化路徑。
- `reconcile`：單 runner lock、殘留掃描（MCLOCK-ISO/down-out OSD/registry process/未 finalize attempt）、**bg-collector 存活檢查（死了就 restart——resume 路徑的 start 點之一）**、final_clean 後才放行。
- claim lease：`results/<cell>/rN/.claim`（mkdir 原子 + runner id + 心跳；stale 接管）。
- **watchdog transition table（v4 完整內嵌，trigger-specific——不同 trigger 走不同修復，不得共用 OSD 修復動作）**；狀態持久化 `results/watchdog-state.json`（resume 不重置計數）：

  | Trigger（detection） | 動作 | 成功判準 | 上限 | 失敗升級 |
  |---|---|---|---|---|
  | PG 零進展 10min（sampler pg 差分） | 停 fio+回退注入 → `ceph orch daemon restart` 相關 OSD → 重試該 replicate | final_clean | 2 | → node reboot（2a） |
  | 目標 node ssh 失聯 | 2a：其他路徑確認（admin ping）→ ssh `sudo reboot`（若 ssh 尚可）| ssh 恢復 + OSD rejoin + final_clean | 2 | → 2b |
  | ssh 完全失聯（reboot 不可下達） | 2b：bastion `az vm restart`（唯一 az 例外；已 preflight） | ssh 恢復 + OSD rejoin + final_clean | 1 | → 層 3 |
  | mon quorum 異常（`quorum_status`≠3） | 停佇列 → `ceph orch daemon restart` 該 mon → 等 quorum=3 | quorum=3 + final_clean | 1 | → 層 3 |
  | sampler/bg-collector heartbeat 失聯 | **只重啟 collector**（remote_bg registry kill+start）；當前 attempt 標 taint；**不碰 OSD/cluster** | collector heartbeat 恢復 | 2 | → 層 3 |
  | fio client heartbeat 失聯 | 停該 attempt（taint）→ unmap/map 重試 smoke → 重跑 attempt | smoke 過 + 新 attempt 正常 | 1 | → 層 3 |
  | 層 3（HUMAN-NEEDED） | 機器行 `watchdog: HUMAN-NEEDED <trigger> <ctx>`、佇列停、**嚴禁 deallocate** | — | — | — |

  每層動作前後驗 ssh / OSD 狀態 / collector+fio cleanup；每個 trigger 的計數獨立；任一修復成功即 reset 該 trigger 計數。

- [ ] Step 1: 測試先行（**順序斷言：sampler_start → assert → fio readiness → 注入**、recovery_complete 為 stop-condition、censor 判定於量測窗、**coverage supervisor 的 gap→taint**、**cap/guard deadline 不變條件**、cleanup stack 全出口、reconcile 各殘留類型、claim 衝突/stale、**watchdog 各 trigger 分派互不誤傷（sampler 死不碰 OSD）**+ 遞進 + 持久化、**同 replicate 連續 3 次 taint/abort 不再重發（needs-human 入 journal、佇列跳過續跑）**）。
- [ ] Step 2: 實作至 gate 綠。

### Task 12: run/calibrate.sh

**Files:** Create `run/calibrate.sh`、`tests/test-calibrate.sh`

順序：verify-provision（含 az preflight）→ `env_snapshot_provision` → **raw NVMe fio ×8（bootstrap 前）** → 部署鏈（Task 5 序列含 versions gate + smoke）→ `campaign_flags` → `env_snapshot_cluster` → capacity provenance + **decide（全五狀態決策表 + 跨 8 顆 CoV gate）** + lock → **reboot canary（`ceph_verify_no_rebench`：current-boot 合取證據——boot ID 變更 + unit-scoped `journalctl -b -u ceph-<fsid>@osd.N` 無 bench log + effective skip + 值未變）** → network baseline（iperf3）→ images + `client_tuning_apply` + map + `env_snapshot_map` + precondition → **`fio_smoke_real`（parser 校正）** → calibrate ×2 → `manifest.py generate --assert` → **`bg_collect_start`（v4.1：campaign 級收集在此啟動——所有 execution preflight 的 `bg-collector alive` 由此保證；all.sh 收尾對稱 stop、reconcile 負責 resume 時重啟）** → `calibrate: PASS`。

- [ ] Step 1: 測試先行（順序含 smoke_real、五狀態決策表、CoV gate；canary 用 current-boot 合取證據（boot ID + **unit-scoped** `journalctl -b -u ceph-<fsid>@osd.N`）**且測試中不得出現 pre-reboot cursor 或裸 `journalctl -b`**；`bg_collect_start` 在 `calibrate: PASS` 前——即 steady 第一個 preflight 之前）。
- [ ] Step 2: 實作至 gate 綠。

### Task 13: run/steady.sh + run/faults.sh（薄入口）

**Files:** Create `run/steady.sh`、`run/faults.sh`、`tests/test-steady.sh`、`tests/test-faults.sh`

兩者皆為 `reconcile → manifest next 迴圈 → pipeline_run_execution` 的薄 orchestrator：
- steady：first-cell gate（含 `fio_smoke_real` 已過的斷言）；完成後 `verdict.py margins`（faults 前置檔）。
- faults：margins 前置（`--pilot` 除外）；pilot → `schedule-estimate`（含 PILOT-CENSORED 分支）→ 人工放行；每 cell n=2 後 `need-more-n` → `manifest.py amend`；12h 回報（含 **az 登入態唯讀檢查**（v4.2/F5-7）——watchdog 2b 的救援憑證在 hour 60+ 可能失效，失效即早警示為 pre-HUMAN 事件）+ `budget-warning`。
- [ ] Step 1: 測試先行（薄入口只做編排、不繞過 pipeline；margins/pilot gate；amend 接線）。
- [ ] Step 2: 實作至 gate 綠。

### Task 14: run/chaos.sh + run/all.sh

**Files:** Create `run/chaos.sh`、`run/all.sh`、`tests/test-chaos-all.sh`

- chaos：manifest 驅動 3 executions，走同一 pipeline（chaos 也有 prediction/verdict/finalize，round2/F21）。
- `all.sh` 收尾順序（round2 blocker 10 修正）：faults/chaos 完 → 停全部注入/fio（reconcile 級掃描）→ `ceph_campaign_unflags` + `client_tuning_restore` → `sampler`/`bg_collect` 全停 → **資料集封閉**（不再有 writer）→ `verdict.py audit`（唯讀）→ `campaign: DONE`。audit FAIL 也不會留下 flags/writer。
- [ ] Step 1: 測試先行（收尾順序、audit 唯讀、audit FAIL 不留殘態）。
- [ ] Step 2: 實作至 gate 綠。

### Task 15: README runbook

**Files:** Create `README.md`；`.gitignore` 收尾

README = campaign runbook：前置 gate 清單（使用者刪舊 lab、IaC inventory+attestation、verify-provision PASS、HYPOTHESES gate、campaign plan 核可、**bastion 前置檢查（v4.2/F5-10）：`caffeinate` 防睡眠、接電源、網路穩定、TCC 權限正常**）、Replicate Pipeline 圖解、執行順序、人工 gate 節點（first-cell / pilot 放行 / **PILOT-CENSORED 分支處理** / **capacity-dispersion-high remediation** / **drift recalibrate 裁決**）、reconciler 使用時機、watchdog HUMAN-NEEDED 處理指引（**明列預期怠轉成本：停佇列不停機 ≈ $8/hr，最壞 12h 無人回應 ≈ $100——這是明示接受的 tradeoff**）、az preflight 與 12h 登入態檢查說明、12h 回報樣式、descope 階梯操作、teardown 交還 IaC 的 checklist（bundle audit 過才准刪 RG）。

- [ ] Step 1: 撰寫 + gate 綠。

### Task 16: 收尾 gate + Phase 3–5 plan 草案

- [ ] `tests/gate.sh` 全綠；commit + push。
- [ ] **產出 Phase 3–5（campaign + synthesis）plan 草案**至 `docs/superpowers/plans/`（round2/F28：不只是承諾——真機執行順序、gate、報告產出流程；Phase 3 開跑 gate 以它為準）。
- [ ] 回報使用者：**Phase 1–2 harness ready**；等 IaC inventory+attestation、舊 lab 刪除、HYPOTHESES gate、campaign plan 核可、說 go。
