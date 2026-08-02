# ceph-mclock-profiles — Campaign Runbook

> **讀者**：之後要真的按著這份跑一次 72h+ 真機 campaign 的人（很可能是幾週後的你自己）。
> **狀態**：Phase 1–2（Frame + Automate）已完成，harness 可運作；**Phase 3 尚未開跑**。
> **上位文件**：
> - spec（rev 8）：`docs/superpowers/specs/2026-07-24-ceph-mclock-profiles-azure-design.md`
> - harness plan（v4.5）：`docs/superpowers/plans/2026-07-24-ceph-mclock-profiles-harness.md`
> - campaign plan（Phase 3–5）：`docs/superpowers/plans/2026-07-25-ceph-mclock-profiles-campaign.md`
> - 假說 backlog：`HYPOTHESES.md`｜provisioning 契約：`PROVISIONING-REQUIREMENTS.md`
>
> 本檔只講**怎麼跑**。為什麼這樣設計看 spec，每個函式的契約看 plan 與各 lib 的檔頭註解。

---

## 0. 一頁摘要

| 項目 | 內容 |
|---|---|
| 研究對象 | Ceph v19.2.2 的 mClock 三個內建 profile（`balanced` / `high_client_ops` / `high_recovery_ops`） |
| 環境 | Azure japanwest，15 台 VM（8 OSD node + 1 admin/mon + 2 mon + 4 fio client） |
| 矩陣 | 63 cells / 147 executions（穩態 72、故障 72、chaos 3） |
| 時程目標 | 72h wall-clock（無硬上限；跨 96h 通知使用者一聲但不停機） |
| 成本 | compute ≈ **$8.03/hr**，全程估 $620–850，天花板 US$1000 |
| 執行者 | bastion = 本機 macOS；全程 ssh-native，campaign 期間只有兩個 az 例外（watchdog 2b 的 `az vm restart`、12h 回報的唯讀 `az account show`） |
| 入口 | `run/all.sh --yes-really-inject`（或分段跑，見 §3） |
| 產物 | `results/`（git-ignored 的 evidence bundles）+ `EVIDENCE-SUMMARY-<date>.md`（進 git） |

**一句話流程**：`calibrate` → `steady`（negative control）→ `faults --pilot` → `faults` → `chaos` → `finalize`（audit）→ 交還 IaC 刪 RG。

---

## 1. 開跑前的 gate 清單

**全部要過才准下 `run/all.sh`。順序不可跳。**

### 1.1 使用者手動前置（AI 不碰）

- [ ] **刪除 japanwest 的舊 lab RG `CYSHIH-KUBEVIRT-CEPH-LAB`**。這是硬前提：LSv3 family quota 上限 65 vCPU，本實驗要 64，舊 lab 不刪就湊不出 8 台 L8s_v3。
- [ ] 確認三層 quota 有餘裕（Regional 88 / LSv3 64 / DSv5 24），證據 = `az vm list-usage -l japanwest` 的輸出留檔。
- [ ] bastion 的 `az login` 有效，且該 subscription 對目標 RG 有寫入權限。

### 1.2 IaC agent 交付物

- [ ] `azure/inventory.json`（15 台的 name/ip/rack/nvme + `admin_public_ip` / `admin_private_ip`）
- [ ] `azure/attestation.json`（IaC 對 desired state 的自證，含 `generated_at`、`subscription_id`、費率）

兩個檔都是 git-ignored。契約細節見 `PROVISIONING-REQUIREMENTS.md` §8。

### 1.3 `azure/verify-provision.sh` 必須 PASS

```bash
bash experiments/ceph-mclock-profiles/azure/verify-provision.sh
# 機器行：verify-provision: PASS <n>/<total>   （FAIL 即 exit 1）
```

其中 `os-version` / `kernel-version` 兩條是**生產對映的硬 gate**：15 台必須是 **Ubuntu 22.04 (jammy)**（`VERSION_ID="22.04"`）且 `uname -r` 為 `6.8.*`（`linux-generic-hwe-22.04`，不是 `linux-azure`）。client IO 走 krbd = kernel 內的 RBD client，kernel 版本不對映生產，profile 對照的結論就外推不到生產。期望值可用 `OS_VERSION_EXPECT` / `KERNEL_VERSION_EXPECT` 覆蓋，但**改期望值等於改實驗前提**，要在報告的 limitations 交代。

這支同時完成 **campaign 前唯一的 az preflight**：`az account show` 的登入態、subscription 與 attestation 一致、RG 權限——也就是 watchdog 2b（`az vm restart`）的救援憑證預檢。attestation 是**驗值**不是驗存在：boolean 要等於期望值、費率 > 0、`generated_at` 在 24h 內。

任一條 FAIL → **退回 IaC agent**，不要自己在 VM 上手動補。手動補過的環境無法被 attestation 覆蓋，等於整場 campaign 的環境前提失去單一 SoT。

### 1.4 HYPOTHESES gate

- [ ] `HYPOTHESES.md` 已貼給使用者過目，且 §「讀碼結果與 plan / spec 敘述的出入」與 §Triage 的裁示已回填。
- [ ] §「預註冊生產門檻」四個 primary endpoint 的絕對門檻已定案——這是 `verdict` 區分「等效」與「靈敏度不足」的唯一依據，開跑後不得再改（改了等於事後移動球門）。

### 1.5 bastion 前置檢查（macOS 本機）

72h 的 campaign 全靠這台筆電的 ssh 連線活著。開跑前逐條確認：

- [ ] **接電源**，且電源設定不會在閒置時睡眠。
- [ ] 開跑指令一律包 `caffeinate`：

  ```bash
  caffeinate -dimsu bash run/all.sh --yes-really-inject 2>&1 | tee -a /tmp/mclock-campaign.log
  ```

  （`-d` 防螢幕睡、`-i` 防閒置睡、`-m` 防磁碟睡、`-s` 接電源時防系統睡、`-u` 宣告有使用者活動。）
- [ ] **網路穩定**：用有線或穩定 Wi-Fi，別用會換 IP 的熱點。NSG 只放行使用者來源 IP，換 IP = 全部 ssh 斷線 = watchdog 誤判成 node 失聯。
- [ ] **TCC 權限正常**：終端機對「文件檔案夾」的存取權還在。指紋 = `stat` 過得了但 `open`/`readdir` 全 `EPERM`。開跑前跑一次 `ls experiments/ceph-mclock-profiles/lib >/dev/null` 確認。
- [ ] ssh key 可用：`ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none ikaros@<admin_public_ip> true`。
- [ ] 本機時鐘同步（bundle 的絕對時間軸要跟 node 對齊）。

### 1.6 harness 自身 gate

```bash
bash experiments/ceph-mclock-profiles/tests/gate.sh
# gate: PASS  = run-tests + shellcheck（含 info 級）+ make validate 三段全綠
```

### 1.7 Phase 1–2 掃出的三個缺口（Task 0 已補）

收官時掃出三個「單元測試綠但真機會擋路」的缺口，已在 Phase 3–5 plan 的 Task 0 補完：

| 缺口 | 現在的做法 |
|---|---|
| ~~沒有 profile 切換~~ | `lib/ceph.sh::ceph_set_profile <profile>`（冪等；三個合法 profile 之外 die），由 `lib/pipeline.sh` 的 preflight 在 `ceph_qos_gate` **之前**呼叫。設定只負責下指令，**是否生效仍由 gate 判定**；campaign 收尾由 `ceph_campaign_unflags` 對稱移除 |
| ~~descope 沒有佇列端效果~~ | `results/descope.json` 是 merge 視圖的第五種狀態 `descoped`：`manifest.py view` 標示、`next` 跳過、`counts.descoped` 獨立計數（§7.3 已改為單步操作） |
| ~~`halted` 沒有解除路徑~~ | `run/unhalt.sh "<理由>" [--clear-counts]`（= `_pipeline_py state <path> unhalt`）：清 `halted`／`halt_reason`、**保留** trigger counts 與 drift streak、留痕進 `unhalt_log`（§4.7） |

---

## 2. Replicate Pipeline（唯一流程 SoT）

steady / fault / chaos 走**同一台狀態機**（`lib/pipeline.sh::pipeline_run_execution`），差別只在 manifest 的 `fault_params`。順序不可變：

```
 claim（results/<cell>/<rN>/.claim；mkdir 原子 + 心跳 + stale 接管）
   │
   ├─ preflight ── ceph_qos_gate <profile>（osd_op_queue=mclock_scheduler + 九參數
   │               + 鎖定 capacity + skip_benchmark=true + mon store 來源反向斷言）
   │            ── final_clean
   │            ── bg-collector alive（campaign 級，calibrate 啟動的）
   │
   ├─ prediction freeze（verdict.py freeze；寫入後 sha256 不可變）
   │
   ├─ sampler_start（replicate 級，5s 粒度）→ sampler_assert_alive
   │      ※ 先 start 才 assert，順序不可倒
   │
   ├─ fio 啟動（背景 segment 模式，4 client 平行）
   │   └─ readiness barrier：ramp 完成 + 60s throughput 穩定窗
   │      ★ 這 60s 窗 = within-replicate 的「注入前健康基線」
   │        primary endpoint「p99 degradation ratio」的分母優先用它
   │        （跨日的穩態 cell 只當次要對照，防 72h 校準漂移污染）
   │
   ├─[fault]─ 記 fault_t0（絕對 epoch）
   │          → measurement_deadline = fault_t0 + measurement_cap（持久化）
   │          → 注入（fio 持續跑，故障發生在 workload 進行中）
   │
   ├─ 量測窗 ── stop-condition = recovery_complete ‖ measurement_deadline
   │            （撞 cap = right-censored，**仍是有效觀測**，不是失敗）
   │         ── coverage supervisor：固定 30s cadence，查 sampler + 各 fio client heartbeat
   │            持續 gap（連續 3 次）→ 該 attempt 標 taint，但量測繼續跑完以保叢集安全回收
   │         ── finalize 前做時間軸連續性驗證 → coverage-proof.json
   │
   ├─ 停 fio（收 exit proof）→ 回歸（heal / daemon start + osd in）
   │
   ├─ safety gate ── 等 final_clean（PG 10min 零進展 → watchdog pg-no-progress）
   │              ── 記 H-008 兩時戳（回歸開始 → final_clean）+ 該區間 recovery bytes/s
   │                 → return-backfill.json（全實驗唯一 best_effort `lim` 會 binding 的場景）
   │
   ├─ baseline 復測（60s，同形態同壓力固定速率）→ verdict.py baseline-check（drift gate）
   │
   ├─ sampler_stop → collect_cell → aggregate → verdict
   │              → verdict.py schemas <kind> --verify（cell/profile/manifest-hash/時間窗交叉核對）
   │              → bundle_finalize（per-kind required-files schema 全過才原子寫 DONE）
   │
   └─ release claim
```

任何出口（成功 / 失敗 / 中斷）都走同一個 cleanup stack，LIFO 固定為：**停 fio → 回退注入 → sampler_stop → 釋放 claim**。

### 兩層 clean 判準（全文唯一定義）

| 判準 | 定義 | 用在哪 |
|---|---|---|
| **`recovery_complete`** | 以**當下 up set** 為準，PG 100% `active+clean`（degraded/misplaced 歸零）。managed-out 的故障中，backfill 完成時 target 仍 down+out——**這就是量測終點** | fio segment 的 stop-condition、censor 判定 |
| **`final_clean`** | OSD **全部 up+in** + PG 100% `active+clean` + health 除 harness 自設的 `noscrub`/`nodeep-scrub` 外無其他 warning/error | replicate 收尾、baseline 復測前、reconcile 放行、watchdog 成功判準 |

**絕不可用字面 `HEALTH_OK` 判定**——campaign 全程掛著 noscrub flags，那會永久 timeout。

### Reconciler（每個 run 腳本啟動時必跑）

1. **單 runner lock**（`results/.runner.lock`，mkdir 原子 + pid + 心跳；stale 逾時 `RUNNER_LOCK_STALE_SECS`=1h 後接管）。
2. 殘留掃描：全 OSD node 的 `MCLOCK-ISO` chain flush、非預期 down/out 的 OSD（start + in）、`/run/mclock/` registry 的殘留 fio/sampler/guard（`bgc-*` 的 campaign 級 collector **不殺**）、未 finalize 的 attempt 標 `ABORTED`。
3. bg collector 存活檢查（死了就 restart——這是 resume 路徑的 collector 啟動點）。
4. 等 `final_clean` 才放行 `manifest next`。

---

## 3. 執行順序

### 3.1 一鍵入口

```bash
cd experiments/ceph-mclock-profiles
caffeinate -dimsu bash run/all.sh --yes-really-inject 2>&1 | tee -a /tmp/mclock-campaign.log
```

段落：`calibrate` → `steady` → `faults-pilot` → `faults` → `chaos` → `finalize`。
每段成功寫 `results/.stage-<name>.done`，重入直接 `all: STAGE <name> SKIP`。

> **⚠️ `--resume` 是共用旗標，會一次放行兩道人工 gate。**
> `all.sh --resume` 會把 `--resume` 同時傳給 `steady.sh` 與 `faults.sh --pilot`。也就是說：你為了通過 first-cell gate 而帶上的 `--resume`，會連 pilot gate 一起自動放行。
> **建議做法**：human gate 之前的段用 `all.sh`，遇到 gate 之後改用 §3.2 的分段指令逐段放行；或明知並接受 pilot gate 被自動放行（PILOT-CENSORED 的 exit 11 仍會擋，那道不受影響）。
> 另外：**第一次啟動絕對不要帶 `--resume`**，否則 first-cell gate 直接被跳過。

### 3.2 分段執行（推薦）

```bash
cd experiments/ceph-mclock-profiles

# 1. 校準（部署 + capacity lock + reboot canary + 壓力等級 + manifest + bg collector）
bash run/calibrate.sh --yes-really-inject          # → calibrate: PASS

# 2. 穩態第一個 cell（negative control 的首跑）→ 停在 first-cell gate（exit 10）
bash run/steady.sh --yes-really-inject             # → steady: FIRST-CELL-GATE <cell>/<rN>
#    人工檢查 bundle 後放行，跑完全部 72 個穩態 execution + 產 margins.json
bash run/steady.sh --yes-really-inject --resume    # → steady: PASS done=72/72 ...

# 3. 故障 pilot（每故障型的預期最慢組合 × r1）→ 停在 pilot gate（exit 10）
bash run/faults.sh --yes-really-inject --pilot     # → faults: PILOT-GATE bundles=<n>
#    人工檢查 results/schedule-estimate.json 後放行（只做 cap 推導，不續跑全佇列）
bash run/faults.sh --yes-really-inject --pilot --resume   # → faults: PILOT-PASS

# 4. 故障全佇列（需要步驟 2 產出的 margins.json）
bash run/faults.sh --yes-really-inject             # → faults: PASS done=72/72

# 5. chaos（3 executions，同 seed 跨 profile）
bash run/chaos.sh --yes-really-inject              # → chaos: PASS done=3/3

# 6. 收尾（reconcile → unflags + tuning restore → 停 collector → 封閉 → audit）
bash run/all.sh --yes-really-inject --resume       # 前面的 stage marker 會全部 SKIP
```

步驟 6 之所以走 `all.sh`：收尾順序（回退 flags 與 tuning **在 audit 之前**、且不因 audit 結果改變）只在 `all.sh::_all_finalize` 裡實作，run/ 的其他入口沒有這段。若前面是分段跑的，先手動補上 stage marker 讓它跳過已完成的段：

```bash
for s in calibrate steady faults-pilot faults chaos; do : > results/.stage-$s.done; done
bash run/all.sh --yes-really-inject --resume
```

### 3.3 斷點續跑

| 段 | 續跑機制 | 備註 |
|---|---|---|
| `calibrate.sh` | 每步驟寫 `results/calibrate/<step>.done`，重入跳過；journal 在 `results/calibrate/journal.log` | 任一步失敗即 die **停在原地**，修好後重跑會從斷點續。`--redo <step>` 清單一步驟的 marker |
| `steady` / `faults` / `chaos` | `reconcile` → `manifest.py next` 只回還沒有 `results/<cell>/<rN>/DONE` 的 execution | 未 finalize 的 attempt 會被 reconcile 標 `ABORTED`，該 replicate 下一輪重跑 |
| `all.sh` | `results/.stage-<name>.done` | 段內續跑交給該段自己 |
| 全域狀態 | `results/schedule-amendments.json`（append-only JSONL，唯一持久 SoT）、`results/watchdog-state.json`（計數 / halted / drift streak 鏡射，resume **不重置**）、`results/baseline-drift-state.json`（逐組合 drift 計數，停佇列判準的 SoT） | crash 後重讀即恢復 |

**`--redo` 的紅線**：`raw-nvme-baseline` 在 `deploy` 完成後一律拒絕重跑——OSD 建立後直打 raw device 會毀掉 BlueStore。腳本內有順序不變條件，`fio_raw_nvme_baseline` 內另有 blkid / `ceph-volume inventory` 的 RAWGUARD，兩道防線都在。

### 3.4 exit code 對照

| code | 意義 | 出現在 |
|---|---|---|
| 0 | 正常完成 | 全部 |
| 1 | 錯誤（含 audit FAIL） | 全部 |
| 3 | **佇列被 watchdog 停**（`watchdog: HUMAN-NEEDED`）或 `manifest next` 佇列耗盡（僅內部語意） | steady / faults / chaos / all |
| 10 | **人工 gate 等放行**（first-cell、pilot）——不是失敗 | steady / faults / all |
| 11 | **PILOT-CENSORED 等人工裁示** | faults / all |

`all.sh` 對子段的 rc 有轉印：`all: HUMAN-GATE <stage> rc=<10\|11>`、`all: HALTED <stage>`、`all: STAGE <stage> FAIL rc=<n>`。

---

## 4. 人工 gate 節點與處置

> 通則：這些 gate 停的是**佇列**，不是機器。停佇列期間 15 台 VM 照常計費（§5 怠轉成本）。**任何情況都不要 deallocate**。

### 4.1 first-cell gate（`steady: FIRST-CELL-GATE`，exit 10）

**觸發**：穩態第一個 cell 完成後（整場 campaign 的第一次真跑）。前置斷言是 `fio_smoke_real` 已通過（golden log 存在），否則會先印 `steady: SMOKE-MISSING <dir>` 然後 die。

**要看什麼**（bundle 在 `results/<cell>/<rN>/attempts/<ts>/`）：

- `qos.json`：八顆 OSD 的 effective config 是否都收斂到預期 profile，`provenance.forbidden_in_mon_store` 必須是空的。
- `prediction.json` 的 `manifest_hash` 與 freeze sha。
- `fio/` 的三個 log（iops / lat / hist）逐秒是否連續，`aggregate.json` 的 `max_stall` / `p99_ns` 是否落在合理量級。
- `coverage-proof.json` 沒有 taint。
- 對照 `results/calibration.json`：achieved 供給是否接近該壓力的目標速率。

**放行**：`bash run/steady.sh --yes-really-inject --resume`。

### 4.2 pilot gate（`faults: PILOT-GATE`，exit 10）

**觸發**：四個故障型的 pilot（各自的「預期最慢組合」= 最高壓 × `high_client_ops`；node-isolation 只有中壓 cells，其 pilot 退化為中壓 × `high_client_ops`）全部完成、`schedule-estimate` 跑完之後。

**要看什麼**：`results/schedule-estimate.json` 與 `schedule-estimate: cap-update <fault> <secs>` 機器行。判斷 `measurement_cap = max(2700, 2×pilot_recovery_time)` 是否合理，以及 `schedule-estimate: OK <n>h` 的總時程估算有沒有超出預期。

**放行**：`bash run/faults.sh --yes-really-inject --pilot --resume`。放行後**不會**自動接全佇列（全佇列的 `margins.json` 前置在 `--pilot` 模式下被略過，直接續跑等於繞過它）——全佇列要另起一次 `bash run/faults.sh --yes-really-inject`。

### 4.3 PILOT-CENSORED（`faults: PILOT-CENSORED <fault,...>`，exit 11）

**觸發**：pilot 自己撞了 measurement cap。此時 recovery 時間只是**下界**，**禁止**餵進 `2×` 公式。

**處置（二選一，都要記入 journal）**：

```bash
# (a) 以 cap×2 重跑 pilot
python3 lib/manifest.py amend --type cap-update --key <fault> --value <cap×2> \
        --source "human: pilot censored at <cap>s" --results results
#     然後清掉該 pilot 的 DONE 重跑，或直接續跑（cap-update 只影響尚未執行者）

# (b) 人工指定 cap
python3 lib/manifest.py amend --type cap-update --key <fault> --value <你決定的秒數> \
        --source "human: <理由>" --results results
```

**重點**：`--resume` 單獨**不足以**繞過這一格。腳本會用 `queue_has_amend cap-update <fault>` 檢查 journal 裡是否已有該故障型的人工 cap-update，沒有就繼續 exit 11。這是刻意的——「按 enter 就過」的 gate 等於沒有 gate。

有裁示之後：`bash run/faults.sh --yes-really-inject --pilot --resume`。

### 4.4 `capacity-dispersion-high`（calibrate 的 `capacity` 步驟 die）

**觸發**：8 顆 OSD 的 `locked_value` 跨顆 CoV > `CAPACITY_COV_LIMIT`（預設 0.20）。這是 spec §4 的異質 NVMe 防線——8 台 L8s_v3 拿到效能差很多的 NVMe，profile 對照就會被裝置異質性污染。

**Remediation（依序試）**：

1. 讀 `results/capacity-lock.json` 與 `results/capacity-provenance.json`，找出 outlier 是哪顆、`bench_status` 與 `raw_fio_iops` 差多少。
2. **對 outlier OSD 重測**：

   ```bash
   ceph config set osd.<N> osd_mclock_force_run_benchmark_on_init true
   ceph orch daemon restart osd.<N>
   # 等 OSD up + final_clean 後
   ceph config rm osd.<N> osd_mclock_force_run_benchmark_on_init
   bash run/calibrate.sh --yes-really-inject --redo capacity
   ```

   （`force_run_benchmark_on_init` 只保證**重跑**、不保證結果被接受，且需要重啟。）
3. 重測後仍離散 → **operator override**：人工決定該顆的鎖定值，直接改 `results/capacity-lock.json` 的 `locked_value`，**並在同一筆記上 provenance**（誰、何時、依據哪個 raw fio 基線、為什麼），再 `--redo capacity`。override 過的顆數與理由必須寫進最終報告的 limitations。
4. 若離散來自真正的硬體差異且無法收斂 → 這是「環境不符合實驗前提」，退回 IaC 重建那幾台，而不是硬跑。

**不變條件**：`locked_value` 不得等於 compiled default（21500）。決策表撞到就自動偏移 1 IOPS——值 == default 會讓每次 boot 重跑 bench（H-012），那是 `skip_benchmark` 之外的第二道防線。

### 4.5 `capacity-decide: HUMAN-NEEDED`（calibrate die）

**觸發**：某顆 OSD 的 `bench_status` = `failed` / `no-result`（bench 執行錯誤或 log 缺失），或決策表湊不齊 8 顆。**決策表不得自動選值**——猜一個 capacity 等於讓整場實驗的 cost model 分母是假的。

**處置**：讀 die 訊息指名的那顆，查 `journalctl -b -u ceph-<fsid>@osd.<N>`，確認是 bench 真的失敗、還是 log 管道問題。修好之後 `--redo capacity`。

### 4.6 baseline drift：同一組合連續 3 次（佇列停，`recalibrate` 裁決）

**觸發**：`verdict.py baseline-check` 對每個 replicate 的 60s baseline 復測有兩個判定——(a) 供給達成率（achieved/target）< 85%；(b) baseline p99 相對**同條件參考中位數**的偏移超過**該組合自己的容忍值**（`max(15%, 3 × MAD)`，見下方「門檻依實測解析度逐組合校準」）。單次只印 `baseline-drift <metric> <pct> tol=...` 並記 covariate；**同一個 (形態, 壓力, backfill 類別) 連續 3 個 replicate** 超標才停佇列（`PIPELINE_DRIFT_LIMIT`，由 `--drift-limit` 傳給 `verdict.py`）。

**「連續」的母體 = (形態, 壓力, backfill 類別)，與門檻同粒度**（2026-08-02 的第五次假停佇列）：門檻在 2026-08-01 已改成逐組合依實測 MAD 校準，但「連續 N 次」的計數器仍是全域的。造成那次停機的三筆**跨了兩個母體**：

| # | cell | 組合 | shift | 該組合門檻 |
|---|---|---|---|---|
| 1 | `rack-isolation-4k-low+balanced` | low/backfill | +243.08% | 87.75% |
| 2 | `rack-isolation-4k-mid+high_client_ops` | mid/backfill | +41.29% | 15.48% |
| 3 | `rack-isolation-4k-mid+high_recovery_ops` | mid/backfill | +498.73% | 17.20% |

「連續 3 次漂移」的語意是「**同一個量測母體**連續 3 次偏離」，不是「三個互不相干的母體各出現一次離群值」。而佇列是 Latin square 輪替執行、各組合本來就交錯出現，全域計數必然把獨立事件串成假的「連續」。**決定性反證**：`4k/mid/backfill` 的注入前窗（主指標 `p99_degradation_ratio` 的分母）跨 5 天 9 個 attempt 是 `3.228–3.424 ms`（全距 **6%**），而善後復測是 `4.489–30.802 ms`（6.9×）；那筆 30.8 ms 對應的注入前窗是 3.391 ms——**叢集完全正常，抖的只有善後復測這個量**。

**兩條軸都逐組合**：`achieve-ratio` 量的是「fio 有沒有打到目標速率」，而目標速率本來就隨 (形態, 壓力) 而異（低/中/高壓各是 ceiling 的 25/50/80%）；而且 baseline 是善後復測，backfill 還在排的時候供給達成率本來就會掉——backfill 類別同樣是它的母體邊界。兩條軸共用同一個母體鍵，在鍵底下**各自**計數（兩條軸「量得到與否」不同步，共用一個計數器會讓 p99 盲的 cell 被 achieve-ratio 的乾淨結果抹掉證據）。

**停佇列判準只有一個**：`verdict.py baseline-check` 的 `rc=4`。`lib/pipeline.sh` 的 `_pipeline_baseline_gate` **不再自己數、也不再據 `drift_streak` 停佇列**——pipeline 只看得到 stdout，它不知道這格屬於哪個組合，自己數出來的必然是跨母體的全域數字。它現在只做兩件事：(1) 把 `verdict.py` 回報的**該組合** streak 鏡射進 `watchdog-state.json` 的 `drift_streak`（純可觀測性；解析不到就維持不變，不憑空歸零）；(2) `rc=4` → 停佇列。**同一套政策不再實作兩次**（本 repo 已有四次「修正本身造成迴歸」的前例，見 `HYPOTHESES.md` H-032 / H-036）。

**可觀測性**：每次 `baseline-check` 都會印一行

```
baseline-check: streak combo=4k/mid/backfill n=2 limit=3 achieve-ratio=0 baseline-p99=2
```

`baseline-check.json` 同步記 `drift_combo` / `drift_scope`（= `combo`）/ `drift_axes` / `drift_limit` / `consecutive_drift`（**該組合**的 streak）。判準的粒度與門檻都寫在輸出裡——**判準不可以悄悄變動而看不出來**。

全 campaign 依時序回放（134 個 attempt、真 CLI、`/tmp` 沙箱、逐格增量搬入以還原「當下的參考池」）：

| 版本 | 全 campaign 訊號次數 | 停佇列次數 | 停在哪 |
|---|---|---|---|
| 全域計數（修正前） | 10 | **1** | `20260802T024023Z`（`4k/mid/backfill`）——第 5 次假停機；前一筆訊號在 `4k/low/backfill`，跨母體 |
| 逐組合計數（修正後） | 10 | **0** | 最長 streak：`4k/low/backfill` 2 次、`4k/mid/backfill` 2 次 |

**偵測力保留驗證**（沙箱內只讓**一個**組合從第 4 個 attempt 起全部 ×2 再回放）：

| 被劣化的組合 | 停佇列？ | 停在哪 | 停在正確的組合？ |
|---|---|---|---|
| `4k/low/nobackfill` | ✅ `rc=4` | 該組合第 3 個劣化 attempt（`20260726T200233Z`，+88.83%） | ✅ `combo=4k/low/nobackfill` |
| `4k/mid/nobackfill` | ✅ `rc=4` | 該組合第 3 個劣化 attempt（`20260726T213555Z`，+98.14%） | ✅ `combo=4k/mid/nobackfill` |
| `4k/mid/backfill` | ✅ `rc=4` | 該組合第 3 個連續訊號（`20260731T175023Z`，+91.36%） | ✅ `combo=4k/mid/backfill` |

`4k/low/backfill` 在 ×2 下**仍抓不到**——那是它自己 87.7% 門檻的已知限制（見下方「已知限制」），與計數粒度無關。

**「同條件」= 同 (形態, 壓力, backfill 類別)**：這個 baseline 是「注入 → 回復 → final_clean 之後」的復測，量到的是**善後成本**。真機實測（DONE 且未 tainted 的 attempt，單位 ms）：

| shape/pressure | none | flapping | osd-down | node-isolation |
|---|---|---|---|---|
| 4k/low | 2.834 (n=9) | 3.015 (n=4) | **4.284 (n=6)** | — |
| 4k/mid | 3.523 (n=9) | 3.654 (n=6) | **5.210 (n=3)** | **4.817 (n=1)** |

**分界不是故障型，是「有沒有觸發 backfill」**：flapping 與穩態只差 3.7%（4k/mid）與 6.4%（4k/low），因為 flapping 全程 `noout`、OSD 從未被標 out；真正把復測拉高的是被 `ceph osd out` 之後的 backfill。所以參考池按二元類別配對，判準**從 manifest 已宣告的 `fault_params` 推導**（不硬編故障型清單）：

| `fault_params` | 故障型 | 類別 |
|---|---|---|
| `manual_out: true` | osd-down / node-isolation / rack-isolation / **seq-contention**（它的機制就是 osd-down） | backfill |
| `no_out: true` / `{}` | flapping / none | 非 backfill |
| （皆無） | chaos | **保守歸 backfill**（見下） |

> chaos 的注入路徑（`lib/inject.sh` 的 `chaos_run`）只 `ceph_daemon_stop` + `_inject_osd_start_only` / `_inject_node_rollback`，**沒有任何 manual out**（`ceph_osd_out` 只在 `fault_osd_down` / `fault_node_isolate` 兩個包裝函式裡，chaos 走的是 `_inject_node_isolate_core`，繞過它）；單一事件 hold ≤ `CHAOS_HOLD_MAX=180s` < `mon_osd_down_out_interval=600s`（實測 config-show）。**但** chaos 與 flapping 不同，全程沒有設 `noout`，也沒有「被 out 就作廢」的斷言，只要有一次 `osd-start` 失敗（`chaos_run` 對失敗只記 log 續跑），OSD 留在 down 超過 600s 就會被 auto-out 而觸發 backfill。判不定 → 保守歸 backfill。

參考值取 campaign 內先前**同條件、已 finalize（有 `DONE`）且未 tainted** 的 replicate 中位數（`reference_source = campaign-median-backfill(n=N)` 或 `campaign-median-nobackfill(n=N)`）。tainted 的 attempt 是 harness 自己判定「不得作為有效 replicate」的量測，不得當基準（實測 117 個 attempt 裡有 18 個是這種）。

**量不到就明講**：同條件樣本 < 3（含 `prediction.json` 損毀或判不出類別）時退回校準值（`reference_source = calibration`），stdout 印 `baseline-check: OK covariate-only class=<類別> n=<樣本數>`，**值仍記進 `baseline-check.json`（`p99_shift` / `baseline_p99_ns` / `measured: false`）當 covariate，但不判漂移**。連續計數**維持不變**（不是歸零）——「量不了」≠「沒漂移」，佇列成塊執行，跨 group 邊界必然出現數格 covariate-only，在那裡歸零會把先前累積的證據反覆抹掉。

`baseline-drift-state.json` 的 schema：**`combos.<形態>/<壓力>/<類別>` 底下逐軸記**（`axes.achieve-ratio` / `axes.baseline-p99`），因為兩條軸「量得到與否」不同步；該組合的 `consecutive` = 兩軸最大值，門檻仍是連續 3 次，且**只有本次真的量到且超標**才會升級成 `HUMAN-NEEDED`（殘留計數不會讓一格「量不了」的 cell 停佇列）。頂層的 `combo` / `consecutive` / `axes` / `recent` 是**當前這個 execution 所屬組合**的鏡射（相容舊讀法、也讓人一眼看出這次計的是誰），別的組合的計數只存在 `combos` 底下。分類判不出來的走 `<形態>/<壓力>/unknown` 這個桶（那條路徑本來就只有 achieve-ratio 量得到）。

**舊格式遷移**：舊檔是全域的 `{"axes": {...}, "consecutive": N}`。那個 `N` 是把不同母體串起來累加出來的，**無法歸屬到任何單一組合**，繼承它等於把已知無效的「連續」搬進新語意——所以**一律捨棄**、各組合從 0 起算，被丟掉的值留痕成 `legacy_consecutive_dropped`。型別壞掉的狀態檔（人工手改壞了等）走同一條路：當成空的重建，**不得讓 `baseline-check` 以 `rc=1` 死掉**（`rc=1` 會被 pipeline 靜默吞掉 → 偵測失效偽裝成通過）。

**已知盲區（實測，剩餘 55 格排程）**：按此二元分組還有 **6/55 格（11%）** 拿不到 ≥3 個同條件樣本而只能 covariate-only——`seq-contention-seq-mid` 3 格、`seq-contention-seq-extreme` 2 格（seq 形態下完全沒有其他 backfill 類別的先前樣本）、`osd-down-4k-extreme` 1 格；最長連續盲窗 3 格。（若改按故障型分組則是 20/55 格、36%，含 `chaos-4k-extreme` 3/3 全盲。）另外每個新的 (形態, 壓力, 類別) 組合的**前 3 個** replicate 必然盲（`BASELINE_REF_MIN_SAMPLES=3` 且排除自己）。

**門檻依實測解析度逐組合校準**（`max(15%, C × MAD)`，`C = 3`）：15% 這個全域常數對 11 個 (形態, 壓力, backfill 類別) 組合裡的 **9 個就是實測解析度**，但對其餘幾個低於儀器自己的抖動。2026-08-01 的假停佇列即由此而來——三筆訊號是 `+203.61%` / `+129.25%` / **`−31.55%`**，第三筆比參考基準**快**，劣化不會產生這種讀數。逐組合量離散度（DONE 且未 tainted 的 attempt，`MAD_pct = median(|x − median|) ÷ median`）後改為：

```
容忍值(組合) = max(0.15, 3 × MAD_pct(該組合的參考池))
```

參考池沿用同一份 `_prior_baselines` 結果（不另外取樣），下限 0.15 **永不下降**，所以這個改動只會在「該組合自己量到的抖動大於 15%」時放寬，方向單一，**已完成的 112 格資料一格都不受影響**（主指標 `p99_degradation_ratio` 的分母是**注入前**窗，實測 MAD 1.1–9.5%，本來就穩定）。各組合實際生效的容忍值：

| 組合 | n | 善後復測 MAD | 生效容忍值 | 來源 | 抓得到的最小劣化倍數 |
|---|---|---|---|---|---|
| 4k/extreme/backfill | 7 | 7.2% | **21.5%** | MAD | ×1.22 |
| 4k/extreme/nobackfill | 14 | 2.0% | 15.0% | 下限 | ×1.15 |
| 4k/high/nobackfill | 9 | 2.0% | 15.0% | 下限 | ×1.15 |
| **4k/low/backfill** | 11 | **29.2%** | **87.7%** | MAD | **×1.88** |
| 4k/low/nobackfill | 13 | 3.4% | 15.0% | 下限 | ×1.15 |
| 4k/mid/backfill | 7 | 5.2% | **15.5%** | MAD | ×1.15 |
| 4k/mid/nobackfill | 15 | 1.8% | 15.0% | 下限 | ×1.15 |
| seq/extreme/nobackfill | 9 | 2.0% | 15.0% | 下限 | ×1.15 |
| seq/high/nobackfill | 8 | 3.4% | 15.0% | 下限 | ×1.15 |
| seq/low/nobackfill | 9 | 2.6% | 15.0% | 下限 | ×1.15 |
| **seq/mid/nobackfill** | 9 | 10.3% | **31.0%** | MAD | ×1.31 |

**C = 3 是被資料夾出來的，不是挑出來的**——兩條界都來自這份 campaign：

- **下界 2.5**：全 campaign 的 robust-z（`|x − median| / MAD`，n=111）p90 = **2.50**、p95 = 4.42。取 `C ≥ 2.5` 才蓋得住九成的組內正常變異。假停佇列那三筆的 z 是 1.04 / 4.95 / 8.00——`−31.55%` 只離中位數 **1.04 個 MAD**，本來就不該是訊號。
- **上界 3.42**：最寬的組合（MAD 29.2%）要留住 ×2 劣化的偵測力 → `C × 0.292 < 1.0` → `C < 3.42`。`C = 4.45`（robust 3σ）在那個組合的門檻是 130%，×2 劣化就抓不到了。
- 取整數 3（也正好是慣用的 robust 2σ：`2 × 1.4826 = 2.97`）。

全 campaign 依時序回放（131 個 attempt、真 CLI、`/tmp` 沙箱）：

| C | 全 campaign 訊號次數 | 停佇列次數 |
|---|---|---|
| 0（= 現況全域 15%） | 10 | **1**（即這次的假停機） |
| 1.4826 | 8 | 0 |
| 2.0 | 7 | 0 |
| **3.0（採用）** | **7** | **0**（最長連續 2 次） |
| 4.4478 | 7 | 0 |
| 6.0 | 6 | 0 |

`C = 3` 保留了 7 個訊號（含 `+203.61%`、`+129.25%`、`+100.00%` 這些真的離群的讀數）——**孤立離群值本來就該記訊號**，連續 3 次才停佇列。合成劣化驗證（沙箱內把 campaign 中段之後的所有復測乘上劣化倍數再回放）：×1.5 與 ×2 在 `C = 3` 都仍會停佇列，且**首次停佇列的時間點與 C=0 完全相同**（例如劣化起於 07-30 → 兩者都停在 `20260730T033747Z`）。

> **已知限制：重尾組合的偵測力本質上較低。** `4k/low/backfill` 的善後復測是**雙峰**的——backfill 排乾 ≈2.9–4.1 ms、沒排乾 ≈9.5–12.4 ms（全距 4.3×），這是真實的物理變異不是量測噪音（按故障型再細分也沒有變窄：osd-down 子集 MAD 24%、rack-isolation 子集 27.7%，反而樣本不足）。它的生效門檻 87.7% 代表**要 ×1.9 以上的劣化才抓得到**，×1.5 抓不到。這不是被這次改動弄壞的——15% 門檻在那個組合的訊號率是 **73%**（11 筆有 8 筆超標），等於擲硬幣，那種「偵測」不帶任何資訊、而且保證遲早湊成連續 3 次假停機。叢集層級的劣化仍由其餘 10 個緊的組合負責偵測。若這個組合日後又反覆送訊號，正確的下一步是**把它改記 covariate-only**（承認那個組合沒有偵測力），而不是再把 C 調大——調大會連 ×2 劣化都放過。

**結構性限制**：參考池由 campaign 自身產生，所以對**漸進式**劣化靈敏（中位數落後於當前值），對**階梯式**劣化靈敏度低——階梯發生後三個 replicate 就會把新水位寫進參考池，之後的偏移量會回落到容忍帶內。要抓階梯式劣化得靠 `covariate` 欄位事後回看（`reference_p99_ns` 的時間序列），不能只依賴這個 gate。

**要判什麼**：72h 內 Azure 鄰居效應、NVMe 溫度 / GC、BlueStore compaction 都可能讓基準漂走。決策樹：

- 漂移**單向且持續**（例如 achieved 一路下滑）→ 環境已經不是校準時的環境。**重新校準**：
  `bash run/calibrate.sh --yes-really-inject --redo calibrate-4k --redo calibrate-seq`
  並在報告中把 campaign 切成「校準期 A / 校準期 B」兩段，跨段的絕對速率**不可**直接比較。
- 漂移**來回抖動**（同一 cell 有時超標有時不超）→ 噪音升高而非漂移。接受並續跑，但把該時段標進 covariate，report 的 noise margin 要用含這段的資料重算。
- 漂移只出現在**單一 client**（看 `fio/` 各 client 的 per-client log）→ 那台 client VM 的問題，不是叢集漂移。重做該 client 的 unmap/map + smoke。

裁決後要恢復佇列，見 §4.7 的解除步驟。**注意 drift 的連續計數有兩個檔、`unhalt.sh` 只清得掉其中一個**，兩個都要處理（§4.7 步驟 4）。

### 4.7 `watchdog: HUMAN-NEEDED <trigger> <ctx>`（佇列停，exit 3）

**觸發**：watchdog 某個 trigger 的所有自動修復層都用完了（表見 §5）。

**處置流程**：

1. **先看 `ctx`**（通常是 node 名或 mon 名）與 `results/watchdog-state.json` 的 `counts` / `halt_reason`——哪個 trigger、失敗幾次、走過哪些層。
2. 手動確認叢集現況：

   ```bash
   ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none ikaros@<admin_public_ip> \
       'sudo ceph -s; sudo ceph osd tree; sudo ceph health detail'
   ```

3. 修復（人工）。**紅線**：不論怎麼修，**嚴禁 deallocate 任何 VM**——8 台 OSD 的 local NVMe 同時消失 = data plane 報廢，整場 campaign 從 provision 重來。停機只能是使用者親自下的放棄決定。
4. **解除停佇列**（單步，理由必填——會寫進 `watchdog-state.json` 的 `unhalt_log` 留痕）：

   ```bash
   # 一般情況：清 halted，**保留** trigger counts 與 drift streak
   bash run/unhalt.sh "node-ssh-lost：mclock-osd-3 網卡重設後已恢復"
   # unhalt: OK

   # 已確定根因排除（例如 drift 裁決後重新校準完）才一併歸零累積計數：
   bash run/unhalt.sh "baseline drift：已重新校準，切成校準期 B" --clear-counts
   # unhalt: OK cleared-counts
   ```

   ※ `--clear-counts` 會同時歸零 `counts`（各 trigger 的失敗累積）與 `drift_streak`。不帶旗標時兩者都保留——沒排除的累積不該憑空歸零。⚠️ 它**清不到** `baseline-drift-state.json`（真正的判準），見下。
   ※ 佇列本來就沒停時回 `unhalt: NOOP`（不寫留痕）。

   ⚠️ **drift 相關的狀態有兩個檔，只有一個是判準**：

   | 檔 | 誰維護 | 是停佇列判準？ | `--clear-counts` 清得掉？ |
   |---|---|---|---|
   | `results/baseline-drift-state.json` 的 `combos.<組合>` | `verdict.py baseline-check` 自己 | ✅ **唯一判準**（`rc=4`） | ❌ **完全不碰** |
   | `results/watchdog-state.json` 的 `drift_streak` | `lib/pipeline.sh` 鏡射 `verdict.py` 回報的值 | ❌ 純可觀測性（見 §4.6） | ✅ |

   前者是 `baseline-check` 判 `HUMAN-NEEDED recalibrate` 的依據。因為連續計數會跨 covariate-only 的 execution **維持**（見 §4.6），假警報造成的殘留不會自己消失——確認是誤報、或重新校準完之後，要**手動歸零**（目前沒有 CLI 入口，這是唯一需要手改的狀態檔）：

   ```bash
   # 先看現況：combos 底下哪個組合累積了幾次、recent 是哪幾個 bundle
   #（先確認它們確實是誤報；stdout 的 `baseline-check: streak combo=... n=...` 也看得到）
   python3 -m json.tool results/baseline-drift-state.json

   # 確認後整份歸零（沿用 verdict.py 寫入的 schema；缺 combos 會被當舊格式捨棄重建，
   # 兩種寫法都安全）
   printf '{"combos":{}}\n' > results/baseline-drift-state.json
   ```

   不歸零的後果：**該組合**的計數停在門檻邊緣，它下一個「真的量到且超標」的 replicate 會立刻把它推過 3 而再次停佇列——那不是連續 3 次漂移，是拿舊帳停人。（反過來說，沒有訊號的 execution 已經不會因為殘留計數而停佇列，別的組合的計數也不會互相影響，所以這件事不緊急，但報告前一定要清乾淨，否則 `consecutive_drift` 這個 covariate 欄位會是假的。）

   把「做了什麼、為什麼」寫進 journal 留痕：

   ```bash
   python3 lib/manifest.py amend --type needs-human --key <cell_id>/<rN> \
           --value "human: <trigger> 已人工修復，<處置摘要>" --source human --results results
   ```

   ※ 注意 `needs-human` amend 會讓該 replicate（或整個 cell，若 key 不帶 `/rN`）**被佇列跳過**。只是要留痕而想繼續跑該 replicate 的話，改記在 `/tmp/mclock-campaign.log` 或另開筆記，不要用這個 amend type。
5. 續跑該段（`run/faults.sh --yes-really-inject` 等）。reconcile 會先清殘留、等 final_clean 才放行。

### 4.8 taint / abort 預算耗盡（`taint-budget: NEEDS-HUMAN <cell>/<rN> <n>`）

**觸發**：同一個 replicate 連續 3 次（`PIPELINE_TAINT_BUDGET`）taint 或 abort。這是防「系統性成因造成同一 cell 無限重試空轉」的閥。

**行為**：自動寫 `needs-human` 進 amendments journal，佇列**跳過該 replicate 續跑其餘 cells**（不停整條佇列）。

**處置**：不急，但收官前要處理。查該 replicate 的 `attempts/*/` 找共同 taint 原因（coverage gap？guard fired？rack barrier 失敗？），修掉根因後把該筆 `needs-human` 的效力解除——目前 journal 是 append-only 且沒有「撤銷」type，實務做法是**新開一筆說明並手動移除該行**（journal 是 JSONL，移除單行後 `next` 的 merge 視圖即恢復），移除動作要在報告的 incidents 一節記名。

### 4.9 `fio_calibrate` 的 profile 不符（真機首跑最可能踩的一格）

`fio_calibrate` 要求當下 profile 是 `balanced`（校準是共同參考條件，treatment 不得污染 dose），判定方式是 `ceph config get osd osd_mclock_profile`，**依賴 v19.2.2 編譯預設即 `balanced`**。

若這裡 die（`校準必須在 balanced profile 下做（目前 <x>）`），先分清楚**是誰設的**：

**情況 A — 首跑校準（還沒有任何 execution 跑過）**：

> **人工裁決，不可用 `ceph config set osd osd_mclock_profile balanced` 繞過。**

理由：那會把 `osd_mclock_profile` 寫進 mon config store，而 `ceph_qos_gate` 的**來源反向斷言**檢查的正是「QoS / recovery 參數不得來自 mon store」（H-009 / H-018）。雖然 `osd_mclock_profile` 本身不在 `FORBIDDEN_IN_MON_STORE` 清單裡（九個衍生參數才是），但一旦有人為了繞過而設值，就再也分不清「profile 是 harness 設的還是殘留的」，capacity / 九參數的 provenance 論證同時失效。

正確處置：查為什麼不是 balanced（是不是 IaC 交付的 image 帶了 ceph.conf？是不是前一次 campaign 的殘留 mon store？），把污染源清乾淨，而不是往上疊一層設定。

**情況 B — campaign 中途重新校準**（§4.6 的 drift 裁決；已經有 cell 跑過）：這時非 balanced 是 **harness 自己設的**（`ceph_set_profile` 在每個 execution 的 preflight 下 `ceph config set osd osd_mclock_profile <cell 的 profile>`，§1.7）。這不是污染，而是我們自己的 treatment 還掛著。處置是**收掉自己的設定**再校準：

```bash
sudo ceph config rm osd osd_mclock_profile      # 回到編譯預設 balanced
sudo ceph config get osd osd_mclock_profile     # 確認是 balanced 才續跑
```

判別方法：`sudo ceph config dump | grep osd_mclock_profile` 看它的 section 是 `osd`（harness 設的）還是 `global` / `osd.N`（外來污染），並對照 `results/<cell>/<rN>/attempts/*/qos.json` 最後一次通過的 profile。校準完再開佇列時，下一個 execution 的 preflight 會重新把 profile 設回去。

---

## 5. Watchdog：三層自救與紅線

### 三層心智模型

1. **第一層**：停 fio 與故障注入、暫停佇列，試自動修復（daemon restart、`ceph osd in/out` 校正、重跑該 replicate）。
2. **第二層**：reboot 相關 VM——首選 ssh `sudo reboot`（2a），ssh 完全失聯才用 `az vm restart`（2b，campaign 期間唯一的 mutating az 呼叫）。兩者皆不換 host、local NVMe 保留。
3. **第三層（唯一叫人的時機）**：前兩層循環仍無法恢復 → `watchdog: HUMAN-NEEDED`、佇列停。

### Trigger 對照表（trigger-specific，各層計數獨立、修復成功即歸零）

| Trigger | 偵測 | 動作 | 成功判準 | 上限 | 升級 |
|---|---|---|---|---|---|
| `collector-heartbeat` | sampler / bg-collector heartbeat 過期 | **只重啟 collector**（`bg_collect_ensure`）；當前 attempt 標 taint；**不碰 OSD/cluster** | collector heartbeat 恢復 | 2 | 層 3 |
| `fio-heartbeat` | fio client heartbeat 過期 | unmap / map 重做 + `fio_smoke_real`；**不碰 OSD** | smoke 過 | 1 | 層 3 |
| `mon-quorum` | `quorum_status` ≠ 3 | `ceph orch daemon restart mon.<x>` → 等 quorum=3 | quorum=3 + final_clean | 1 | 層 3 |
| `pg-no-progress` | sampler 的 PG 差分 10min 零進展 | restart 相關 OSD | final_clean | 2 | node reboot(2a) → az restart(2b) → 層 3 |
| `node-ssh-lost` | 目標 node ssh 失聯 | 2a：admin 端 ping 留證 → ssh `sudo reboot` | ssh 恢復 + final_clean | 2 | 2b |
| （2b） | ssh 完全失聯 | bastion `az vm restart`（已 preflight） | ssh 恢復 + final_clean | 1 | 層 3 |

**設計紅線（測試有斷言）**：collector 死掉**只重啟 collector**。量測工具故障絕不可以用「動 OSD」去修——那會把工具故障放大成叢集故障，而且會污染正在量的那個 replicate。

### 絕對紅線：嚴禁 deallocate

- harness 本身沒有任何 `az vm stop` / `deallocate` / `delete` 的呼叫路徑，watchdog 的 az 例外只有 `az vm restart` 一格。
- 人工介入時同樣適用：**deallocate = 8 台 OSD 的 local NVMe 內容同時消失 = data plane 報廢**。這只能是使用者親自下的「放棄這場 campaign」決定，不是排障手段。
- teardown（刪整個 RG）是 campaign 收官後、bundle audit 過了才做（§8）。

---

## 6. 怠轉成本（明示接受的 tradeoff）

停佇列**不停機**。這是刻意的取捨：

| 情境 | 成本 |
|---|---|
| 佇列停、VM 全部 allocated | ≈ **$8/hr**（compute $8.03/hr + 雜項） |
| 最壞情況：12h 無人回應 | ≈ **$100** |
| 若改成停機省錢 | local NVMe 資料全失 → 重新 provision + 重跑 calibrate ≈ 6–8h + 重跑已完成的 executions |

**結論：$100 的怠轉遠比重跑一場便宜。** 這是明示接受的 tradeoff，不是疏漏。所以看到 `watchdog: HUMAN-NEEDED` 時的正確反應是「找時間好好排查」，不是「趕快關機止血」。

---

## 7. 進度回報、預算與 descope

### 7.1 12h 回報樣式

`run/faults.sh` 每 `FAULTS_REPORT_SECS`（預設 43200 = 12h）印一次，並在該段結束時再印一次：

```
faults: REPORT done=38/72 elapsed_h=26.50 cost_usd=212 az=ok
```

| 欄位 | 意義 |
|---|---|
| `done=<n>/<total>` | 故障區塊的 execution 完成度（manifest merge 視圖，含 amendments） |
| `elapsed_h` | 自 `results/.campaign-start` 起算的 wall-clock 小時 |
| `cost_usd` | `elapsed_h × FAULTS_HOURLY_USD`（預設 8）——粗估，不含雜項 |
| `az` | **唯讀 az 登入態檢查**：`ok` / `stale`（`az account show` 失敗）/ `missing`（沒裝 az） |

`az` 不是 `ok` 時額外印：

```
faults: AZ-LOGIN-STALE stale
```

**這是 pre-HUMAN 警示**：watchdog 2b 的救援憑證在 hour 60+ 可能過期，等到真的要用時才發現就來不及了。看到就去 bastion 重新 `az login`。

### 7.2 budget-warning

累計估算 ≥ `FAULTS_BUDGET_USD`（預設 1000）時印：

```
budget-warning: cost_usd=1004 threshold=1000
```

**不會停機**（使用者裁示：跨過就通知一聲，繼續跑到完）。看到就通知使用者，並評估是否啟用 descope。

### 7.3 descope 階梯

只在**成本逼近 $1000 天花板**或**病態緩慢**（單 cycle 反覆超估算 3 倍以上）時啟用，**啟用前通知使用者**。順序固定：

| 階 | 內容 | 節省 |
|---|---|---|
| ① | 故障低壓 cells 降 n=1 | 9 個 execution |
| ② | 砍 auto-out 確認組（S3 選配，本來就非必要） | 2 個 |
| ③ | seq-contention 只留極端壓（砍中壓 3 cells） | 6 個 |

**操作方式**（單步）：寫 `results/descope.json`，佇列端與 audit 端讀的是同一個檔。

```bash
cat > results/descope.json <<'JSON'
{ "cells": [
  { "cell_id": "<cell_id>", "reason": "descope-① 低壓降 n=1（成本 $X 逼近天花板）" }
] }
JSON

# 立刻驗證生效（第五種狀態 descoped）
python3 lib/manifest.py view --results results \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["counts"]); print(d["descoped"])'
```

效果：`manifest.py view` 把該 cell 未完成的 executions 標成 `descoped`、`next` 跳過、`counts.descoped` 獨立計數，`verdict.py audit` 把缺件認成「有記錄的缺件」。**已完成的 replicate 保持 `done`**（descope 是不再跑，不是抹掉既有證據）。

`reason` 必填、`cell_id` 必須存在於 manifest；壞檔或打錯 cell 名一律讓 `view` / `next` **失敗**（不得靜默失效讓佇列照跑）。要撤回 descope 就把該筆從檔案移除。

descoped 的 executions 也**不計入 `queue_progress` 的分母**（`steady: PASS done=x/y` 這類機器行），否則 `run/steady.sh` 的「全數完成才產 margins」判準會被永遠卡住。

**注意**：任何 descope 都會讓 `verdict.py audit` 回 exit 1（`audit: INCOMPLETE`）、進而讓 `all.sh` 印 `campaign: AUDIT-FAIL`。這是預期行為。teardown 的判準不是「audit exit 0」，而是「`EVIDENCE-SUMMARY-<date>.md` 的 missing 清單裡每一筆都有 descope / needs-human 的具名理由」（§8）。

---

## 8. 收尾與 teardown checklist

### 8.1 收尾順序（`all.sh::_all_finalize`——順序本身就是規格）

1. `reconcile`：停全部注入 / fio（`MCLOCK-ISO` chain、非預期 down/out 的 OSD、`/run/mclock` registry 殘留）→ `all: RECONCILED`
2. `ceph_campaign_unflags` + `client_tuning_restore` → `all: UNFLAGGED fails=<n>`
3. `bg_collect_stop`（sampler 已由 reconcile 按 registry 清掉）
4. **資料集封閉**：寫 `results/DATASET-SEALED`，此後不再有 writer → `all: SEALED <path>`
5. `verdict.py audit results/`（**唯讀**，不碰叢集）→ 產 `audit.json` + `EVIDENCE-SUMMARY-<date>.md`
6. `campaign: DONE`

**1–4 不因 audit 結果而改變**——audit FAIL 也絕不留下 campaign flags 或還在寫的 collector。步驟 2/3 任一失敗會印 `all: CLEANUP-INCOMPLETE <n>` 並讓收尾回 1，但後面的步驟照樣做完。

### 8.2 交還 IaC 之前的 checklist

**bundle audit 過才准刪 RG。** 逐條確認：

- [ ] `campaign: DONE`（或 `campaign: AUDIT-FAIL` 但 §8.3 的例外條件成立）
- [ ] `EVIDENCE-SUMMARY-<date>.md` 已產出，且**已 commit 進 git**（`results/` 是 git-ignored，這份 md 在實驗根目錄，是唯一進 git 的索引）
- [ ] `audit: <done>/<expected> cells=... missing=... duplicate=... unknown=...`：`duplicate` 與 `unknown_cells` **必須為 0**（不為 0 = bundle 對不上 manifest，資料完整性有問題，先查清楚）
- [ ] `missing` 清單中每一筆都有具名理由（descope / needs-human），沒有「不知道為什麼少」的項目
- [ ] `censored` 清單已檢視：每個 right-censored 觀測都是**有效資料**（`time-to-recovery > cap`），不是工具故障；同 cell 雙 censored 的自救 replicate 有跑到
- [ ] `tainted` 清單已檢視：沒有 `manifest_hash 不符` 的項目（有 = 中途重新 generate 過 manifest，跨段資料不可合併）
- [ ] **原始資料已從 bastion 備份出去**（`results/` 在 git-ignored 目錄，刪 RG 之後叢集端就沒有任何備份了）：

  ```bash
  tar --no-xattrs -czf ~/mclock-results-$(date +%Y%m%d).tar.gz -C experiments/ceph-mclock-profiles results
  ```

  （macOS 的 bsdtar 會塞 `com.apple.provenance` xattr，`--no-xattrs` 必加。）
- [ ] Phase 5 的報告草稿已能從 `results/` 產出（至少 aggregate 與 verdict 都讀得到），確認沒有「刪了才發現缺一個檔」的風險
- [ ] 叢集端的 campaign flags 已回退（`ceph osd dump | grep flags` 沒有 noscrub / nodeep-scrub）——雖然 RG 要刪了，但這是驗證 cleanup stack 對稱性的最後一次機會，結果要記進報告
- [ ] 費用總結：`az consumption usage list` 或 Cost Management 的實際數字，對照 `faults: REPORT` 的估算，差異記進報告

全過之後才通知 IaC agent 刪整個 RG。**刪 RG 是不可逆的**——8 台 OSD 的 local NVMe 內容、prometheus 的時序資料、所有 remote 端的原始 log 全部消失。

### 8.3 audit FAIL 仍可 teardown 的唯一例外

`missing` 全部是**已記錄的 descope / needs-human**，且 `duplicate` = `unknown_cells` = 0。此時 `audit: INCOMPLETE` 是帳目正確的「有意識的缺件」，不是資料遺失。把這個判斷寫進報告的 limitations，附上 EVIDENCE-SUMMARY 的對應段落。

---

## 9. 可調旋鈕與調整時機

全部走環境變數（`VAR=值 bash run/xxx.sh`），預設值見各 lib 檔頭。最常需要動的：

| 變數 | 預設 | 意義與調整時機 |
|---|---|---|
| `CALIB_NET_MIN_GBPS` | `1.0` | **網路基線地板**：iperf3 最慢一台低於此值即 die，不得開跑。1 Gbps 量級 = Accelerated Networking 沒開或 NIC 真的壞了。**只有在明確知道該 SKU 的合理下限不同時才調低**；調低等於放行一個網路壞掉的環境，所有 seq 形態的結論都會失真 |
| `CALIB_NET_WARN_GBPS` | `5.0` | **警告門檻**：正常 L8s_v3 應有 ~12 Gbps。低於此值但高於地板 → 只警告 + 記成 covariate，繼續跑。若換 SKU 或 region，這個值要跟著該 SKU 的標稱頻寬重設（大約設在標稱值的 40%） |
| `CALIB_REBOOT_SECS` | `900` | reboot canary 等 node 帶新 boot ID 回來的上限。Azure 偶爾慢，看到 canary 逾時但 node 其實活著就調高 |
| `MEASUREMENT_CAP` | `2700` | pilot 前的預設量測上限（45min）。對單 OSD backfill 寬裕、對 rack loss 偏緊——**operator 要有心理準備 rack cells 會 censored**。pilot 之後由 `cap-update` amendment 接管，不要手動改這個變數 |
| `PIPELINE_DRIFT_LIMIT` | `3` | **同一個 (形態,壓力,backfill 類別)** 連續幾次 baseline drift 才停佇列（用 `--drift-limit` 傳給 `verdict.py`，判定只實作在那一處）。環境本來就抖（例如已知的鄰居效應時段）可暫時調高，但要記進 covariate |
| `PIPELINE_TAINT_BUDGET` | `3` | 同一 replicate 連續幾次 taint 就轉 needs-human 並跳過 |
| `FAULTS_REPORT_SECS` | `43200` | 回報週期。想要更密的進度就調小（例如 `3600`） |
| `FAULTS_BUDGET_USD` | `1000` | budget-warning 門檻 |
| `FAULTS_HOURLY_USD` | `8` | 成本模型的時薪。provision 前用實際 subscription rate 重算一次就改這個 |
| `CAPACITY_COV_LIMIT` | `0.20` | 跨 8 顆 capacity 的 CoV gate。**不建議調高**——這是異質 NVMe 的唯一防線 |
| `QUEUE_STUCK_LIMIT` | `5` | 同一個 execution key 連續回鍋幾次仍無進展就判 STUCK。正常情況 taint 預算會先接手 |
| `RESULTS_DIR` / `INVENTORY_JSON` | `results/` / `azure/inventory.json` | 換路徑用（例如同機跑第二場） |

---

## 10. 真機首跑的已知風險

按「最可能絆倒你」排序：

0. **IaC 交付的是 5.15 kernel**（jammy 的**預設 GA kernel**，也就是「照 image 開機、沒裝 HWE」的預設結果）——`verify-provision.sh` 的 `kernel-version` check 會 FAIL。處置：**退回 IaC**，在 15 台裝 `linux-generic-hwe-22.04` → **reboot** → 重驗 `uname -r` 為 `6.8.*`，通過才准往下。**不可放行、不可用 `KERNEL_VERSION_EXPECT=5.15` 繞過**：client IO 走 krbd，5.15 與 6.8 的 kernel RBD datapath 不同，量出來的 client latency 尾巴會混入與 mClock profile 無關的成分，整場對照失去外推價值。同理 `os-version` FAIL（拿到 24.04）也一律退回重開機器——24.04 還會連帶裝不到官方 `ceph-common` 19.2.2（`download.ceph.com/debian-19.2.2/dists/` 沒有 `noble`）。
1. **profile 切換的第一次真跑**（§1.7 已補）——`ceph_set_profile` 在 preflight 下 `ceph config set osd osd_mclock_profile`，接著由 qos gate 驗八顆同時收斂。第一個非 `balanced` 的 cell 是這條路徑的首次真機驗證：若 gate 逾時，先看 `set-profile: SET <old> <new>` 這行有沒有出現、再看是不是九參數沒跟著換。
2. **`fio_calibrate` 依賴編譯預設即 balanced**（§4.9）——若 die，人工裁決，**不可**用 `ceph config set` 繞過。
3. **fio parser 對真機輸出的一次性校正**：`fio_smoke_real` 會跑 60s 真 fio、把 raw 三個 log 存成 golden，再用 `verdict.py aggregate --validate-schema` 驗過才放行。**如果這裡失敗，代表本機 fio 版本的 log 格式與 parser 假設不符**（常見：hist log 的 bin 數 / 單位是 ns 還是 us、windowed log 的重複 timestamp、不完整的尾窗）。修 parser，不要修 golden。
4. **capacity 決策表五狀態**：`accepted-consistent` / `accepted-inconsistent` / `rejected-out-of-range` / `skipped-existing-nondefault` / `failed`。前四種都有自動出口，最後一種 die 叫人（§4.5）。真機第一次跑最常見的是 `rejected-out-of-range`（L8s_v3 的 NVMe 可能量出 > 80000 IOPS 被 Ceph 丟掉）→ 自動改鎖 `min(raw_fio, 72000)` 並標 `fio-derived`，報告要註明。
5. **`down` 偵測延遲的本質差異（H-020）**：`ceph orch daemon stop` 會送 `MOSDMarkMeDown`（< 5s 判 down），network isolation 只能等 heartbeat 逾時（≈ 20s）。**兩者的時間軸必須以 OSDMap epoch 對齊**，不可直接以注入時刻對齊，否則 node-loss cell 會平白多出 ~15s 的「無故障」窗被算進 stall。這已在 `inject.sh` 實作，但看報表時要記得。
6. **rack-isolation 的 prepare/verify/commit barrier**：兩台都 verified 才 `ceph osd out` 兩顆。任一台失敗 → 立即回退兩台並標 taint，**不得降級成單 node fault 續量**。真機第一次跑 rack cell 時盯一下 `rack-isolate: OK/TAINT` 機器行。
7. **`H-023` 預測**：`rack-loss × 極端壓 × high_client_ops` 是最可能撞 cap 的 cell。它 censored 是**預期中的研究發現**，不是故障。
8. **chaos 的 min_size 不變條件**：事件序列 generator 保證任一時刻不會讓任何 PG 低於 `min_size=2`。若 PG inactive，krbd client 的 IO 會卡在 kernel D-state，fio kill 不掉、`rbd unmap` 必敗、watchdog 救不回來。這條在 `inject.sh` 有測試斷言，但真機首跑 chaos 時仍應人在旁邊。
9. **`calibrate` 的 campaign flags 交棒**：calibrate 成功收尾時會把 flags 的 unset 從 cleanup stack 移除（交棒給 run 佇列）；失敗 / 中斷路徑照常回退，且會對稱清掉 `campaign-flags.done` marker。若你看到「續跑之後 noscrub 不見了」，就是這個交棒出問題——別繼續跑，那會污染所有 cells。

---

## 11. 產物地圖

```
experiments/ceph-mclock-profiles/
├── README.md                      ← 你在這
├── HYPOTHESES.md                  charter + 假說 backlog + 預註冊生產門檻
├── PROVISIONING-REQUIREMENTS.md   給 IaC agent 的完整需求（含 §9 acceptance checklist）
├── EVIDENCE-SUMMARY-<date>.md     audit 產物（**進 git**，唯一的索引）
├── azure/
│   ├── verify-provision.sh        IaC 交付驗收 + az preflight
│   ├── inventory.json             ← IaC 交付（git-ignored）
│   └── attestation.json           ← IaC 交付（git-ignored）
├── lib/                           common / inventory / ceph / fio / inject / collect / pipeline .sh
│                                  manifest.py / verdict.py
├── run/                           calibrate / steady / faults / chaos / all / queue / unhalt .sh
├── tests/                         gate.sh（= run-tests + shellcheck + make validate）
└── results/                       **git-ignored**
    ├── manifest.json              63 cells / 147 executions
    ├── schedule-amendments.json   append-only JSONL，唯一持久 SoT
    ├── calibration.json           壓力等級速率 + 各壓力參考 p99
    ├── capacity-lock.json         8 顆的決策表與鎖定值
    ├── capacity-provenance.json   bench 來源證據
    ├── margins.json               雙軌 margin（noise + production）
    ├── schedule-estimate.json     pilot 推導的 cap 與總時程
    ├── watchdog-state.json        trigger 計數 / halted / drift streak 鏡射 / unhalt_log（resume 不重置）
    ├── descope.json               成本決策（§7.3）：列出的 cell 在 merge 視圖標 descoped
    ├── audit.json                 齊備度總表
    ├── DATASET-SEALED             封閉標記
    ├── .stage-<name>.done         all.sh 的段落 marker
    ├── calibrate/<step>.done      calibrate 的步驟 marker + journal.log
    └── <cell_id>/<rN>/
        ├── DONE / .claim / .taint-count / .needs-human
        └── attempts/<ts>/         evidence bundle（prediction / qos / fio / sampler /
                                   fault-timeline / coverage-proof / return-backfill /
                                   censor-status / final-clean-proof / cleanup-proof /
                                   aggregate / verdict / DONE）
```

---

## 12. 疑難排解快速表

| 症狀（機器行） | 意義 | 先做什麼 |
|---|---|---|
| `verify-provision: FAIL <n>/<t>` | IaC 交付不符契約 | 退回 IaC，別手動補 |
| `calibrate 步驟失敗：<step>` | 停在原地 | 修好後重跑 calibrate，會從斷點續 |
| `capacity-dispersion-high` | 8 顆 capacity 太離散 | §4.4 remediation |
| `capacity-decide: HUMAN-NEEDED` | bench 失敗 / 決策表不齊 | §4.5 |
| `qos gate：八顆 OSD 未在 <n>s 內同時收斂` | profile / 九參數 / capacity 對不上 | 先確認前一行有 `set-profile: SET/NOOP`（§1.7），再比對 bundle 的 `qos.json` 逐項失敗欄位 |
| `set-profile: SET <old> <new>` | preflight 真的切了 profile | 正常訊息；後面要跟著 `qos-gate: PASS <new>` |
| `steady: SMOKE-MISSING <dir>` | golden log 缺 | `fio_smoke_real` 沒過，回去跑 calibrate 的 `fio-smoke-real` 步驟 |
| `steady: FIRST-CELL-GATE` | 人工 gate（exit 10） | §4.1 |
| `faults: NO-MARGINS <path>` | 缺 margins.json | 先把穩態跑完（`--pilot` 才可略過） |
| `faults: PILOT-GATE` | 人工 gate（exit 10） | §4.2 |
| `faults: PILOT-CENSORED <f>` | 需 cap 裁示（exit 11） | §4.3，先落 cap-update amendment |
| `faults: AZ-LOGIN-STALE` | 2b 救援憑證失效 | bastion 重新 `az login` |
| `budget-warning: cost_usd=...` | 逼近天花板 | 通知使用者，評估 descope（§7.3） |
| `baseline-drift <metric> <pct> [tol=...]` | 單次漂移（p99 軸會一併印生效門檻） | 記 covariate，續跑；連 3 次才停 |
| `baseline-check: OK p99-tol=<x>% (<來源>, mad <y>% x3.0, n=<k>)` | 正常通過，且**明示這格生效的門檻**（`floor` = 15% 下限／`mad` = 被該組合實測離散度放寬） | 正常續跑；門檻怎麼推導見 §4.6 |
| `baseline-check: OK covariate-only class=<c> n=<k>` | 這格**沒有**可比參考，p99 漂移偵測沒開 | 正常續跑；盲區規模見 §4.6 |
| `watchdog: HUMAN-NEEDED <t> <ctx>` | 佇列停（exit 3） | §4.7，**別 deallocate** |
| `taint-budget: NEEDS-HUMAN <k> <n>` | 該 replicate 被跳過 | §4.8，續跑其餘 cells |
| `queue: STUCK <kind> <key>` | 同一 key 連續回鍋 5 次無進展 | 查該 cell 的 attempts，通常伴隨 taint |
| `reconcile: BLOCKED final-clean rc=<n>` | 殘留沒清乾淨 | 人工看 `ceph -s`，別強行續跑 |
| `pipeline: BUSY <key>` | claim 被別的 runner 持有 | 確認沒有第二個 runner；stale 逾時 1h 後可接管 |
| `all: CLEANUP-INCOMPLETE <n>` | 收尾有步驟失敗 | 手動確認 flags / tuning / collector 都回退了 |
| `campaign: AUDIT-FAIL rc=1` | audit INCOMPLETE | §8.3 判斷是不是「有記錄的缺件」 |
