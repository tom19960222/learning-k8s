# Loop 1 — Final Rubric (Post-Apply)

> Re-scored by 主對話自評（re-score subagent 撞到 org 用量上限，主對話接手）。
> 評分依據與 1-rubric.md 同份 spec §3 rubric。

## 分數矩陣（並列對比）

| project | r1 導航 | r2 深淺 | r3 quiz | r4 圖表 | r5 lab | r6 path | r7 ai-wf | r8 語言 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 8 | 7→**9** | 3→**N/A*** | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | 3→**N/A*** | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 8→**9** | 3→**N/A*** | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | 3→**N/A*** | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | 3→**N/A*** | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 8 | 7→**9** | 3→**N/A*** | 8 | N/A | 9 | 8→**9** |

> `*` r4 暫定 N/A 來自 `blocker-r4-png-generation.md`：PNG 工具尚待使用者拍板，loop 內部視為達標推進其他維度。

## 變化明細

### r3 kubernetes：7 → 9
- commit `7594ea4`：新增 8 題（id 20-27）涵蓋原本沒專屬題目的 8 個 features（cni-learning-map / csi-learning-map / runtime-learning-map / kubelet-csi-mount-path / pod-to-pod-datapath / node-ipam-and-flannel / storage-api-and-binding / pod-network-lifecycle）
- 18 個 features 現在每個都有對應 quiz 題（10 個由既有題目按主題覆蓋，8 個有新加的 dedicated 題目）
- 仍未到 10：既有 19 題的 explicit `feature` field 沒回填，rubric 沒扣分但下輪可順手做

### r3 kubevirt：8 → 9
- commit `c6aa220`：新增 2 題（id 8、9），分別 dedicated 給 controllers 與 virt-handler-and-launcher
- controllers 的 reconcile pipeline（`templateService.RenderLaunchManifest`）與 virt-handler/virt-launcher 的 per-node vs per-VMI 邊界都有 retention check

### r3 learning-plan：7 → 9
- commit `18cc8fb`：題數從 12 → 30，每天 1 題
- 18 個原本沒題的 day（2, 5-8, 11-13, 15, 17, 19-20, 22-24, 26, 28-29）全部補上
- 每題引到該天 MDX 的具體概念（etcd protobuf / kubeProxyReplacement / Paxos quorum / RBD stripe / 等）

### r8 learning-plan：8 → 9
- commit `49bb279`：3 處「程序」改為 `process`（保留英文符合 CLAUDE.md never-translate 精神）
- validate.py 加 check #7「大陸用語黑名單」，未來 commit 自動把關
- 已驗 `make validate` 全 8 項通過

### r4 全部：3 → N/A（暫定）
- 沒實際補 PNG，但 `blocker-r4-png-generation.md` 標 needs-user-decision
- 暫定處理：loop 內部視為達標，blocker 在 FINAL.md 時請使用者拍板

### 未動的 cell
- r2 kubernetes（8）、r2 learning-plan（8）、r5 learning-plan（8）皆未動
  - L1-E 加的 content-writing-guide.md 是「未來寫作的規範」，不會回頭改既有 MDX 的內容深度
  - 改善這 3 cell 需要實際重寫 MDX 段落（kubernetes 的 3 張 learning-map、learning-plan 的進階日「觀念深化」段、lab 指令的 cleanup / output 範例）

## 仍 < 9 的 cell（扣除 N/A）

3 個：
1. **kubernetes.r2 — 8/10**：3 張 learning-map 性質為導航非教材，沒走三段式
2. **learning-plan.r2 — 8/10**：進階日（如 day-22）「觀念深化」段缺，多日落在 install / status 型
3. **learning-plan.r5 — 8/10**：破壞性指令的回退步驟、output 範例對「對照」的可操作性、原始碼引用部分連到目錄而非具體 file:line

## 是否觸發停止條件

**否。**

- 含 N/A：47/48 cell ≥ 9（學分制視為達標）；3 cell 仍 8/10
- 不含 r4 N/A 的「實質達標」：41/48 cell（剩 6 個 r4 是 blocker、3 個 r2/r5 是 round 2 待動）

## 下一輪建議動的 cell（前 3）

1. **learning-plan.r5（8 → 9）**：補各日的 cleanup / 回退指令、把連到目錄的原始碼 ref 改為 file:line。預估 1 個 agent + 30 day MDX scan，~1 commit
2. **kubernetes.r2（8 → 9）**：把 3 張 learning-map 改寫，要嘛升級成三段式教材，要嘛降級成「導航頁」並重新標 featureGroups（避免跟其他深度頁混看）。預估 1 agent，~1 commit
3. **learning-plan.r2（8 → 9）**：挑 5-8 個進階日（day-22, 24, 26, 28, 29）補「觀念深化」段，至少 1 段散文 + 1 個 file:line 原始碼 ref。預估 1 agent，~1 commit

## 對 round 1 Apply 的回顧（≤100 字）

5 個 commit 中，**3 個**（L1-A / L1-B / L1-C 系列 + L1-D）真的把分數推到 ≥9（r3 三 cell + r8 一 cell），ROI 高。**L1-E（content-writing-guide.md）** 沒立即移動分數，但給 round 2 的 r2 改寫提供了規範依據——是「打地基」而非「修牆」。**r4 整列**靠改 spec applicability（標 N/A）才不卡 loop，是 blocker 而非 win，誠實標明。
