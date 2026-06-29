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
- `SEED_HOST`：cephadm mode 用來跑 cluster-level `ceph` command 的 node。
- `ROOK_NAMESPACE`：Rook mode 的 namespace，未填時預設 `rook-ceph`。
- `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。

## cephadm 範例

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  --ssh-key .ssh/id_ed25519 \
  --mode cephadm \
  --since 24h
```

cephadm mode 會透過 seed node 執行：

```text
sudo cephadm shell -- ceph ...
```

## Rook 範例

先建立自己的 inventory：

```bash
cp experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  experiments/ceph-incident-bundle/inventory/rook.env
```

編輯 `experiments/ceph-incident-bundle/inventory/rook.env`，把 `HOSTS` 改成 Rook 所在的 Kubernetes node，並確認 `ROOK_NAMESPACE`。

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/rook.env \
  --ssh-key ~/.ssh/id_ed25519 \
  --mode rook \
  --since 24h
```

Rook mode 會在本機使用 `kubectl get`、`kubectl logs`，並在 toolbox Pod 存在時執行 read-only 的 `ceph status`。

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

- `0`：收集完成，沒有已知失敗。
- `2`：有部分 command 或部分 node 失敗，但 bundle 已產生。先看 `errors.log` 和 `summary.txt`。
- `1`：使用方式或必要輸入錯誤，例如 inventory 不存在、SSH key 不存在、bundle 驗證失敗。

## 常見失敗與處理

- `missing inventory`：確認 `--inventory` 路徑存在。
- `missing ssh key`：確認 `--ssh-key` 路徑存在，且本機可讀。
- `node <alias> collector exited 255`：通常是 SSH 連線、帳號、key、known_hosts 或 sudo 權限問題。
- `VERIFY FAIL`：bundle 結構不完整，或包含 `keyring`、`.ssh`、`id_ed25519`、`private_key` 這類不該打包的路徑。
- exit code `2`：先不要重跑覆蓋判讀脈絡，先保留 `.tar.gz`，再看 `errors.log` 決定是否針對失敗 node 補跑。

## 安全界線

- 這套工具以 read-only 收集為原則，不會主動修復或改變 Ceph 狀態。
- script 會遮蔽明顯含有 `password`、`secret`、`token`、`keyring`、`private key` 的文字行，但這不是完整 DLP。
- 分享 bundle 前仍應自行檢查是否包含內部 IP、hostname、路徑、帳號名稱或其他敏感資料。
- `verify-bundle.sh` 會阻擋明顯不該出現的 secret path，但不能保證內容完全沒有敏感資料。

## Lab smoke test

- 日期：2026-06-29
- cluster mode：`cephadm`
- host count：6
- exit code：0
- bundle verifier：`VERIFY PASS`
- node aliases：`monitor01`, `mon02`, `mon03`, `osd01`, `osd02`, `osd03`
- 已知 optional/read-only 非零紀錄：各 node 的 LVM 查詢（`pvs` / `vgs` / `lvs`）、`docker ps -a`、node-level `sudo cephadm ls --format json-pretty` 可能回非零；artifact 與 node 內部 `errors.log` 會保留原始輸出，整體 bundle 仍驗證通過。
