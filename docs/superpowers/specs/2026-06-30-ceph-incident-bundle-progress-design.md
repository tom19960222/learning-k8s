# Ceph Incident Bundle — Progress Output Design

- 日期：2026-06-30
- 對象：`experiments/ceph-incident-bundle/`
- 目標：執行時顯示進度,讓使用者知道工具在動(目前整個多分鐘的收集過程幾乎完全靜默)。

## 緣起

現狀 `collect.sh` 對使用者幾乎不輸出:開頭一行 timeout WARNING、結尾 `bundle: <path>`,其餘(探測每台 node、~24 條 `cephadm shell` cluster 指令、逐台 node 收集、redact、verify、tar)全靜默。最慢的是 cluster-ceph 的 ~24 條指令(每條起一個 container,~2 分鐘),使用者完全看不到動靜。

## 決策（使用者已確認）

1. 進度預設**開**;`--quiet` 關。
2. 進度走 **stderr**;stdout 維持只有 `bundle: <path>`(給 script 抓)。
3. cluster-ceph 層**逐條指令**顯示。

## 架構

- 在 `lib/common.sh` 新增 `progress()` helper:除非 `CEPH_INCIDENT_QUIET` 非空,否則印 `[<utcstamp>] <msg>` 到 **stderr**。
- 只從 **workstation 端**呼叫(`run/collect.sh` 編排、`lib/collect-cluster-cephadm.sh` 逐條、`lib/collect-cluster-rook.sh` 逐步)。**不從 `lib/collect-node.sh` 呼叫**(它在遠端跑,stderr 會經 ssh 回傳交錯,且部分輸出會混進 node tar 流)。
- `run/collect.sh` 加 `--quiet`,設 `export CEPH_INCIDENT_QUIET=1`,讓被 source 的 cephadm/rook collector 在同一行程內自動沿用。

## 進度點

| 階段 | 訊息 |
|---|---|
| 開頭 | `starting: mode=<mode>, <N> hosts` |
| 探測 | `probing <N> nodes for capabilities…`;每台 `[i/N] probe <target>: <caps or none>` |
| ceph 層 | `collecting ceph cluster from <source>…`;每條 `[k/total] ceph <args>` |
| rook 層 | `collecting rook from <source> (ns=<ns>)…` |
| node 層 | 每台收集前 `[i/N] node <alias>…`;收完 `[i/N] node <alias>: ok`/`SKIPPED (exit <rc>)` |
| 收尾 | `redacting…` / `verifying…` / `packaging…` |
| 結束 | `bundle: <path>`(stdout,不變) |

逐條 ceph 進度由 `collect_cluster_cephadm` 算 total（`#json_specs + #text_specs`,crash info 另計或標 `crash`），在每次 `collect_cephadm_command` 前印。

## 相容性 / 不變的事

- 純顯示;不改任何收集行為、artifact、exit code(0/2/1)、bundle 內容。
- 既有測試抓的是 stdout 的 `bundle:` 與檔案系統,不受 stderr 進度影響。
- `--quiet` 下完全不印進度,但 `bundle:`(stdout)與錯誤訊息照舊。

## 測試

1. 一般 run:stderr 含進度(出現 `probing`、`node <alias>`、`ceph ` 之類關鍵字);stdout 仍有 `bundle:` 且**不含**進度行。
2. `--quiet`:stderr 不含進度關鍵字;bundle 仍產出、stdout 仍有 `bundle:`、exit code 不變。
3. `progress()` 單元:`CEPH_INCIDENT_QUIET=1` 時不輸出、未設時輸出到 stderr(可在 test-common 驗)。

## 範圍外（YAGNI）

- spinner / 百分比 / cursor 控制 / tty 偵測。
- 遠端 node 收集的逐步進度(只報「node X 開始/結果」,不報 node 內每條指令)。
