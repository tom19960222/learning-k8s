# Ceph Incident Bundle

## 這是做什麼的

這套 script 是事故發生時的「先保留現場」工具。它會從一台工作機透過 SSH 到所有 Ceph node 收集系統狀態、Ceph 狀態、log 清單與必要 log，最後打包成一個 `.tar.gz`。

它不會修復 Ceph，也不會執行 restart、delete、repair、scrub 這類會改變 cluster 狀態的操作。

## 什麼時候執行

建議在以下情境先跑一次：

- `ceph health detail` 出現 `HEALTH_WARN` 或 `HEALTH_ERR`
- OSD down、PG stuck、I/O latency 異常、MON quorum 異常
- node CPU、RAM、disk、網路看起來異常，但還不確定是不是 Ceph 問題
- 準備請別人或 AI 協助判讀，需要保留當下證據

## 最短操作流程

在 repo root 執行：

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  --ssh-key .ssh/id_ed25519 \
  --seed ikaros@192.168.18.166 \
  --mode cephadm \
  --since 24h
```

成功後會看到：

```text
bundle: experiments/ceph-incident-bundle/results/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
```

驗證 bundle：

```bash
bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle.tar.gz>
```

## 如何填 inventory

Inventory 是 shell 檔案，格式如下：

```bash
SSH_USER="ikaros"
SEED_HOST="192.168.18.166"
ROOK_NAMESPACE="rook-ceph"
HOSTS=(
  "monitor01=192.168.18.166"
  "mon02=192.168.18.167"
  "osd01=192.168.18.169"
)
```

- `SSH_USER`：登入每台 node 的 Linux 帳號。
- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
- `ROOK_NAMESPACE`：Rook 的 namespace，未填時預設 `rook-ceph`。
- `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。external-ceph rook 拓樸可以把 **external ceph 主機與 k8s node 混在同一份** `HOSTS` 裡。

## 自動偵測（auto，預設）

預設 `--mode auto` 會逐台 node 經 ssh 偵測能力，再分層收集：

- node 上有 `cephadm` → 從**第一台**有 cephadm 的 node 收 cluster-level ceph（`sudo -n cephadm shell -- ceph ...`）。
- node 上有 `kubectl` → 從**第一台**有 kubectl 的 node、用 ssh 在該 node 上跑 `kubectl`（可加 `--kube-context`）收 rook 層。
- 兩層都有來源就都收、各收一次;node 層一律每台都收。

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  --ssh-key .ssh/id_ed25519 \
  --since 24h
```

## external ceph + rook（一份 inventory）

把 external ceph 主機和有 `kubectl` 的 k8s node 列進同一份 `HOSTS`，`auto` 會：ceph 層從 ceph 主機收、rook 層在 k8s node 上跑 kubectl 收。指定 context：

```bash
SSH_USER="ikaros"
HOSTS=(
  "mon01=10.0.0.1"     # external ceph（有 cephadm）
  "osd01=10.0.0.2"     # external ceph
  "k8s1=10.0.0.9"      # k8s node（有 kubectl）
)
```

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory inventory/external.env \
  --ssh-key ~/.ssh/id_ed25519 \
  --kube-context my-cluster \
  --since 24h
```

## 只收單層（覆寫）

- `--mode cephadm`（可配 `--seed USER@HOST`）：只收 ceph 層。
- `--mode rook`：只收 rook 層（在第一台有 kubectl 的 node 上跑）。

## auto 的限制（已知）

- **來源挑「第一台」、不看 liveness**：cluster-ceph 取第一台有 `cephadm` 的 node、cluster-rook 取第一台有 `kubectl` 的 node;只看指令存在、不檢查該 node 的 ceph/k8s 是否健康,也不會自動 fallback 到第二台。若想釘住一台已知健康的 mon,用 `--seed USER@HOST`。
- **探測是逐台序列 ssh**:某層的能力完全不存在時(例如純 cephadm 叢集仍會為了 rook 掃完每台),或 node 沒回應時,探測會逐台等到 `ConnectTimeout`。大型 inventory 建議直接用 `--mode cephadm --seed ...` 跳過探測。探測 ssh 失敗的 node 會記進 `errors.log`(`capability probe failed for ...`),不會被當成「沒有該能力」而靜默忽略。

## 逾時與大型 log

- `--timeout`（預設 20s）是**單一指令 / SSH 連線**的逾時。
- `--node-timeout`（預設 600s）是**單一 node 整輪收集**的逾時。兩者分開：慢或大的 node 不會被單指令逾時誤殺。
- 大型 Ceph log（超過 `CEPH_INCIDENT_LOG_FILE_CAP_BYTES`，預設 1 MiB）不會被靜默丟棄，而是收最後一段（tail）並附 `<檔名>.TRUNCATED` 記錄原始大小；壓縮過的 `*.gz` 過大時則只記錄、不收（gzip 的尾段無法解壓）。
- 被逾時砍掉（exit 124/137）的指令輸出會在 artifact 末尾標 `# TRUNCATED`，讓判讀者知道內容被截斷。
- **工作機若沒有 `timeout` / `gtimeout`**（如預設 macOS），會在開頭印警告；此時外層逾時停用，只靠 SSH `ConnectTimeout` / `ServerAlive` 把關。要完整把關可 `brew install coreutils`（提供 `gtimeout`），或在 Linux ops 機執行。

## bundle 內有什麼

主要檔案：

- `README-FIRST.txt`：打開 bundle 後先看的入口。
- `summary.txt`：本次收集摘要與成功/失敗數。
- `environment.txt`：收集時間、mode、seed、git commit。
- `manifest.jsonl`：每個 artifact 的 command、exit code、時間。
- `errors.log`：非零 exit code、SSH 失敗、部分失敗。
- `cluster/`：cephadm 或 Rook cluster-level 狀態。
- `nodes/<alias>/`：每台 node 的系統、資源、disk、kernel、systemd、Ceph log 與 cephadm 狀態。

## exit code 怎麼看

- `0`：收集完成，沒有已知失敗。（注意：OSD/MON down 這類**叢集故障本身**會被收進 bundle，不算收集失敗，仍是 `0`。）
- `2`：有部分 command 或部分 node 失敗，但 bundle 已產生。先看 `errors.log` 和 `summary.txt`。
- `1`：使用方式或必要輸入錯誤（inventory / SSH key 不存在），或 **bundle 驗證失敗**。驗證失敗時不會打包可分享的 `.tar.gz`，而是**保留 workdir**（印出路徑）讓你檢查——已收集的證據不會因驗證失敗被刪掉。

## 常見失敗與處理

- `missing inventory`：確認 `--inventory` 路徑存在。
- `missing ssh key`：確認 `--ssh-key` 路徑存在，且本機可讀。
- `node <alias> collector exited 255`：通常是 SSH 連線、帳號、key、known_hosts 或 sudo 權限問題。
- `VERIFY FAIL`：bundle 結構不完整，或包含 `keyring`、`.ssh`、`id_ed25519`、`private_key`、`*.pem`/`*.key`/`*.crt` 這類路徑，或檔案內容殘留未遮蔽的 private key / `key = <base64>` 金鑰材料。此時 workdir 會被保留、不打包，先看印出的路徑與 `errors.log`。
- exit code `2`：先不要重跑覆蓋判讀脈絡，先保留 `.tar.gz`，再看 `errors.log` 決定是否針對失敗 node 補跑。

## 安全界線

- 這套工具以 read-only 收集為原則，不會主動修復或改變 Ceph 狀態。
- 遮蔽（redaction）涵蓋：含 `password`/`secret`/`token`/`keyring`/`private key` 的文字行、Ceph 金鑰材料（`key = AQB..==` 與 base64 區塊）、整段多行 PEM private key block；並會把 `*.gz` 解壓後遮蔽再壓回。但這**不是完整 DLP**。
- `verify-bundle.sh` 會以**檔名**（keyring/.ssh/id_ed25519/private_key/*.pem/*.key/*.crt）與**內容**（殘留的 PRIVATE KEY block / `key = <base64>`）兩道把關，但仍不能保證內容完全沒有敏感資料。
- 分享 bundle 前仍應自行檢查是否包含內部 IP、hostname、路徑、帳號名稱或其他敏感資料。

## Lab 驗證（multi-fault）

2026-06-30 在真 cephadm v19.2.3 叢集（3 mon + 9 OSD、pool `.mgr` size 3）跑過多故障矩陣，破壞性情境皆先 `ok-to-stop` / 確認 quorum 後注入並立即回退，最後 HEALTH_OK：

| 情境 | 注入 | bundle | exit |
|---|---|---|---|
| 健康基準 | 無 | VERIFY PASS、6/6 node、312 行遮蔽 | 0 |
| OSD down | 停 osd.0 | 收到 `OSD_DOWN`（text+json）| 0 |
| MON 少一台 | 停 mon-02（quorum 在）| 收到 `MON_DOWN`（out of quorum）| 0 |
| node 不可達 | inventory 加假 host | 該 node `SKIPPED.txt`、其餘照收、errors.log 有記 | 2 |
| seed 不可達 | `--seed` 指死 host | cluster collector 失敗、6 node 仍收 | 2 |

詳見 `docs/superpowers/reviews/2026-06-30-lab-validation.md`。

- 已知 optional/read-only 非零紀錄：各 node 的 LVM 查詢（`pvs` / `vgs` / `lvs`）、`docker ps -a`、node-level `sudo cephadm ls --format json-pretty` 可能回非零；artifact 與 node 內部 `errors.log` 會保留原始輸出，整體 bundle 仍驗證通過。
