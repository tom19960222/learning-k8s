# Ceph 內容稽核證據（2026-07-10）

本目錄是 Ceph 內容重構 SP（spec：`docs/superpowers/specs/2026-07-10-ceph-content-restructure-design.md`）
動工前的逐條查證產物。由 workflow `wf_0d2aa12c-e42` 的 11 個平行 agent 產出，
對象是 Codex 初步盤點的技術指控與 24 篇既有文章。查證基準：ceph v19.2.3
（submodule commit `c92aebb`）、ceph-csi v3.14.0（`0d0e1f8`）、worktree base `e9e0399`。

> 引用注意：這些 JSON 內的 file:line 與逐字引句是「稽核當下」的紀錄。
> 寫新文章時仍須對 pinned source 重新開檔驗過（zero-fabrication），不可未驗照抄。

| 檔案 | 內容 |
|---|---|
| `claim_clock-skew-source.json` | 指控 1（>5s skew→election churn 因果鏈）與指控 2（cephx 方向 B rotate 條件）——皆 confirmed（文章錯），附 Paxos.cc / Auth.h / CephxKeyServer.cc 逐字反證 |
| `claim_recovery-throttle-injectargs.json` | injectargs 被 mClock rollback 的宣稱——confirmed（文章錯）：injectargs 寫 CONF_OVERRIDE，rollback 只動 mon config DB |
| `claim_rbd-csi-datapath.json` | krbd/librbd 混淆與 volumeMode 描述——confirmed（含細節打折說明），附 ceph-csi v3.14.0 錨點 |
| `findings_alertseries.json` | alert 四頁時間拼貼 12 條 finding（含 git 時序、內嵌 YAML 缺 OSD_FLAGS、routing 缺 ceph_external 等） |
| `findings_slowops.json` | 舊 slow-ops 頁 vs 2026-07-09 研究逐條對照（推翻/保留/新發現三類） |
| `findings_incident.json` | incident-bundle 文章 vs 工具現況：8 項未涵蓋能力（附 file:line）+ 5 處與現行為不符 + (a)-(n) v3 能力清單 |
| `datapoints.json` | 6 個實驗數據點查證——全部 confirmed，附 git 內出處 |
| `navigation.json` | learningPaths 10/24 覆蓋、feature-map 16-node SCC 與 32 條 cycle、5 篇 prerequisite 宣告盤點 |
| `articles_architecture.json` | 24 篇逐篇體檢（前 12 篇：doc_type / 自足性 / 時效風險 / 必保留內容 / 實際前置） |
| `articles_clock-skew-magnitude-ladder.json` | 24 篇逐篇體檢（後 12 篇） |
| `experiments.json` | 8 個 experiments/ 目錄的證據狀態（committed / article-ready / local-only 斷鏈） |
