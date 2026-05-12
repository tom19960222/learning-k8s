# SP-9: Feature-map JSON 補齊 plan

> spec: `docs/superpowers/specs/2026-05-13-sp9-feature-maps-design.md`

## 工作項目

任務之間沒有依賴，可並行寫；驗證統一在最後跑 `make validate`。

### Step 1 — 寫 6 份 feature-map.json

每個寫到 `next-site/content/{project}/feature-map.json`：

| # | 檔案 | 節點數 | 邊數 |
|---|---|---|---|
| 1 | `content/kubernetes/feature-map.json` | 8 | 10 |
| 2 | `content/cilium/feature-map.json` | 4 | 4 |
| 3 | `content/kubevirt/feature-map.json` | 6 | 8 |
| 4 | `content/ceph/feature-map.json` | 4 | 5 |
| 5 | `content/multus/feature-map.json` | 4 | 4 |
| 6 | `content/learning-plan/feature-map.json` | 5 | 4 |

內容完全按 spec 表格產出，欄位順序：projectId → nodes → edges。

### Step 2 — featureSlug 對映確認

寫完之前用 `ls next-site/content/{project}/features/` 對所有 featureSlug 確認檔案存在。學習-plan 的 `day-30.mdx` 用過 `ls` 確認存在。

### Step 3 — `make validate`

要點：
- `scripts/validate.py` 目前不一定檢查 `feature-map.json`，但 next.js build 階段會走 `loadFeatureMap()` 並 render 6 個頁面；JSON syntax error 或 featureSlug 對不到的話 build 不會錯但點擊會 404。所以 featureSlug 對應的人工檢查是關鍵。
- 期望 `make validate` exit 0。

### Step 4 — 手動 sanity check（不啟動 dev server）

`next-site/.next/server/app/{project}/feature-map.html` 在 build 後存在表示頁面 render 成功；只要 `loadFeatureMap` 回 non-null，placeholder 「功能地圖尚未建立」就會消失。

### Step 5 — Commit

訊息：`feat(sp-9): add feature-map.json for all 6 projects`

## Risk

- `category` 值打錯 → FeatureMapGraph fallback 用灰色 border，視覺降級但不會 crash。
- node id 跟其他 id 衝到 → React Flow 會警告但仍 render；用 spec 表格中設定的 id (kebab-case，等於 featureSlug 或語意化縮寫) 來避免。
- learning-plan 的「week」是聚合，可能跟未來補 day-by-day node 衝突；目前接受此差異，反正是個人學習網站。
