# Ceph Incident Bundle — `--kube-mode local|remote`

- 日期：2026-06-30
- 對象：`experiments/ceph-incident-bundle/`
- 目標：讓 rook 層的 `kubectl` 可選擇在**本機(跳板機)**或**inventory node** 上跑。預設 `remote`(現狀,完全相容)。

## 緣起

使用者的 `kubectl` + kubeconfig 在執行工具的跳板機上,不在任何 inventory node。現狀 auto-detect 只會探測 node 上的 kubectl 並在 node 上跑,故收不到 rook。rook collector 其實早已支援本機模式(`--ssh-target` 為空時直接跑 `kubectl`),只是 `collect_clusters` 一律帶 `--ssh-target`。

## 決策（使用者已確認）

- 加一個參數切換 local / remote。
- 預設 `remote`(維持現狀)。
- 不做自動 fallback(避免本機 kubeconfig 指到別的 cluster 默默收錯)。

## 介面

- 新旗標 `--kube-mode <local|remote>`,預設 `remote`。非法值 → exit 1。
- `remote`(預設):現狀。探測 inventory node 找第一台有 kubectl 的,經 ssh 在該 node 上跑 `kubectl`。
- `local`:在跳板機本機跑 `kubectl`(`collect_cluster_rook` 不帶 `--ssh-target`),跳過對 node 的 kubectl 探測。
- `--kube-context` 兩種模式都套用。

## 行為

- `collect_clusters` 收 `kube_mode`:
  - rook 來源探測只在 `remote` 時進行(probe 迴圈條件:`want_ceph 需要` 或 `want_rook && kube_mode=remote`)。
  - rook 層:`local` → `collect_cluster_rook`(不帶 `--ssh-target`,本機);`remote` → 同現狀(帶 `--ssh-target rook_source`)。
  - `auto` 模式仍對 rook collector 帶 `--allow-skip`(local 下本機沒 kubectl/namespace 也只是資訊性 skip)。
- 進度:`collecting rook from local kubectl…`(local)/ `from <node> (ns=…)`(remote)。
- `environment.txt`:`rook_source=local`(local 模式)或 node target。
- ceph 層、node 層、exit code、redaction、bundle 內容皆不變。

## 相容性

- 預設 `remote` = 現有所有行為與測試不變。
- `local` 走 collector 既有的本機 kubectl 路徑(`command -v kubectl` 本機檢查 + 本機執行)。

## 測試

1. `--kube-mode local`(fake 本機 kubectl on PATH):rook 層在**本機**跑 kubectl(ssh log 無 `kubectl`),收到 `pods-wide.txt`,`environment.txt` `rook_source=local`,`--kube-context` 有套用。
2. `--kube-mode local` 但本機無 kubectl:auto → rook SKIPPED(資訊性)、不影響 ceph/node;明確 rook 模式 → exit 2。
3. 預設(remote)既有 auto 雙層測試不變(node 上跑 kubectl)。
4. `--kube-mode bogus` → exit 1。
5. lab:`--mode auto --kube-mode local`(lab 無 rook,本機 kubectl 指向... 不一定有)→ 主要驗 ceph 層不受影響、rook 資訊性 skip、exit 行為合理(本機若無 kubectl → skip)。

## 範圍外（YAGNI）

- 自動 local/remote fallback。
- 多 context 各收一份。
