# Ceph Incident Bundle — Production Hardening Design

- 日期：2026-06-30
- 對象：`experiments/ceph-incident-bundle/`（事故現場 read-only 收集工具，約 2400 行 bash）
- 目標：把這套已可用的工具硬化到「可在多個 production cluster 安心執行」的程度
- 執行模型：subagent-driven-development，三視角 review（Code Reviewer agent + SRE agent + codex 跨模型）

## 緣起

`ceph-incident-bundle` 是事故發生時「先保留現場」的工具：從一台工作機 SSH 到所有 Ceph node，收集系統狀態、Ceph 狀態、log 清單與必要 log，打包成 `.tar.gz`，全程 read-only、不改 cluster 狀態。

現狀健康：`tests/run-tests.sh` 全綠、`shellcheck` 0 error（13 warning + 4 note）、2026-06-29 在 lab（cephadm、6 host）smoke test exit 0 / VERIFY PASS。

但「lab 上跑得過」不等於「production 上跑得對」。使用者會把它帶到其他 production cluster，所以要把潛在的生產失敗模式找出來修掉。這是**硬化**，不是搶救，也不是加功能。

## 範圍

### In-scope（硬化）
- edge case 與 error handling
- exit code 語意一致性（0 / 2 / 1）
- SSH / timeout / 部分失敗（partial failure）處理
- redaction 漏洞與跨平台行為（工作機是 darwin）
- portability：非 lab 叢集、不同 distro、非 cephadm 環境
- `shellcheck` 清零（13 warning → 0）
- 對每個修好的問題補回歸測試
- README 與實際行為對齊（安全界線、exit code、已知非零）

### Out-of-scope（除非 review 證明是正確性問題）
- 新增收集項目（更多 artifact）
- 平行化 node 收集
- 架構重寫

## 執行架構（方案 A）

```
Phase 1  review（平行、三獨立視角）
  ├─ Code Reviewer agent  → 正確性 / 可維護性 / bash 安全
  ├─ SRE agent            → 生產可用性 / 失敗模式 / timeout / 部分失敗
  └─ codex exec（背景）   → 跨模型第三視角，省 Claude rate limit
Phase 2  triage（orchestrator）
  去重 → 嚴重度排序 → 對照 in-scope → 丟掉 out-of-scope
Phase 3  fix（subagent-driven-development）
  每個獨立 finding 一個 task：先補會紅的測試 → 修 → 綠；機械性修正交給 codex
Phase 4  validate（SRE agent 在 lab 真叢集）
  多故障矩陣，每項故障注入皆可回退
```

## 成功條件

1. `tests/run-tests.sh` 全綠，且每個被修的 finding 都有對應回歸測試。
2. `shellcheck lib/*.sh run/*.sh tests/*.sh` 0 warning。
3. 真叢集多故障矩陣全部產出可驗證 bundle，exit code 符合語意。
4. README 的「安全界線 / exit code / 已知非零」與實際行為一致。
5. `make validate` exit 0（不破壞站台 build）。

## Lab 多故障驗證矩陣

叢集：3 mon + 9 OSD、replicated pool、現為 HEALTH_OK。所有故障注入前先 `ceph osd ok-to-stop` / 確認 quorum，注入後立即回退。

| 情境 | 注入 | 預期收集結果 | 預期 exit | 回退 |
|---|---|---|---|---|
| 健康基準 | 無 | VERIFY PASS、各 node 收齊 | 0 | — |
| OSD down | 確認 ok-to-stop 後停 1 顆 OSD | health detail/PG_DEGRADED 入 bundle | 0 | `ceph orch daemon restart osd.<id>` |
| MON 少一台 | 停 1 台 mon（quorum 仍在） | MON_DOWN 入 bundle | 0 | 重啟該 mon |
| node SSH 不可達 | inventory 含一台不可達 host | 該 node SKIPPED、其餘照收、errors.log 有記 | 2 | — |
| seed 掛掉 | `--seed` 指不可達 host | cluster collector 失敗、node 仍收 | 2 | — |

> 破壞性操作（停 OSD / 停 mon）一律：先確認安全 → 注入 → 收集 → **立即回退** → 確認 HEALTH_OK 後才進下一個情境。

## 已知候選 finding（review 起點，非完整清單）

1. **[高] node 收集被 per-command timeout 整包卡死**：`collect_remote_node` 把整個遠端 node 收集包在 `timeout "$timeout"`（預設 20s）中（`run/collect.sh:166-169`），但遠端要跑 `iostat 1 3`+`journalctl`+`dmesg`+log 複製，production node 容易 >20s → 整包 SIGTERM 截斷。per-command 與 per-node 總 timeout 被混用為同一值，應分離（node 總 timeout 例如 300s）。
2. **[中] 大 log 靜默丟棄**：`copy_ceph_logs` 對 >1MB 檔案直接 `continue` 跳過（`lib/collect-node.sh:169`），出事時最該收的當前大 log 正好被丟，且 manifest/errors 無記錄。應改為「截尾收 tail + 在 manifest 記錄被截斷」。
3. **[中] 無 trap cleanup**：collect.sh `set -e` 中途死或 Ctrl-C 會留下 `tmp.*.$$` workdir 與 `.node-*.tar.gz`。應加 trap 清理。
4. **[低] redaction 跨平台**：`redact_file` 用 `chmod --reference`（GNU only），darwin 工作機上失敗（已 `|| true` 吞掉，temp 檔權限未對齊）。
5. **[低] heavy cluster command timeout 過緊**：`pg dump` / `osd dump` 在大叢集可能撞 20s，需分級 timeout。

## 風險與決策

- **故障注入在真叢集**：replicated pool + 先 ok-to-stop 確認，單 OSD / 單 mon 失效可回復；每步附回退並驗證恢復。
- **timeout 分級**會改變預設行為（node 總 timeout 變長）：屬正確性修正，視為 in-scope。
- **大 log 改截尾**會改變 bundle 內容語意（不再「整檔或不收」）：用 manifest 標註截斷，README 同步。
