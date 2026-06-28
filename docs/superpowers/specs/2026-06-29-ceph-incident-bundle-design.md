# Ceph Incident Bundle — 設計（spec）

> 日期：2026-06-29
> 子計畫定位：SP-6（ceph）下的 incident evidence collection 工具與專題頁。
> 目標讀者：只會基本 Linux、不懂 ceph 的值班者。
> 使用者核准方向：支援 cephadm 與 Rook/Kubernetes 自動偵測；開發可拆多個 helper script，但操作時只跑一支整合 script；KISS / DRY；每個實作 task 後用 Code Reviewer agent review 到無阻斷問題；最後用真 lab 測試、整理成一篇 ceph 專題頁，再跑 `/reviewing-source-first-pages` review loop。

## 1. 目標

當 ceph 出問題時，值班者通常最需要的是「先把現場證據完整留下來」，而不是一開始就判斷根因。本計劃要交付一套可重複使用的 evidence bundle 流程：

1. 使用者在工作機執行一個 shell script。
2. script 透過 SSH 到所有 ceph node 收集當下資料。
3. script 從 seed node 收集 cluster-level ceph 狀態。
4. 所有輸出整理成一個 `.tar.gz`。
5. bundle 內有 manifest、命令結果、錯誤紀錄與環境資訊，方便事後給自己、AI、同事或 upstream issue 使用。

成功標準：

- 對基本 Linux 使用者來說，只要能填 inventory、知道 SSH key，就能照 README 跑。
- 對 ceph 不熟的人，不需要知道哪些 `ceph` command 要跑。
- 單一 node 指令失敗不會讓整包收集失敗；失敗會被記錄。
- 收集行為預設 read-only，不做 restart、repair、flush、compact、scrub、destroy、delete。
- bundle 可在沒有網路的環境留存；所有資料都是一般文字、JSON、log、或 command output。
- 實作保持簡潔可讀：小函式、少全域狀態、無過度抽象，重複命令收集用表格驅動。

## 2. 已確認的測試環境

使用者提供的 lab 是 cephadm-managed Ceph v19.2.3（Squid），目前從 `monitor01` 透過 `sudo cephadm shell -- ceph -s --format json` 確認 `HEALTH_OK`。

| 角色 | Hostname | IP |
|---|---|---|
| monitor01 / mon | `ceph-lab-mon-01` | `192.168.18.166` |
| mon02 | `ceph-lab-mon-02` | `192.168.18.167` |
| mon03 | `ceph-lab-mon-03` | `192.168.18.164` |
| osd01 | `ceph-lab-osd-01` | `192.168.18.169` |
| osd02 | `ceph-lab-osd-02` | `192.168.18.171` |
| osd03 | `ceph-lab-osd-03` | `192.168.18.174` |

Lab 特性：

- SSH user：`ikaros`
- SSH key：repo 內 `.ssh/id_ed25519`
- 所有 node 有 `sudo`、`cephadm`、`tar`、`gzip`
- host 上沒有一般 `ceph` CLI；ceph CLI 需要透過 `sudo cephadm shell -- ceph ...`
- 有 `podman` 與 `docker`
- `/var/log/ceph` 與 `/var/lib/ceph/<fsid>` 存在

## 3. 方案選擇

採用「local SSH orchestrator + remote helper」。

使用者只在 repo 內執行：

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  --ssh-key .ssh/id_ed25519 \
  --seed ikaros@192.168.18.166
```

輸出：

```text
experiments/ceph-incident-bundle/results/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
```

採用這個方案的理由：

- 符合「只跑一個 script」：`run/collect.sh` 是唯一入口。
- 不需要預先把工具安裝到 ceph node；helper 可用 SSH 串流送到遠端執行。
- 一台工作機可以同時包 cluster-level 與所有 node-level 資料。
- SSH inventory 清楚，日後同一套也可收 Proxmox bare-metal、cephadm VM、或 Rook worker node。

不採用的替代方案：

- 只在 mon node 上執行：少一層工作機 dependency，但會要求 mon node 能 SSH 到所有 node，額外假設太多。
- 每台 node 手動執行：script 最簡單，但事故時最容易漏跑、漏包、覆蓋資料。

## 4. 目錄與責任邊界

```text
experiments/ceph-incident-bundle/
  README.md
  .gitignore
  inventory/
    ceph-lab.example.env
  lib/
    common.sh
    collect-cluster-cephadm.sh
    collect-cluster-rook.sh
    collect-node.sh
    verify-bundle.sh
  run/
    collect.sh
  tests/
    run-tests.sh
    test-common.sh
    fixtures/
  results/
    .gitkeep
```

責任分工：

- `run/collect.sh`：唯一入口，解析參數、載入 inventory、建立暫存目錄、呼叫 cluster/node collectors、打包 `.tar.gz`。
- `lib/common.sh`：共用函式，包含 log、die、command timeout、safe command runner、redaction、manifest 寫入、路徑檢查。
- `lib/collect-cluster-cephadm.sh`：cephadm 模式的 cluster-level ceph command 收集。
- `lib/collect-cluster-rook.sh`：Rook/Kubernetes 模式的 cluster-level `kubectl` / toolbox / Pod log 收集。
- `lib/collect-node.sh`：在每台 node 上執行的 read-only node-level collector。
- `lib/verify-bundle.sh`：驗證 bundle 結構、gzip 完整性、必要檔案是否存在、是否包含明顯不該收的 secret path。
- `tests/run-tests.sh`：本機單元測試與 fixture 測試。
- `README.md`：給基本 Linux 使用者照做的操作手冊。

## 5. Inventory 格式

保持 shell 原生、可讀、可 copy：

```bash
SSH_USER="ikaros"
SEED_HOST="192.168.18.166"
HOSTS=(
  "monitor01=192.168.18.166"
  "mon02=192.168.18.167"
  "mon03=192.168.18.164"
  "osd01=192.168.18.169"
  "osd02=192.168.18.171"
  "osd03=192.168.18.174"
)
```

`run/collect.sh` 支援：

- `--inventory PATH`：載入 inventory。
- `--ssh-key PATH`：SSH private key。
- `--seed USER@HOST`：覆蓋 inventory 的 seed。
- `--out DIR`：輸出目錄，預設 `results/`。
- `--mode auto|cephadm|rook`：預設 `auto`。
- `--since DURATION`：journal/log 時間窗，預設 `24h`。
- `--timeout SECONDS`：單一 command timeout，預設 `20`。
- `--skip-logs`：只收狀態不收大型 log，給空間很小時使用。
- `--keep-workdir`：保留暫存目錄方便 debug。

## 6. 收集內容

### 6.1 Bundle metadata

每次收集都建立：

- `manifest.jsonl`：每個 artifact 一行，包含 host、collector、path、command、exit code、開始/結束時間。
- `README-FIRST.txt`：事故後先看哪幾個檔案。
- `summary.txt`：bundle 名稱、時間、mode、seed、hosts、成功/失敗統計。
- `errors.log`：所有非零 exit code、SSH 失敗、timeout。
- `environment.txt`：collector 版本、git commit、local host、執行參數。

### 6.2 Cluster-level：cephadm mode

從 seed node 透過 `sudo cephadm shell -- ceph ...` 收：

- `ceph status --format json-pretty`
- `ceph health detail --format json-pretty`
- `ceph versions --format json-pretty`
- `ceph df detail --format json-pretty`
- `ceph osd tree --format json-pretty`
- `ceph osd df --format json-pretty`
- `ceph osd dump --format json-pretty`
- `ceph osd perf --format json-pretty`
- `ceph osd blocked-by --format json-pretty`
- `ceph pg stat --format json-pretty`
- `ceph pg dump --format json-pretty`
- `ceph pg dump_stuck --format json-pretty`
- `ceph mon dump --format json-pretty`
- `ceph quorum_status --format json-pretty`
- `ceph mgr dump --format json-pretty`
- `ceph orch host ls --format json-pretty`
- `ceph orch ps --format json-pretty`
- `ceph orch device ls --wide --format json-pretty`
- `ceph config dump --format json-pretty`
- `ceph crash ls --format json-pretty`
- `ceph crash info <id>` for recent crash ids, with a cap。

文字版也保留少量關鍵檔案，方便不用 `jq` 時閱讀：

- `ceph/status.txt`
- `ceph/health-detail.txt`
- `ceph/osd-tree.txt`
- `ceph/orch-ps.txt`

### 6.3 Cluster-level：Rook/Kubernetes mode

自動偵測條件：

- local 或 seed node 有 `kubectl`
- 存在 `rook-ceph` namespace 或 inventory 指定 `ROOK_NAMESPACE`

收集：

- `kubectl -n rook-ceph get pods -o wide`
- `kubectl -n rook-ceph get cephcluster,cephblockpool,cephfilesystem,cephobjectstore -o yaml`
- `kubectl -n rook-ceph get events --sort-by=.lastTimestamp`
- Rook operator log
- ceph toolbox 中的 `ceph -s` / `health detail` / OSD / PG / MON / MGR 狀態
- ceph daemon Pod logs（依 label 選 mon/mgr/osd/crash/exporter）

Rook 第一版目標是「可用且 read-only」，不是覆蓋所有 CSI / PVC 狀態；若偵測不到 Rook，清楚記錄 `rook mode skipped`。

### 6.4 Node-level

每台 node 收：

系統基本資訊：

- `hostname -f`, `date -u`, `uptime`, `uname -a`, `/etc/os-release`
- `timedatectl`, `chronyc tracking` 或 `ntpq -p`（存在才跑）

CPU / RAM / process：

- `top -b -n1`
- `ps auxww --sort=-%cpu`
- `ps auxww --sort=-%mem`
- `free -h`
- `/proc/meminfo`, `/proc/loadavg`, `/proc/pressure/*`

disk / block / filesystem：

- `df -hT`
- `lsblk -a -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,ROTA,STATE`
- `blkid`
- `mount`
- `findmnt`
- `pvs`, `vgs`, `lvs`（存在才跑）
- `iostat -xz 1 3`（存在才跑）

network：

- `ip addr`, `ip route`, `ip neigh`, `ss -tulpn`
- `/etc/hosts`, `/etc/resolv.conf`

kernel / system log：

- `dmesg -T`
- `journalctl -k --since "-24h"`
- `journalctl --since "-24h" -p warning..alert`
- `systemctl --failed`
- `systemctl list-units 'ceph*' --no-pager`
- `journalctl -u 'ceph*' --since "-24h"`

container / cephadm：

- `cephadm version`
- `cephadm ls --format json-pretty`
- `podman ps -a`, `podman stats --no-stream`, `podman images`（存在才跑）
- `docker ps -a`, `docker stats --no-stream`, `docker images`（存在才跑）
- `/var/log/ceph` listing and log copies, respecting size cap。
- `/var/lib/ceph` safe listings and selected config files, excluding keyrings。

## 7. 安全與資料保護

預設排除：

- `*.keyring`
- `client.*.key`
- private SSH key
- core dump
- huge BlueStore block devices / raw device reads
- `/var/lib/ceph/*/mon.*/keyring`

Redaction：

- 對文字輸出跑 `redact_file`，遮掉含 `password`、`secret`、`token`、`keyring`、`private_key` 的明顯敏感行。
- redaction 只處理已收文字檔，不嘗試解讀 binary。
- bundle 內保留 `redaction.log`，列出哪些檔案有行被遮掉。

安全聲明：

- script 不保證移除所有秘密；事故後分享給第三方前仍要人工掃過。
- script 不做任何會改變 cluster 狀態的操作。
- 所有 `sudo` command 都是 read-only；若 `sudo -n` 不可用，清楚失敗並記錄。

## 8. 錯誤處理

KISS 原則：

- 每個 command 都用 `run_capture <name> <outfile> -- <cmd...>`。
- `run_capture` 永遠寫 `.meta` 或 manifest entry。
- command 非 0 時不讓整體中止，除非是前置條件（inventory 不存在、無法建立輸出目錄）。
- SSH 到某 node 失敗時，該 node 記為 failed，其他 node 照跑。
- cluster-level ceph command 失敗時，仍收 node-level。
- 最後 exit code：
  - `0`：所有必要 collector 成功。
  - `2`：部分 host 或部分 command 失敗，但 bundle 已產出。
  - `1`：沒有產出 bundle 的致命錯誤。

## 9. 測試與驗證

本機測試：

- `bash -n` 所有 shell script。
- `tests/run-tests.sh`：
  - inventory parser 正常/錯誤格式。
  - `redact_file` 遮掉敏感行。
  - manifest 寫入格式。
  - `verify-bundle.sh` 能驗出缺檔、能通過 fixture bundle。
  - fake SSH / fake cephadm command failure 不會讓整體停止。

真 lab smoke：

1. 對使用者提供的 6-node cephadm lab 跑 `run/collect.sh`。
2. 驗證 `.tar.gz` 可解開。
3. 驗證 bundle 內有 6 個 node 目錄。
4. 驗證 cluster-level cephadm command 有 `status`、`health detail`、`orch ps`。
5. 驗證每台 node 有 `dmesg`、`journalctl`、`df`、`lsblk`、`cephadm ls`。
6. 驗證 bundle 不包含 `keyring` 路徑。
7. 跑 `lib/verify-bundle.sh <bundle>`。

網站驗證：

- 新增 ceph feature page，描述緣起、流程、收集清單、操作步驟、bundle 結構、失敗處理、安全界線、lab 實測結果。
- 更新 `next-site/lib/projects.ts`、`next-site/content/ceph/feature-map.json`、`next-site/content/ceph/quiz.json`。
- 對該頁跑 `/reviewing-source-first-pages` loop，直到 reviewer pass。
- `make validate` exit 0。

## 10. Review 與實作流程

實作採 `superpowers:subagent-driven-development`：

1. 先寫 implementation plan。
2. 每個 task 由 fresh implementer subagent 處理。
3. 每個 task 完成後呼叫 Code Reviewer agent，檢查 spec compliance 與 code quality。
4. Critical / Important finding 必須修完並 re-review。
5. 全部 task 完成後再做 whole-branch Code Reviewer review。
6. MDX 專題頁完成後，使用 `/reviewing-source-first-pages` review loop。

模型/代理人選擇：

- shell script 實作 task：worker / Code Reviewer。
- MDX 寫作：Technical Writer。
- MDX 挑戰：Code Reviewer 或可用的 reviewer agent，使用 `reviewing-source-first-pages` 的兩軸要求。

## 11. 不做

- 不自動修復 ceph。
- 不重啟 daemon。
- 不收 raw block device。
- 不預設收 core dump。
- 不假設每台 node 都有 host-level `ceph` CLI。
- 不把 bundle commit 進 repo；只 commit script、README、測試、專題頁、必要的 fixture。
- 不在 MDX import component；測驗題只放 `quiz.json`。
- 不加 Mermaid；若未來需要圖，一律用靜態 PNG。

## 12. 交付物

1. `experiments/ceph-incident-bundle/` runnable evidence collector。
2. `experiments/ceph-incident-bundle/README.md` 操作手冊。
3. `tests/run-tests.sh` 本機測試。
4. 真 lab smoke test 的驗證摘要，必要時保留 scrubbed sample manifest，不 commit 完整事故 bundle。
5. Ceph 專題頁：`next-site/content/ceph/features/incident-bundle-runbook.mdx`。
6. `projects.ts` / `feature-map.json` / `quiz.json` 整合。
7. `make validate` 通過。
8. `git commit --no-gpg-sign`。
9. 使用 repo-local `.ssh/id_ed25519` push。
