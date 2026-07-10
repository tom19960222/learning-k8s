# SP: Ceph 內容重構 — Design Spec

- 日期：2026-07-10
- 狀態：使用者已選定方案 A；本 spec 由驗證過的盤點結果落成
- 前置討論：Codex 完成初步盤點與三方案比較，使用者選 A；本 session 以 11 個平行查證 agent
  對 ceph v19.2.3（commit c92aebb）、ceph-csi v3.14.0 原始碼與 repo 內實驗證據逐條驗證後定稿
- 驗證產物：workflow `wf_0d2aa12c-e42`（11/11 agent，所有結論附 file:line 逐字引句）

## 0. 範圍與已確定決策

**目標**：Ceph 24 篇文章的架構重整。只新增新文章、不改舊文章內文；全部新文章通過
review 後，一次性把被取代的舊文章 archive（archive = frontmatter 標記 + 導覽移組，內文不動）。

**每篇新文章的讀者假設**：完全不知道我們做過什麼的人，讀單篇就能回答——為什麼做、
做了什麼、實驗了什麼、每個實驗調了什麼參數、預期效果、實際效果、哪裡可以改進、建議
怎麼改進、總結（writing-experiment-reports 的七問契約）。需要前置知識時，開頭明示
prerequisite（≤2 篇 + 為什麼必讀）；做不到明示前提的內容必須自包含。

**方案 A 邊界**：
- Ceph 新架構納入全域閱讀地圖；`vm-storage-perf`、rook、kubevirt 等其他分類的頁面不動。
- Ceph 新文章引用其他分類的實驗數據（如 kubevirt-rbd-tuning 的 E-32/E-34）時附連結
  與摘要數字，不重寫全文。
- `experiments/` 下的工具 README 與 harness 不受「不改舊文章」約束（它們是工具文件，
  跟隨工具現況），但改動仍走 TDD 與 shellcheck 約定。

**寫作契約**：
- 實驗報告類文章一律用 `skills/writing-experiment-reports/SKILL.md`（七問、規劃總覽表、
  逐實驗五欄、參數建議總表、主管 persona review gate）。
- source-first 頁沿用 `skills/source-first-topic-page/SKILL.md` 與 zero-fabrication 規則。
- 台灣繁中、never-translate 清單、不在 MDX import 元件、測驗放 quiz.json、圖表用靜態 PNG。

## 1. 現況問題清單（全部經本次逐條查證，非轉述）

### 1a. Source-level 錯誤（三條指控全部 confirmed）

| # | 頁面 | 錯誤 | 反證錨點 |
|---|---|---|---|
| P1 | `clock-skew-magnitude-ladder` | 「>5s skew → lease 崩 → election churn」因果鏈錯：`handle_lease` 收到過期 lease 照樣 ACK 並重設 10s timer（2×`mon_lease`），leader 每 3s renew，穩態 skew 下 `lease_timeout` 永不觸發；真實後果是該 peon 永久不可讀（`is_lease_valid()` false），不是反覆 election。另「peon 的 is_writeable 垮」是類別錯誤（`is_writeable` 要求 leader） | `Paxos.cc:1123-1144`（ACK+reset）、`Paxos.cc:1206-1207`（timer=訊息斷流計時器）、`Paxos.cc:1215-1221`（唯一 bootstrap 路徑）、`Paxos.cc:1486-1490` |
| P2 | `clock-skew-magnitude-ladder` | 「mon 時鐘跳回後立刻 rotate 出正確時間的 key、擠掉未來 key」與 source 相反：`need_new_secrets(now)` 在 `current().expiration > now` 時回 false → 完全不 rotate、未來 key 不被淘汰；真實後果是 rotation 凍結長達偏移量的時間。文章 line 323 對 OSD 端其實已寫對同一邏輯 | `Auth.h:324-326`（need_new_secrets 條件）、`Auth.h:314-318`（淘汰只在 add() 內）、`CephxKeyServer.cc:180-193` |
| P3 | `recovery-throttle-runtime` | 「mClock 會把 injectargs rollback、必須先開 override 才生效」錯：injectargs 寫入最高優先層 `CONF_OVERRIDE`，mClock 防寫只對 mon config DB 發 `config rm`（對 injectargs 是 no-op）+ clog warning；注入值在該 OSD 上生效直到重啟。clog 的 "did not take effect" 在 injectargs 情境是 source 自身的誤導文案。文章 line 359 對照表其實已寫對，與 TL;DR/Callout 自相矛盾 | `config.cc:851`（injectargs→CONF_OVERRIDE）、`config.h:30-38`（層級）、`config_values.cc:24-26,60-62`、`OSD.cc:10229-10239`（rollback 只有 config rm + clog） |
| P4 | `rbd-and-csi` | IO 流程圖把 krbd 也導進 librbd 的 `librados→Objecter` 漏斗（krbd 在 kernel 內自行 striping，不經文章引用的任何 librbd 碼）；從未提 ceph-csi 預設 mounter=krbd（預設部署下文章詳解的 `ImageRequest.cc` 不在 data path 上）；NodeStage/NodePublish 描述與兩種 volumeMode 實際行為都不符（Filesystem mode 在 NodeStage 就 mkfs+mount 到 stagingPath；Block mode 才 bind device 檔）。另：24 篇中唯一沒有版本錨的頁 | `rbd_util.go:54-55`、`nodeserver.go:213-214,253-261,800,840-844,875,896-897`、`rbd_attach.go:399` |

### 1b. 被後續研究推翻／大幅修正的建議

| # | 頁面 | 問題 |
|---|---|---|
| P5 | `slow-ops-and-bluestore-alerts` | 「怎麼改進 alert」下半整段被 2026-07-09 研究推翻：BLUESTORE_SLOW_OP_ALERT 從「第 1 層偵測」降級為盤後追查器（latch 24h 不適合 pager）；latency 均值 alert 的「唯一辦法」宣稱被 H-007 violated 推翻（8s 卡頓均值僅 0.672s，連 1s 門檻都過不了）；daemon SLOW_OPS 規則三要素（instant expr / for:1m / warning）全部要改（H-023：44.7s 真事件兩條 alert 全默）；「能指出是哪顆 OSD」被 H-025 推翻（怪錯人：亮的是別台 primary）。上半機制章節（兩 metric 來源鏈、七缺口表）正確且被 E-01 真機實證強化。缺：R1-R4、三層盲區、Squid 版本依賴、idle 盲區 |
| P6 | `mon-quorum-loss-impact` | 「新 PVC 會失敗」被真機部分推翻（新 PVC 反而 Bound——CSI provisioner 是既有連線；卡的是 node 端全新 kernel `rbd map`）；「既有 I/O 可能持續」的保守推測可升級為 fio 實證（全 pattern ≈ baseline）。quorum 數學、lease 時序、dataplane/control plane 分界仍正確 |

### 1c. Alert 系列時間拼貼（12 條 finding，擇要）

git 時序：testing 建立 06-25 → real-cluster Tier D 06-26（修 OSD_FLAGS、加 External）→
design/testing prose 修 07-04 → real-lab-findings 補 22/22 07-06。每波更新只同步了部分頁面：

- **`prometheus-alert-testing`（拼貼最嚴重）**：宣稱 Tier D 未跑/`tierD-realceph/` 只是對照表
  （實際 06-26 已跑完且是可執行 harness）；frontmatter 自稱「四層逐一驗過」與內文 Tier D ❌
  互斥；「25 個排除 name」「5 個低優先 name」（現行 26/8）；OSDMAP_FLAGS fixture 引文與
  harness 實檔（已改 OSD_FLAGS）漂移；「noout 自動設 → OSDMAP_FLAGS」oracle 宣稱被真機
  發現一推翻。
- **`prometheus-alert-real-lab-findings`（最危險的誤導源）**：內嵌 v2 YAML 缺 `OSD_FLAGS`
  （排除清單與 LowPriority 都缺）、routing 缺 `ceph_external`——讀者照抄會重現已修掉的
  「例行維護 page oncall」bug，並把唯一可靠的 quorum 生命線排除在 pager 外；同頁 L349
  「還沒逐條真機」vs L9「22/22 完成」矛盾；「27 條 rule」不含 dynamic/external（實際 29）。
- **`prometheus-alert-design`**：最接近現況（rule YAML 與 harness 逐字一致、有防漂移 guard），
  僅 L342/L351「第二台 mon 掉會 page 的生命線」prose 與同頁 L175 callout（承認 mgr 凍結盲區）
  矛盾。
- **`prometheus-alert-real-cluster`**：歷史與現況都成立，僅「3-node」稱呼（實際 6 host）與
  S 編號撞名（S1-S5 vs real-lab-findings 的 S1-S22 指不同場景）兩個小疵。
- **緩解命名分裂**：同一個 quorum 盲區緩解存在兩套並存實作無互相指涉——real-cluster 的
  `CephMonQuorumLostExternal`（自製 mon-tcp-probe.py / `ceph_mon_tcp_up`）vs blind-spot 頁的
  `CephMonQuorumLostBlackbox`（blackbox_exporter / `probe_success`）。

### 1d. 證據斷鏈

- **alert real-lab 22 場**：committed ledger（`EVIDENCE-SUMMARY-2026-07-04.md`）只索引 3 場
  且明寫受測 rule 只有 2 條；「22/22 全數驗證」在 repo 內 unverifiable。raw bundle 在主
  checkout `experiments/ceph-alert-real-lab/results/`（3,636 個目錄，gitignored，僅本機）。
- **incident-bundle --prom-url**：README:142 仍寫「尚未對真 Prometheus 驗證」，但 2026-07-10
  真機驗證已全過——該驗證在 repo 內無任何 committed 證據。
- 證據鏈完好的對照組：`ceph-mon-quorum-blind-spot`（raw results 直接進 git）、
  `ceph-slow-ops-detection`（12 run 的 EVIDENCE-SUMMARY 索引 + REPORT 已 commit）、
  `ceph-alert-rules`（tierD `results/observations.md` S1-S5 真機觀測已 commit）、
  `kubevirt-rbd-tuning` / `rbd-io-perf` / `timesyncd`（ledger 齊）。

### 1e. incident-bundle-runbook 落後工具現況

8 項能力未涵蓋（--mode auto 探測、--kube-mode remote|local、--operator-namespace/external
拓樸、redaction 開關與擴充範圍、ssh-debug、progress/--quiet、--timeout/--node-timeout 分層、
--prom-url 整層）+ 5 處與現行為不符（rook 層預設已是 remote kubectl；cephadm 層改為
direct→sudo→cephadm shell 三階擇優；超大 log 改收 tail+.TRUNCATED；bsdtar xattr 已在源頭修掉；
environment.txt 新增 ceph_source/ceph_runner/rook_source 欄位）。詳細清單（a)-(n) 見驗證
產物 `findings_incident.json`。

### 1f. 導覽結構失效

- learningPaths 只涵蓋 10/24（「OSD 維運命令」0/2、「監控與告警」1/7）。
- feature-map：24 nodes / 48 edges，16 個 node 構成單一強連通分量、32 條元素迴圈
  （5 條回饋邊造成），不能當閱讀順序。
- 只有 5 篇在開頭宣告 prerequisite；三套結構對 rbd-and-csi 的位置互相矛盾
  （group 排最後 vs beginner path 排第 2）。

## 2. 目標架構：雙軸

**軸 1 — 主分類（featureGroups 重排）**，按讀者任務分 6 組 + Archive：

| 組 | 內容 |
|---|---|
| 🚀 從這裡開始 | architecture |
| 🧮 核心模型與資料路徑 | crush-and-placement, crush-straw-straw2, pool-pgnum-pgpnum, osd-and-bluestore, bluestore-deep-dive, **N6 rbd-datapath-and-csi** |
| 💥 故障模型與時間 | osd-flapping, pg-health-states, mon-clock-skew-detection, cluster-time-skew-impact, **N4 clock-skew-failure-modes**, **N3 mon-quorum-loss-io-lab**, mon-quorum-detection-blind-spot |
| ⚙️ 效能與參數決策 | mclock-osd-scheduler, **N5 recovery-throttle-and-mclock** |
| 📡 可觀測性與 alerting | **N1a slow-ops-detection-mechanisms**, **N1b slow-ops-fast-detection-lab**, **N2a ceph-alert-policy-current**, **N2b ceph-alert-validation-methodology**, **N2c ceph-alert-real-lab-report** |
| 🛠️ 維運命令與事故處理 | osd-ok-to-stop, osd-safe-to-destroy, **N7a incident-bundle-operator-runbook**, **N7b incident-bundle-validation-report** |
| 📦 Archive（歷史版本） | 被取代的 10 篇（見 §4） |

**軸 2 — 文章類型**，每篇 frontmatter `category:` 標示（feature page 元件已會渲染
`data.category` badge，`page.tsx:51-53`，目前無人使用）：

- `mechanism`：source-first 機制拆解；evergreen；證據層級以 T1 為主。
- `experiment-report`：日期化（slug 或 as-of 註明時期），**不可事後改寫歷史**；
  遵循 writing-experiment-reports。
- `decision-guide`：吸收最新實驗的「現行建議」；evergreen；每條建議附證據連結。
- `runbook`：可直接操作；含進場 gate、預期輸出、失敗處理、回退、健康驗證。

**時間狀態原則**：歷史事實放 experiment-report（保持當時快照＋明標 as-of）；「目前該
怎麼做」只放 decision-guide / runbook。同一主題不再出現「一頁裡新舊段落疊加」。

**feature-map 定位**：降級為概念關聯圖，重建為只含 active 頁的版本（移除 archived
nodes、加入新 nodes）；閱讀順序的權威來源 = 各文章開頭的 prerequisite 宣告 + learningPaths。
prerequisite 宣告構成的圖必須是 DAG（新文章間互相引用時檢查）。

## 3. 新文章開頭契約（每篇必備）

frontmatter：`layout: doc`、`title:`、`description:`、`category:`（四類型之一）。

開頭固定「本頁定位」區塊（純 Markdown，不用元件）：

1. 文章類型與 as-of 日期（experiment-report 必填 as-of；mechanism/decision-guide 寫
   「隨 source/rule 版本更新」）。
2. 版本錨點：ceph v19.2.3（commit c92aebb）、ceph-csi v3.14.0、Prometheus/lab 拓樸
   （用到才寫）。
3. 閱讀前提：最多 2 篇 + 各一句「為什麼必讀」；沒有就明寫「本頁可獨立閱讀」。
   prerequisite 不得指向 archived 頁。
4. 證據層級標示：T1 source / T2 官方文件・外部資料 / T3 真機實證——在關鍵結論處標，
   不是裝飾；純 mechanism 頁誠實寫「本頁只有 T1，哪些主張仍欠 T3」。
5. 取代宣告：本頁取代哪些舊文章（archive 後 banner 反向指回來）。
6. 「相關閱讀」一律放文末，不得用來補正文缺失。

實驗報告類另加 writing-experiment-reports 全套：前提章（SUT、負載矩陣、判準、噪音帶）、
規劃總覽表（planned = executed + merged + skipped 對帳）、逐實驗五欄（調了什麼參數／
為什麼測／事前 prediction／before→after 數字+倍率／建議）、參數建議總表（值+條件+
變更方式）、被推翻的預測醒目標示、limitations/incidents/open questions。

## 4. 新文章清單與取代對應

### Wave 1 — 證據補救（不是文章，是新文章的地基）

| # | 產出 | 內容 |
|---|---|---|
| W1a | `experiments/ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md` | 從主 checkout 本機 raw results（3,636 個 gitignored 目錄）重建 22 場 machine-readable ledger：每場 scenario id、run 時戳、注入方式、ceph 端證據、Prometheus/receiver 證據、negative assertions、rollback、HEALTH_OK 確認。只能在本機執行（raw 檔不在 git） |
| W1b | incident-bundle --prom-url 真機驗證證據 | 從本機找回 2026-07-10 驗證 artifacts；找不到就在真 lab 重跑一次收證據（read-only 操作），落 `experiments/ceph-incident-bundle/` 下 committed 摘要；同步更新 README:142 時效 |

### Wave 2 — 新文章（11 篇）

| # | slug | 類型 | 取代 | 素材（已驗證可用） |
|---|---|---|---|---|
| N1a | `slow-ops-detection-mechanisms` | mechanism | `slow-ops-and-bluestore-alerts`（與 N1b 共同取代） | 舊頁上半（來源鏈正確）+ 三層盲區 + H-025 + H-011/H-014 邊界 + Squid 版本依賴；修正「22 處呼叫」→ 對 pinned source 重數（研究枚舉 29 處） |
| N1b | `slow-ops-fast-detection-lab` | experiment-report（as-of 2026-07-09） | 同上 | `ceph-slow-ops-detection/`：REPORT + HYPOTHESES（25 條：19C/4V/2P）+ 12 run 索引 + rules/ceph-slow-ops-fast.yml；R1 +14s / R2 +20s / R3R4 +45~60s vs 舊 ~120s；被推翻的 4 條預測 |
| N2a | `ceph-alert-policy-current` | decision-guide | `prometheus-alert-design` | rules/ 7 檔（29 條 rule 全列含 dynamic/external）、routing、silence SOP、每條規則驗證狀態表；欽定 quorum 盲區緩解 canonical 命名（建議 Blackbox 版，standard exporter）；**遷移 check-rules-match-page.sh guard 指向本頁** |
| N2b | `ceph-alert-validation-methodology` | mechanism | `prometheus-alert-testing` | 四層 Tier A-D 分工與「Tier A 證明 IF」哲學、F1 完整故事、三個 PromQL gotcha、注入手法目錄（cgroup io.max 等）、綠燈不可過度解讀清單——全部同步到現況（26/8 個 name、Tier D 已完成） |
| N2c | `ceph-alert-real-lab-report` | experiment-report（as-of 2026-07） | `prometheus-alert-real-lab-findings`、`prometheus-alert-real-cluster` | W1a ledger + 22 場總表 + 16 發現 + tierD observations.md（S1-S5）+ 兩頁的不可替代內容（發現一/二機制、逐欄對帳表）；統一場景編號 |
| N3 | `mon-quorum-loss-io-lab` | experiment-report（as-of 2026-07-08） | `mon-quorum-loss-impact` | `ceph-mon-quorum-blind-spot/`：REPORT §4（真機時序、fio IO 矩陣、新 PVC Bound 反直覺）+ 舊頁正確的 quorum 數學/lease 時序/dataplane 分界（T1 部分移植並修正「新 PVC 會失敗」） |
| N4 | `clock-skew-failure-modes` | mechanism | `clock-skew-magnitude-ladder` | 三線框架與 client ticket 免疫（正確部分移植）；線 1 改寫（穩態 skew → peon 不可讀、election churn 需訊息斷流 ≥10s 或時鐘跳變）；線 2 方向 B 改寫（rotation 凍結；「校時跳回」警告降級為未驗證假說或刪除）；沿用文章 line 323 已寫對的 OSD 端邏輯 |
| N5 | `recovery-throttle-and-mclock` | mechanism + decision-guide | `recovery-throttle-runtime` | injectargs 真實行為（CONF_OVERRIDE、生效至 restart、clog 誤導文案是 source quirk）、config set rollback（舊頁正確部分）、_recover_now/四層 gate、ping-pong 止血；可選 T3：真機 `ceph daemon osd.N config show`（level=override）驗證 |
| N6 | `rbd-datapath-and-csi` | mechanism | `rbd-and-csi` | 兩條 data path 拆開（krbd kernel 自行 striping vs librbd userspace）、CSI 預設 mounter=krbd、volumeMode Filesystem/Block 正確流程、tryOtherMounters；object layout/feature dependency/責任邊界（舊頁正確部分移植）；補版本錨（ceph v19.2.3 + ceph-csi v3.14.0）；引用 vm-storage-perf 的量化結論（連結） |
| N7a | `incident-bundle-operator-runbook` | runbook | `incident-bundle-runbook`（與 N7b 共同取代） | 工具現況全能力（findings_incident.json 的 (a)-(n) 清單）；目標讀者維持「只懂基本 Linux」 |
| N7b | `incident-bundle-validation-report` | experiment-report | 同上 | 2026-06-30 multi-fault 矩陣（README + docs/superpowers/reviews/2026-06-30-lab-validation.md）+ W1b 的 prom dump 驗證 |

### 保留 active 的 14 篇（不改內文）

architecture, crush-and-placement, crush-straw-straw2, pool-pgnum-pgpnum, osd-and-bluestore,
bluestore-deep-dive, mclock-osd-scheduler, osd-flapping, pg-health-states,
mon-clock-skew-detection, cluster-time-skew-impact, osd-ok-to-stop, osd-safe-to-destroy,
mon-quorum-detection-blind-spot。

已知的小缺口用新文章互鏈吸收，不改舊文：pg-health-states 的 SLOW_OPS/MON_DOWN 段由
N1a/N2a 補充；bluestore-deep-dive 的 BLUESTORE_SLOW_OP_ALERT 段由 N1a 深化；
osd-flapping 是推演等級 + `ceph osd rm-noout` 命令名疑點 → 列入未來工作（§9），
E-34（noout p999 1146→335ms）數據由 N2a/N1a 引用。

### Archive 的 10 篇

slow-ops-and-bluestore-alerts、prometheus-alert-design、prometheus-alert-testing、
prometheus-alert-real-lab-findings、prometheus-alert-real-cluster、mon-quorum-loss-impact、
clock-skew-magnitude-ladder、recovery-throttle-runtime、rbd-and-csi、incident-bundle-runbook。

## 5. Archive 機制

- Archive 階段（所有新文章過 review 之後）對舊頁 frontmatter 加兩個欄位（內文零改動）：
  `archived: true`、`supersededBy: <new-slug>`（可為 list）。
- `app/[project]/features/[slug]/page.tsx` 擴充：讀到 `archived` 時在標題上方渲染
  banner——「本頁為歷史版本（已於 2026-07 被取代），現行版本請看 →〈新頁 title〉」。
  沿用現有 gray-matter data 流，不動 MDX pipeline。
- featureGroups 尾端加「📦 Archive（歷史版本）」組；archived 頁從原組移除。
- learningPaths 與 feature-map 不引用 archived 頁。
- archived 頁保留原 URL（不 redirect、不刪檔），`features` 陣列保留 slug（validate 的
  slug↔MDX 對應不變）。
- 站內既有指向 archived 頁的連結（如 mclock → recovery-throttle-runtime）不改：讀者落到
  archive 頁會看到 banner 導向新頁，鏈路不斷。

## 6. 導覽重構

- featureGroups 按 §2 重排（一次 PR 內完成，與 archive 同步）。
- learningPaths 重寫三條：beginner（architecture → crush-and-placement → N6）、
  intermediate（+ pool-pgnum-pgpnum → osd-and-bluestore → mclock → pg-health-states）、
  advanced（bluestore-deep-dive → osd-flapping → 時間三頁 → N3 → N1a/N1b → N2a → N7a）。
  目標：每篇 active 頁至少出現在一條 path 或組內敘事。
- feature-map.json 重建：nodes = 25 篇 active（14 舊 + 11 新），edges 標語意；
  移除 archived nodes。
- `projects.ts` 的 ceph `story`/`problemStatement` 場景若引用 archived slug，同步更新
  連結目標（story 是導覽 metadata，非文章內文）。

## 7. 品質閘門與實作流程

1. 流程：本 spec → `superpowers:writing-plans` 出 plan → `superpowers:subagent-driven-development`
   實作。每篇新文章 = 一個獨立任務（寫 → review → 修）。
2. Review gate：
   - mechanism / decision-guide / runbook 頁 → `skills/reviewing-source-first-pages`
     多視角 review（正確性對 pinned source + 非專家可讀性）。
   - experiment-report 頁 → writing-experiment-reports 的主管 persona 七問 review，
     iterate 到 ACCEPT。
   - reviewer 發現的內容錯誤要回灌到其他做同一主張的 artifact。
3. Zero-fabrication：新頁所有 file:line 引用必須由 writer 對 pinned source
   （主 checkout `ceph/` v19.2.3 c92aebb、`ceph-csi/` v3.14.0；本 worktree submodule 未
   checkout）重新驗過；本次驗證產物（scratchpad `verify-results/*.json`）提供起點但不可
   照抄不驗。
4. Validate 紀律：writer subagent 只改文字、不跑 validate；orchestrator 在每批整合後跑
   一次 `make validate`（baseline 已確認全綠）。
5. 順序約束：W1 先行（N2c、N7b 依賴其產出）；N1a 先於 N1b（prerequisite 關係）；
   N2a 遷移防漂移 guard（`check-rules-match-page.sh` 現寫死指向 design 與 real-lab-findings
   兩頁）必須與該兩頁 archive 同一批完成，期間 guard 不得斷。
6. Archive 與導覽重構放最後一批，全部新文章 review 過後執行；之後跑最終
   `make validate` + 全站互鏈檢查（無 dead link、prerequisite 無環、archived 頁不被
   active 頁當 prerequisite）。
7. Commit 節奏：每批一 commit（W1 / 各文章 / 導覽+archive），訊息中文、
   `git commit --no-gpg-sign`；push 用 repo 內 key（CLAUDE.md 約定）；PR 走
   `pull/new/<branch>` URL。

## 8. 驗收標準

- 24 篇舊文全數處置明確：14 active + 10 archived（banner 指向新頁）。
- 11 篇新文章各自通過對應 review gate；experiment-report 頁能讓「只讀這一份」的人
  回答七問。
- `make validate` exit 0；learningPaths 覆蓋率提升（每篇 active 頁可從導覽到達）；
  **新文章**的 prerequisite 圖無環且不指向 archived 頁（保留 active 的舊文若原本連向
  被 archive 的頁，不改——讀者經 banner 導向新頁）；同主題不再有互相矛盾的現行陳述
  （alert 規則的 single source of truth = N2a + rules/，防漂移 guard 指向新頁）。
- 22/22 宣稱可從 git 內 ledger 稽核（W1a）。

## 9. 風險、邊界、未來工作

- **raw results 只在本機主 checkout**：W1a 必須本地執行；期間主 checkout 若清理 results/
  證據即永久遺失（kubevirt E-35 已有先例）。優先級最高。
- **incident prom 驗證證據**：可能需要重跑真機（read-only）；若 lab 不可用則 N7b 對應
  段落標 unverifiable 並列入待補。
- **舊頁在新頁上線前仍在站上**（含已證實的 source-level 錯誤）：接受——使用者約束是
  「不改舊文章」，錯誤修正以新頁 + archive banner 交付。
- **osd-flapping 推演等級**：6 情境未真機驗證、`ceph osd rm-noout` 命令名 unverifiable
  ——列未來工作（真機 flapping 實驗 + noout/E-34 場景重現）。
- **timesyncd/mon-clock-skew 推算值**（152.5s/305s 偵測延遲）：timesyncd L3/L4 已有
  committed 結果，未來可回填實測——不在本 SP 範圍。
- **quiz.json**：新文章的測驗題不在本 SP 範圍（素材足夠時另開）。
- **圖表**：新頁優先沿用既有 `/diagrams/ceph/*.png`；需要新圖時以文字表格替代，
  不擋本 SP（靜態 PNG 生成另議）。
