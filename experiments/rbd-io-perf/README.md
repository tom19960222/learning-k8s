# rbd-io-perf

## 這是做什麼的

這是一套在**正式在用的 Proxmox VE + Ceph 叢集**上，量測 QEMU / krbd / librbd / image-layout 各項旋鈕對 RBD block device IO 效能實際影響的實驗 harness。目的是替 `next-site/content/vm-storage-perf` 的兩個頁面（`rbd-io-experiment-plan`、`rbd-io-tuning-catalog`）提供 source-first + 真機量測的證據——量不出可信差異的旋鈕誠實標記為「在此環境不可分辨（indistinguishable）」，不硬掰方向。

harness 只做**自有資源的讀寫與量測**：自建的 `ioperf-` 前綴 RBD image、專屬的測試 VM（VMID 1031）、可回收的臨時 storage id。不會變更 Ceph cluster / daemon 設定，也不會影響叢集上其他 VM。

## 安全界線

**三條底線（禁止事項，無例外）**：

1. 不改 Ceph cluster / daemon 設定（`osd_op_num_shards`、mClock profile 等一律唯讀記錄，不寫入）。
2. 不重啟 Ceph（不 restart 任何 mon/osd/mgr daemon）。
3. 不讓其他 VM down（所有操作只碰 VMID 1031 與自建的 `ioperf-` image）。

**Guardrails（執行期自動把關，見 `lib/collect.sh`）**：

- 任何一輪量測前後的 `ceph -s` 若出現 `HEALTH_ERR` → 立即 `die`，整支腳本中止。
- 若本輪 `ceph -s` 出現 `slow ops` 而 baseline 快照沒有 → 視為新增的 slow ops，立即中止（既有的基線 WARN，例如 `osd.0` 的 BlueStore slow ops，不會誤觸發）。
- 若 `ceph -s` 顯示 `recovery` / `backfill` / `degraded` 字樣 → 該輪判定 taint，重跑一次（`baseline.sh` 的 tainted-round retry 邏輯），非 abort。
- Pool 容量：`ioperf` pool 只在 SSD class 上（僅 `osd.0` + `osd.8` 兩顆），操作前後確認 SSD class **至少留 20–30% 可用空間**（使用者要求的下限；目前預算峰值 ~42% 用量，餘裕充足）；磁碟預算固定為 boot 10G + data 16G，每個實驗逐顆建立、測完就刪（不同時堆疊多顆）。
- krbd 相關實驗（E-01、E-04 的 krbd 軸、host 層 map options 系列）會在 PVE node 上額外吃記憶體（kernel rbd client cache + host page cache），跑 krbd 變體前後留意 `free -g`，若逼近上限先降 `--numjobs` / 縮小測試 image。

**只動自有資源**：

- 所有 RBD image 操作（`lib/rbdimg.sh`）都會先檢查名稱是否以 `ioperf-` 開頭，不是就直接拒絕（`_img_guard`）。
- 所有 VM 操作（`lib/pve.sh`）都會先檢查 VMID 落在 1031–1039 範圍（`_vmid_guard`），目前實際只用 1031。
- 所有會變更遠端狀態的腳本都要求明確帶 `--yes-really-inject`，不帶就直接 `exit 1`（唯讀的 `preflight.sh` 例外，不需要這個旗標）。

## 前置需求

- **PVE node**：`pve3`（`192.168.16.7`），登入帳號 `ioperf`（有 sudo）。
- **測試 pool**：`ioperf`（SSD-only，`size=2`），至少留 20–30% 可用空間（下限，非用量上限）；每個實驗的磁碟需求固定 boot 10G + data 16G，循序建立、用完刪除，不長期占用。
- **VMID**：`1031`，guest 網路走 bridge `vmbr1`（`192.168.18.0/24`，DHCP）。
- **node 上先裝 `fio`**（E-02 host 層天花板實驗直接對 `/dev/rbdX` 跑 fio，需要 host 有這個指令；guest 端的 fio 由 `baseline.sh` 自動 `apt-get install`，不用手動處理）：

  ```bash
  ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none ioperf@192.168.16.7 \
    'sudo apt install -y fio'
  ```

- **cloud image**（`baseline.sh` 會檢查存在，不存在就報錯並印出下載指令；預設路徑可用環境變數 `CLOUDIMG` 覆寫）：

  ```bash
  wget -O /mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
  ```

- **SSH key**：一律用 repo 內 `.ssh/id_ed25519`（`lib/common.sh` 預設值即是 `$REPO_ROOT/.ssh/id_ed25519`，且固定帶 `IdentitiesOnly=yes` / `IdentityAgent=none`，繞開本機壞掉的 ssh-agent）。

## 環境變數一覽

全部有預設值（見 `lib/common.sh`），需要時可覆寫（另有 `GUEST_USER`，預設 `ubuntu`，`guest_ssh` 使用）：

| 變數 | 預設值 | 說明 |
|---|---|---|
| `PVE_HOST` | `192.168.16.7` | PVE node（pve3） |
| `PVE_USER` | `ioperf` | 登入帳號 |
| `SSH_KEY` | `<repo root>/.ssh/id_ed25519` | SSH private key 路徑 |
| `VMID` | `1031` | 測試 VM ID（限定範圍 1031–1039） |
| `POOL` | `ioperf` | 測試用 RBD pool |
| `RESULTS_DIR` | `<repo root>/experiments/rbd-io-perf/results` | evidence bundle 輸出根目錄（git-ignored） |
| `EXP0_ROUNDS` | `3` | E-02（host 層天花板）每個 fio pattern 的重複輪數 |
| `BASELINE_ROUNDS` | `5` | E-03（baseline）重複輪數，用來算噪音帶（CoV） |
| `SCEN_ROUNDS` | `3` | E-04 以後各 scenario 的 A/B 交錯輪數 |
| `CLOUDIMG` | `/mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img` | cloud image 路徑 |
| `DATA_SPEC` | `ioperf:vm-1031-disk-1` | baseline 資料盤的 PVE volume spec，各 scenario 拿它當「切回 baseline」的還原點 |

`DATA_SPEC` 需要對到 `baseline.sh` 實際建出來的磁碟名稱——PVE 依建立順序編號 `vm-1031-disk-N`，若環境中 N 不是 1（例如重跑過 baseline 導致編號往後跳），要在跑 scenario 前手動覆寫這個變數，否則各 scenario 的「切回 baseline」步驟會指向錯的（或不存在的）磁碟。

## 執行順序

固定順序：`preflight` → `krbd-check` → `exp0` → `baseline` → `scenario-exp-axis` → 其餘 scenario → （`exp15` 手動）→ `cleanup`。

### 一鍵跑全部（`run/all.sh`）

```bash
bash experiments/rbd-io-perf/run/all.sh --yes-really-inject
```

行為：

- 沒帶 `--yes-really-inject` 直接印錯誤退出，不會誤觸發任何變更。
- 用 `trap ... EXIT` 掛 `cleanup.sh`，不管中途在哪一步失敗，結束前一定會嘗試清理（`|| true`，cleanup 本身失敗不會讓已經失敗的原因被蓋掉）。
- `scenario-exp15-rbdcache.sh` 是**已知 stub**，設計上就是 `exit 2`（不是失敗，是「這步需要人工介入」的訊號）；`run/all.sh` 用 `|| [ "$?" -eq 2 ]` 特別放行這一步，其餘任何非零 exit 都會讓 `set -e` 中止整條鏈並觸發 cleanup。

### 逐支手動執行

也可以一支一支跑，方便中途檢查每個 bundle：

```bash
cd experiments/rbd-io-perf

# E-00：read-only 環境盤點，不需要 --yes-really-inject
bash run/preflight.sh

# E-01：krbd 可行性三關（map + direct IO / features / storage.cfg）
bash run/krbd-check.sh --yes-really-inject

# E-02：host 層天花板（/dev/rbdX 直測，libaio vs io_uring，VM 不參與）
bash run/exp0-host-ceiling.sh --yes-really-inject

# E-03：建測試 VM、prefill、跑 baseline 矩陣 BASELINE_ROUNDS 次、算噪音帶
bash run/baseline.sh --yes-really-inject

# E-04（頭牌）：librbd vs krbd 雙軸對照
bash run/scenario-exp-axis.sh --yes-really-inject

# E-05：cache=writethrough / writeback vs baseline（cache=none）
bash run/scenario-exp1-cache.sh --yes-really-inject

# E-06：aio=native / threads vs baseline（io_uring）
bash run/scenario-exp4-aio.sh --yes-really-inject

# E-07：iothread=1 vs 0
bash run/scenario-exp2-iothread.sh --yes-really-inject

# E-08：virtio-blk num-queues 強制 1 vs 預設 auto（=vCPU 數）
bash run/scenario-exp8-queues.sh --yes-really-inject

# E-09：RBD image layout（object-size 4M/16M、fancy striping）
bash run/scenario-exp9-layout.sh --yes-really-inject

# E-10：krbd map option queue_depth（64/128/256）
bash run/scenario-exp10-qdepth.sh --yes-really-inject

# E-11：guest IO scheduler（none vs 預設）
bash run/scenario-exp11-sched.sh --yes-really-inject

# E-12：krbd map option alloc_size
bash run/scenario-exp12-allocsize.sh --yes-really-inject

# E-13：guest / host readahead（read_ahead_kb）三檔對照
bash run/scenario-exp13-readahead.sh --yes-really-inject

# E-14：krbd map option rxbounce on/off（配 dmesg bad crc 偵測）
bash run/scenario-exp14-rxbounce.sh --yes-really-inject

# E-15：見下方「exp15 是已知 stub」——不要直接跑期待它做完事
bash run/scenario-exp15-rbdcache.sh --yes-really-inject   # 預期 exit 2

# 收尾：刪測試 VM、unmap + 刪所有 ioperf- image、移除臨時 storage id
bash run/cleanup.sh --yes-really-inject
```

### exp15 是已知 stub

`scenario-exp15-rbdcache.sh`（librbd per-image `conf_rbd_cache` 覆寫）**沒有自動化實作**，執行後只會印一行說明並回傳 `exit 2`（不是 `1`——`2` 專門用來跟「真的壞掉」區分）。原因：`lib/rbdimg.sh` 的 `_img_guard` 只允許操作 `ioperf-` 前綴的 image，這是防呆設計的核心（harness 不能碰它無法從命名證明自己擁有的 image）；但這個實驗的操作對象是 baseline 資料盤本身（PVE 建立、命名成 `vm-1031-disk-N`），這個名字通不過守門，也不應該通過——不能因為要跑一個實驗就放寬「只動自己資源」的防呆。

要跑這個實驗，Phase 2 需要人工介入（步驟見腳本開頭註解，摘要如下）：

```bash
# 1. 找出實際的資料盤 volume 名稱
ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none ioperf@192.168.16.7 \
  "sudo -n qm config 1031 | grep virtio1"
# 例如輸出：virtio1: ioperf:vm-1031-disk-2,...

# 2. 對每個值 false / true 覆寫，重啟生效
ssh ... "sudo -n rbd image-meta set ioperf/vm-1031-disk-2 conf_rbd_cache <value>"
ssh ... "sudo -n qm stop 1031 && sudo -n qm start 1031"
# 等 guest agent 回應後，用其他 scenario 相同方式手動跑 fio 矩陣

# 3. 驗證設定生效
ssh ... "sudo -n rbd image-meta get ioperf/vm-1031-disk-2 conf_rbd_cache"
```

## 本機驗證 gate

改動 harness 程式碼或 README 後、commit 前，三個都要跑：

```bash
bash experiments/rbd-io-perf/tests/run-tests.sh
shellcheck experiments/rbd-io-perf/lib/*.sh experiments/rbd-io-perf/run/*.sh experiments/rbd-io-perf/tests/*.sh experiments/rbd-io-perf/tests/fakes/ssh
make validate
```

`run-tests.sh` 用 fake `ssh` / `kubectl`（PATH 覆寫）+ fixture 檔跑完全部 `tests/test-*.sh`，全程不連真的 PVE，全綠時印 `tests: 13 passed, 0 failed`。

## 結果去向

- 每次執行任何 `run/*.sh` 都會在 `results/<experiment>/<timestamp>/` 下產生一個 evidence bundle（prediction 檔、每輪 fio JSON、`ceph -s` 前後快照、noise/verdict 摘要等）。整個 `results/` 目錄被 `.gitignore` 擋掉，不進版控——bundle 本身可能包含環境細節，且會不斷累積。
- 需要留存的是**索引**，不是原始 bundle：把當次執行的結論、關鍵數字、對應 bundle 路徑整理成 `EVIDENCE-SUMMARY-<date>.md`，這份**要進 git**。
- 頁面（`rbd-io-experiment-plan.mdx`、`rbd-io-tuning-catalog.mdx`）上出現的每一個數字，都必須能對應到某份 bundle 或 `EVIDENCE-SUMMARY`——沒有 bundle 佐證的數字不寫進頁面。
- 回填格式與規則（表格欄位、噪音帶判準、`indistinguishable` 何時合法）見 `next-site/content/vm-storage-perf/features/rbd-io-experiment-plan.mdx` 的「結果回填規範」一節；每個實驗的完整協定、預期與回填表在同頁「各實驗協定」。
- 假設對照表（含 status: proposed / confirmed，各假設對應哪個實驗）在 `experiments/rbd-io-perf/HYPOTHESES.md`。

## Gate 2 / Gate 3

- **Gate 2（真機執行前）**：本 harness 目前只做到「本機可驗證」的程度（測試用 fake ssh，`make validate` 過）。任何一步**真的**連上 `pve3`、動到實體資源之前（即便只是唯讀的 `preflight.sh`），要先等使用者明確說「go」——這是生產叢集，不是 disposable 的 kind/minikube。
- **Gate 3（findings triage）**：每輪真機執行完，回頭對照 `HYPOTHESES.md` 的假設列表：量到的數字支持哪條假設（`confirmed`）、推翻哪條（重新標註並說明）、哪條在這個環境「不可分辨」。Triage 完才把回填內容寫回兩個 MDX 頁面；不是每次執行完都自動改頁面。
