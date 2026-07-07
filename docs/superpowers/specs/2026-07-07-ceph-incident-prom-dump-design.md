# Ceph Incident Bundle — Prometheus metrics dump（`--prom-url`）

- 日期：2026-07-07
- 對象：`experiments/ceph-incident-bundle/`
- 目標：收 bundle 時可選擇性地從一個 Prometheus URL 把「執行當下往回 `--since`」的 ceph / node-exporter 相關 metrics 全部 dump 下來，壓縮後放進同一個 incident bundle。不給 URL 就完全跳過。

## 緣起

incident bundle 目前收的是指令輸出（ceph status、journal、kubectl…），缺少事發前一段時間的 metrics 時間序列。事後分析（延遲飆高、OSD 抖動、node 資源耗盡）常需要 Prometheus 裡的歷史數據，但 Prometheus 可能在事故處理中被重建或資料過期 — 收證據時一併 dump 下來才保得住。

## 決策（使用者已確認）

- 新旗標 `--prom-url URL`，**不給就完全不 dump**（連 `cluster/prometheus/` 目錄都不建，非 SKIPPED）。
- 時間窗 = 執行當下往回 `--since`（沿用既有預設 24h）。
- 用 **exporter（job）名稱**找 metrics：job 名稱符合 ceph / node 的都收。
- dump **放進同一個 bundle**（`cluster/prometheus/`），不另出一包。
- 機制採**逐 metric `query_range`**（取法 A）；不採單次大查詢（一次失敗全滅、回應過大）與 TSDB snapshot / federate（需 admin API 或只有瞬時值）。

## 介面

- `--prom-url URL`：Prometheus base URL（例 `http://192.168.18.166:9095`），須從工作機可達。
- `--prom-job-regex RE`：job 名稱過濾，預設 `ceph|node`，不分大小寫（bash ERE）。
- `--prom-step SECONDS`：query_range 取樣間隔，預設自動 `max(15, ceil(window/10000))`（避開 Prometheus 每 series 11,000 點上限）。
- `--prom-timeout SECONDS`：整段 metrics dump 的總時間預算，預設 600。用 `$SECONDS` deadline 檢查（bash 3.2 可用），超時即停止、index 標 `TRUNCATED`、記 errors.log、整體 exit 2。
- 每個 HTTP 請求沿用 `--timeout` 作 curl `--connect-timeout` 與 `--max-time`。
- `--since` 需可解析為秒數才能算窗：新 helper 支援 `N`（秒）、`Ns/Nm/Nh/Nd/Nw`；**只在給了 `--prom-url` 時**於參數驗證階段檢查，解析失敗 → exit 1（不動任何收集）。

## 行為

新檔 `lib/collect-prometheus.sh`（`collect_prometheus` 函式），由 `run/collect.sh` source，於 `collect_clusters` 之後、node 迴圈之前呼叫。全程在工作機本機跑 `curl`。

流程：

1. 前置檢查：`curl`、`python3`（解析 JSON 用）存在；缺任一 → `cluster/prometheus/SKIPPED.txt`（寫明缺什麼）+ errors.log + 回傳 2。
2. `GET /api/v1/status/buildinfo` → `buildinfo.json`。此請求同時當連線探測：失敗 → SKIPPED（unreachable）+ 2。
3. `GET /api/v1/targets` → `targets.json`（scrape 健康狀態，供事後對照）。
4. `GET /api/v1/label/job/values` → 全部 job 名稱，以 `--prom-job-regex` 過濾（不分大小寫）。無符合 → SKIPPED（列出見到的 job 清單）+ 2。
5. 每個入選 job：`GET /api/v1/label/__name__/values?match[]={job="J"}&start&end` → 該 job 在窗內出現過的 metric 名稱。
6. 每個 (job, metric)：`GET /api/v1/query_range`，query=`{__name__="M",job="J"}`，start=now−window、end=now、step 如上。原始 JSON 回應 gzip 存檔。單一 metric 失敗（HTTP 非 200 / curl 失敗 / 回應非 `"status":"success"`）→ 記 index 與 errors.log、繼續收其他、最後回傳 2。
7. query 參數一律用 `curl -G --data-urlencode` 傳遞（避免手工 URL encode）。

產出（皆在 bundle 內）：

```
cluster/prometheus/
  dump-info.txt          # url（遮 credential）、window start/end（UTC+epoch）、step、
                         # job 清單、metric 總數、成功/失敗/截斷統計
  buildinfo.json         # Prometheus 版本
  targets.json           # scrape targets 狀態
  <job>/index.txt        # 每列：metric 檔名 狀態(ok/failed/truncated)
  <job>/<metric>.json.gz # query_range 原始 JSON（gzip）
```

- job 名稱作為目錄名前先 sanitize（沿用 `ssh_debug_safe_name` 的字元白名單思路）；含 `"` 或 `\` 的 job 名稱無法安全塞進 matcher，直接跳過並記 errors.log。metric 名稱本身字元集安全（`[a-zA-Z0-9_:]`）。
- `--prom-url` 若含 `user:pass@`，寫入 `environment.txt` / `dump-info.txt` 前遮蔽為 `user:***@`。
- `environment.txt` 追加 `prom_url=`（遮蔽後）與 `prom_jobs=`。

manifest / CONTENTS.md：**每個 job 一筆** manifest entry（artifact 指向 `<job>/index.txt`，command 記 query_range 樣板與 metric 數），buildinfo / targets 各一筆 — 不逐 metric 記，避免上千列灌爆 CONTENTS.md。

exit code 語意不變：dump 任何層級的失敗都是 partial（整體 exit 2），bundle 照樣產出。

## Redaction / verify

- metrics 的 `<job>/<metric>.json.gz` **明確排除**在 `redact_bundle_text` 之外（find 加排除條件並附註解）：內容是數值 time series；單行數 MB JSON 走逐行 bash redact 極慢，且任一 regex 誤中會把整檔變 `[REDACTED]`。
- `dump-info.txt`、`index.txt`、`buildinfo.json`、`targets.json` 照常走 redaction。
- `verify-bundle.sh` 不需改：`.gz` 是 binary，`grep -I` 掃 secret 時自動跳過；路徑黑名單不受影響。

## 相容性

- 不給 `--prom-url` = 現有所有行為、測試、exit code 完全不變。
- 不影響 cephadm / rook / node 各層與 redaction、packaging 流程。

## 測試（TDD，fake `curl` on PATH + fixtures）

fake `curl` 依 URL 路徑回 canned JSON，環境變數注入故障（連不上、非 200、指定 metric 失敗）。

1. 不給 `--prom-url`：無 `cluster/prometheus/`、無 SKIPPED、exit 不變。
2. happy path：buildinfo/targets/dump-info/index 齊全；`<metric>.json.gz` gunzip 後是合法 JSON；start/end 與 `--since` 相符、step 正確；manifest 為每 job 一筆；exit 0。
3. URL 連不上：SKIPPED（unreachable）+ errors.log + exit 2。
4. 無符合 job（regex 過濾後空）：SKIPPED（含見到的 job 清單）+ exit 2。
5. job 過濾：混入 `grafana` 等 job 時只收 ceph/node 相關。
6. 單一 metric 失敗：index 標 failed、errors.log 有記錄、其他 metric 照收、exit 2。
7. 長窗自動放大 step：`--since 7d` → step > 15。
8. duration parser 單元測：`90`/`30m`/`24h`/`7d`/`2w`/非法值。
9. `--prom-timeout` 超時：index 標 TRUNCATED、exit 2（fake curl 注入延遲或以極小預算觸發）。
10. 缺 python3（PATH 遮蔽）：SKIPPED + exit 2。
11. `test-collect.sh` e2e：帶 `--prom-url` 的完整 collect，bundle 內含 `cluster/prometheus/`，verify PASS。
12. redaction 排除：塞一個假 `.json.gz`（單行、含會誤中 redact regex 的內容）進 metrics 目錄，跑完 redaction 後內容不變。

gate：`bash tests/run-tests.sh`（註冊新測試檔）+ `shellcheck lib/*.sh run/*.sh tests/*.sh` 0 + `make validate`。

## 真機驗證（deferred）

使用者之後提供開著 Prometheus 的環境再跑：對 lab 叢集實跑 `--prom-url`，確認 dump 大小、耗時、與 Grafana 對照數據一致。在此之前以測試 + Prometheus HTTP API 官方文件交叉驗證為準。

## 範圍外（YAGNI）

- 經 ssh tunnel 打叢集內 Prometheus（URL 必須工作機直達）。
- Basic auth / TLS client cert 以外的認證流程（URL 內嵌 `user:pass@` 可用即可）。
- metrics 的解析、繪圖、重灌回本機 Prometheus（bundle 只保原始 JSON）。
- 逐 metric 的 manifest 條目。
