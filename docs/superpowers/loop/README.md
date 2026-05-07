# SP-8 Loop 工作目錄

每輪 loop 的中介產出物。命名規則：`{N}-{stage}.md`，N 從 1 開始遞增。

## 檔案類型

| 檔案 | 由誰寫 | 內容 |
|---|---|---|
| `{N}-pain-points.md` | Agent A (Beginner Read) | 6 project 的卡住點清單，每點 ≤2 行 |
| `{N}-molearn-references.md` | Agent B (Molearn Compare) | 對應 pain-points 的 molearn 參考位置 |
| `{N}-rubric.md` | Agent C (Rubric Scorer) | 6×8 分數矩陣 + 每個 < 9 的理由 |
| `{N}-final-rubric.md` | Agent C (Re-score) | Apply 後重評矩陣，停止判斷依據 |
| `{N}-summary.md` | 主對話 | ≤200 字摘要：本輪改了什麼、下一輪打算動什麼 |
| `blocker-{項目}.md` | 任何 agent | 卡住、需使用者拍板的項目 |

## Rubric 編號（見 spec §3）

1. 導航 / 結構  2. 內容深淺  3. Quiz 連動  4. 圖表
5. 動手體驗     6. learningPaths  7. AI workflow  8. 語言一致性

## Project 列表

`kubernetes` / `cilium` / `kubevirt` / `ceph` / `multus-cni` / `learning-plan`

## molearn 對照地圖

molearn 含的子專案與 learning-k8s 對應：

| learning-k8s | molearn 對照 |
|---|---|
| `kubernetes` | （無直接對照；可看 molearn 整體框架做法）|
| `cilium` | `kube-ovn`（同為 CNI 但不同實作）|
| `kubevirt` | `kubevirt`（**直接對照**）|
| `ceph` | `rook`（ceph operator，間接對照）|
| `multus-cni` | （無直接對照；可看 molearn 怎麼處理 CNI 多平面）|
| `learning-plan` | （無直接對照；molearn 沒有 lab plan）|

molearn 同樣有 `cluster-api`、`cluster-api-provider-maas`、`cluster-api-provider-metal3`（CAPI 生態），learning-k8s 沒有對應。

## 停止條件

6 project × 8 rubric = 48 分數（扣除 N/A），全部 ≥ 9 即停。
