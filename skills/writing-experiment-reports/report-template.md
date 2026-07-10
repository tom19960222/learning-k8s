# Report Section Skeleton

Adapt section numbering freely; keep the parts and their order. Language follows the audience (this repo: zh-TW, Taiwan wording, never-translate list applies).

```markdown
# {系統} — {研究主題}總結報告

> 研究代號與一句話脈絡（外部讀者看得懂的說法）｜起訖日期
> N 個實驗（規劃 M 個：X 獨立執行 + Y 併入 + Z 裁定不做）｜原始數據 ledger 位置
> 版本錨點

## 0. 這份報告怎麼讀
- 各節一句話導覽 +「趕時間看 §規劃總覽 + §參數建議總表」
- 領域術語 primer（2~3 行 × 每個讀者可能缺的概念群），放在第一次使用之前
- 負載/指標縮寫約定（含「為什麼看 p99 不看均值」一句）

## 1. 前提
- 系統形狀（受測鏈路、可調參數的層）
- 要回答的問題（通常 2~4 個）
- 判定標準（先於實驗定案的優先序）
- 實驗環境拓樸
- **受測物規格 + 負載矩陣**（SUT spec、pattern 全集 × 時長 × 輪數、指標分母的由來）
- 結論可信度防線（噪音帶、prediction 先行、生效驗證、交錯…）
- 移植性標記說明（機制級 vs 數值級）

## 2. 實驗規劃總覽（規劃 M 個）
### 2.x 每個類別一張表（基建/效能/穩定性/可調性…）
| 編號 | 調整的參數（值域，預設標記） | 為什麼 | 預期 | 結果（✅❌➖ + 一句話） |
### 2.last 裁定不執行的 Z 個
| 編號 | 原計畫 | 不做的理由 |

## 3..K 逐實驗詳情（每類別一章；每實驗固定五欄）
### {編號} {名稱} —— {一句話 verdict}
- **調整的參數**：具體欄位/指令路徑 + 值域（預設標記）；故障類寫「注入什麼」
- **為什麼測**：目的與來源（常識/假說/使用者關切）
- **預期**：實驗前寫死的 prediction
- **結果**：前後值 + 倍率；被推翻處明標；量測陷阱/方法修正照實記
- **建議**：可執行（設什麼值、什麼條件下、去哪拿現成規則/閾值）

## K+1. 參數建議總表（checklist）
| 層 | 參數 | 建議 | 依據（實驗編號） | 效果量 | 可調性（runtime/重啟/重建/建置期） |

## K+2. 完整總結
- 按研究的問題軸收束（每軸一段）
- 一句話版本
- **接下來做什麼（按優先序，每條掛依據實驗）**

## K+3. 侷限與事故記錄
- 數值級 vs 機制級的邊界、環境綁定因素
- 開放問題（含出處指引）
- 研究過程事故的誠實記錄 + 教訓
```

## Review gate prompt sketch

Spawn a fresh subagent:

> 你是技術主管，只能看這份報告（無任何其他背景）：{path}
> 逐項打分（PASS/WEAK/FAIL + 引用位置）：1 前提完整？2 規劃了哪些實驗、為什麼？3 每個實驗調了什麼參數？
> 4 事前預期明確？5 結果有數字、效果多大、有用沒用一目了然？6 參數建議可執行？7 總結完整、知道下一步？
> 另：讀不懂的術語/句子、內部矛盾、數字對不上、過度外推的結論、冗餘與過簡處。
> verdict：ACCEPT / REVISE（必改清單按重要性排序）。不要客套。

Iterate with the SAME reviewer (it keeps context) until ACCEPT. Back-port content errors to sibling artifacts (site pages, ledgers) that repeat the claim.
