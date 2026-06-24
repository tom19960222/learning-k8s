# ceph alert rules — 開發環境測試 harness（執行計畫）

這份是「給 AI agent / 使用者照著跑」的執行計畫，**不在網站路由內**（位於 `next-site/content` 之外）。zh-TW 敘述，指令一律英文照抄。讀者向的說明頁見 `next-site/content/ceph/features/prometheus-alert-testing.mdx`。

被測對象（single source of truth）：`next-site/content/ceph/features/prometheus-alert-design.mdx` 設計的那套「在 ceph-mixin 預設 rule 之上加一層維護友善 alert」。本 harness 逐條驗證它的 rules / recording rules / routing / silence。

## 分層（為什麼這樣分）

| Tier | 工具 | 測什麼 | 不測什麼 | 需要 |
|---|---|---|---|---|
| **A 規則邏輯** | `promtool test rules` | 每條 alert/recording rule 的 expr、`for:` 時長、輸出 label、`CephClientRisk` 排除清單、scoped 去重 | ceph 真的匯出什麼（用合成 series） | `promtool` |
| **B Routing** | `amtool config routes test` | label set → receiver；預設 aggregate（含 critical 的）不進 pager | — | `amtool` |
| **C live 整合** | 真 `prometheus` + `alertmanager` | 規則真載入評估、alert 真送達 receiver、silence 真壓制（host/daemon 粒度、alertname-scoping、生命線不被壓） | `for:` 時長（見下）| `prometheus`/`alertmanager`/`amtool`/`python3`/`jq`/`curl` |
| **D 真 ceph** | Proxmox + ceph v19.2.3 | 各情境 ceph 實際升的 health check、stopped daemon 是否仍有 metric | — | 真叢集（人工對照） |

**時序語意只在 Tier A 測**：`for:` 邊界（1m/5m/30m/30s）、flap 重置、pending→firing 都用 promtool 凍結時間精準驗。Tier C 不重評 `for:`——C2 是把「已成形的 alert」直接 POST 到 Alertmanager `/api/v2/alerts`，繞過 Prometheus 評估，所以不需要等 30 分鐘、也不需要 `for:`-縮短版規則（原 spec 預想的縮短版最後沒用到）。Tier C1 只確認規則載入後 `health=ok`，不需要 fire。

**dev 能驗到哪**：Tier A/B/C 證明「**若** metric/health check 以頁面假設的 label 與值存在，規則就如設計行為」。「ceph **真的**會升哪些 health check、stopped 的 mon/osd 是否仍匯出 metric」只有真 ceph 能答 → Tier D 用 ceph 原始碼當 oracle，標「在你環境跑後對照」。

## 前提（裝工具）

本機已有 `promtool` / `prometheus`（手動放在 `/usr/local/bin`）、`python3` / `jq` / `curl`。`amtool` / `alertmanager` 用官方 release binary（放 `~/go/bin`，已在 PATH）：

```bash
# darwin-amd64 範例（依你的 OS/arch 調整）
cd /tmp
curl -fsSL -o am.tgz https://github.com/prometheus/alertmanager/releases/download/v0.28.1/alertmanager-0.28.1.darwin-amd64.tar.gz
tar xzf am.tgz && cp alertmanager-0.28.1.darwin-amd64/{amtool,alertmanager} ~/go/bin/
amtool --version && alertmanager --version
```

run 腳本找 binary 的順序：PATH →`~/go/bin`→ harness 自帶 `.bin/`。

## 一鍵跑

```bash
bash experiments/ceph-alert-rules/run/all.sh    # A→B→C，任一 tier 非 0 即整體非 0
# 或單跑
bash experiments/ceph-alert-rules/run/tierA.sh  # guard + lint + promtool（無服務）
bash experiments/ceph-alert-rules/run/tierB.sh  # amtool routing（無服務）
bash experiments/ceph-alert-rules/run/tierC.sh  # 起真 prometheus/alertmanager
```

PASS 判準：每個 tier 結尾印 `TIER X PASS`，`all.sh` 結尾 `ALL PASS`，exit 0。各 tier 輸出存 `results/`。

## 目錄

```
rules/                         被測物（逐字抽自設計頁，不得改寫；lib/check-rules-match-page.sh 比對）
  ceph-stability-first.yml     CephClientBlocked/Risk/MonQuorumLost/ExporterDown/LowPriorityNotice
  ceph-scoped-availability.yml 兩條 recording rule + OSD/MON scoped 三條
  ceph-mon-quorum-dynamic.yml  文末動態 majority 版（邊界測試用）
  _default-mixin.yml           CephHealthError/CephHealthWarning（ceph-mixin v19.2.3 逐字）
  alertmanager-route.yml       被測 routing（Tier B 用）
tests/
  tierA-promtool/*.test.yml    13 個 promtool 測試（每條規則一個 + maintenance-thesis + 轉換 edge + dynamic）
  tierB-routing/routes-test.sh amtool routing 斷言
  tierC-live/                  webhook-sink.py + alertmanager-live.yml + run.sh
  tierD-realceph/README.md     真 ceph 原始碼 oracle 對照表
lib/                           check-rules-match-page.sh、prometheus-load-check.sh
run/                           tierA/B/C.sh、all.sh
results/                       跑完的輸出
```

## 這套測試抓到的真 bug（F1）

`CephMonQuorumLost` 原規則 `count(ceph_mon_quorum_status == 1) < 2`，在**全部 mon 掛掉**時 `count(==1)` 為空、`count(空)` 無 sample，`< 2` 算不出結果 → **不 fire**（最壞情況靜默）。Tier A `mon-quorum-lost.test.yml` 餵「3 台全 0」重現了 `got:[]`。已修為 `(count(...) or vector(0)) < 2`（設計頁與 rules 同步，附 callout），測試斷言修正後全掉也 fire。詳見 `.superpowers/sdd/FINDINGS.md`（scratch）與測試說明頁。

## 給 AI agent 的提醒

- 測試靠 exit code 判 PASS/FAIL，無 GUI、無互動。
- `promtool` 對 unknown alertname 直接 hard-fail，所以 negative（`exp_alerts: []`）測試不會因為「規則整條被刪」而假性通過。
- Tier C 的等待全用「輪詢 + timeout」，不用固定 sleep；port 用 9747(prom)/9748(sink)/9749(am)，被占用先清。
