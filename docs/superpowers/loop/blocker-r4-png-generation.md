---
status: needs-user-decision
project_scope: 6 projects × r4 (圖表)
opened_at: 2026-05-08 (loop-1)
---

# Blocker: r4 圖表 PNG 批次生成

## 現況

`next-site/public/diagrams/` 目錄為空。loop-1 rubric 對 6 個 project 的 r4 全部評 3/10，是最大缺口（13 個 < 9 cell 中佔 6 個）。

## 為什麼是 blocker

要把 r4 從 3 推到 9，每個 project 至少需要 3-5 張 PNG（architecture / 關鍵 flow / data structure 之類）。整體 18-30 張 PNG。

生成方式有以下選項，每個都需要使用者拍板：

### 選項 A：用 `skills/fireworks-tech-graph/`（如果是 Fireworks AI 圖像生成）
- 需要 Fireworks API key（環境變數？.env？）
- 每張圖 token / 費用未知
- 風格可控但需要 prompt engineering
- molearn 的 PNG 看起來是用此方法生（`molearn/next-site/public/diagrams/` 有實際 PNG）

### 選項 B：mermaid-cli + 手寫 mermaid
- 免費、本機可跑
- 但 CLAUDE.md 明文規定「不加 Mermaid 圖表；圖表一律靜態 PNG」
- 可作為「先 mermaid render 成 PNG 再丟進 public/」的 build-time 流程
- 風格較工程化，沒有 Fireworks 的視覺表現力

### 選項 C：Excalidraw / draw.io 手工繪製
- 視覺最佳、最可控
- 但 30 張圖手工成本大（每張 30-60 分）
- 最適合架構鳥瞰、時序圖

### 選項 D：放 r4 不動，當 9 分上限是 7
- 接受「ASCII art 已是現實上限」
- 修改 spec §3 r4 評分標準：「該有圖的地方有 PNG **或** 結構良好的 ASCII art」
- 最低成本但等同放棄這條 rubric

## 建議

短期（loop-2）：
- 選 **A 或 B**：每 project 補 1 張 architecture.png 作為「進入頁鳥瞰」(6 張)
- 把 r4 從 3 推到 6-7
- 不追求 9，先看 ROI

長期（後續 loop）：
- 累積補足關鍵時序圖（live migration / pod-to-pod datapath / CRUSH placement）
- 每張圖前面 MDX 加 1 段「等下要看什麼」前導（content-writing-guide.md Rule 5）

## 需要使用者決定的事

1. 採選項 A、B、C、D 哪一個？
2. 若 A：是否要授權 Fireworks API 使用？key 放哪？
3. 若 B：build pipeline 怎麼接？是 commit time 跑還是 CI 跑？
4. 若 C：使用者想自己畫還是要 AI 用文字描述後丟給其他工具？
5. 若 D：是否要修 spec §3 r4 評分標準的 weight？

## 暫定處理（不等使用者）

loop-2 起，把每個低於 9 的 r4 cell **暫時視為 N/A**（只在 SP-8 loop 內部，不改 spec），讓其他 7 個 rubric 的迭代繼續推進。一旦本 blocker 解，r4 重新算。
