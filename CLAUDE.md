# CLAUDE.md — learning-k8s

> 給未來 AI session 的指引。讀完這份再動手。

## 專案性質

個人 Kubernetes 生態系深度學習網站。從原始碼出發分析 5 個專案，並附 30 天 hands-on lab。內容是給作者自己看的，不是公開教學站。

**已涵蓋（或計畫涵蓋）的專案：**

| 專案 | 版本 | 子計畫 |
|------|------|------|
| kubernetes | v1.36.0 | SP-3 |
| cilium | v1.19.3 | SP-4 |
| kubevirt | v1.8.2 | SP-5 |
| ceph | v19.2.3 (Squid LTS) | SP-6 |
| multus-cni | v4.2.4 | SP-7 |
| learning-plan | — | SP-2（30 天動手實驗，掛在 PROJECTS 裡走既有 `[project]` 路由） |

子計畫的 spec / plan 都在 `docs/superpowers/{specs,plans}/`。

## 內容語言（強制）

- 所有 zh 內容**必須是繁體中文，且使用台灣用語**
- 大陸 / 港式用語禁止：軟體（非软件/软体）、網路（非网络）、檔案（非文件）、程式（非程序）、預設（非默认）、資料（非数据）、使用者（非用户）、影片（非视频）、解析度（非分辨率）、滑鼠（非鼠标）
- 程式碼註解仍維持英文（與 upstream 慣例一致）

### 技術名詞保留英文（never-translate 清單）

下列詞彙**永遠**用英文原文，不要中譯：

`node`, `cluster`, `controller`, `namespace`, `container`, `image`, `workload`, `bare-metal`, `gateway`, `scheduling`, `rolling update`, `label`, `Pod`, `Deployment`, `Service`, `ConfigMap`, `Secret`, `PV`, `PVC`, `StorageClass`, `CRD`, `webhook`, `reconcile`, `operator`, `daemon`, `sidecar`, `taint`, `toleration`, `affinity`

## 強制流程

### 每次 commit 前

```bash
make validate
```

必須 exit 0 才能 commit。`validate.py` 會檢查：
- MDX frontmatter（`layout: doc` + `title:`）
- 圖片引用都存在且非 1×1 placeholder
- QuizQuestion 語法（quotes、answer 格式）
- quiz.json 格式（id 整數、answer 0-indexed）
- `projects.ts` 裡所有 slug 都有對應 MDX 檔
- Next.js build 必須 exit 0

### 加新專案的 5 步驟

詳見 `BOOTSTRAP.md`。摘要：

1. `git submodule add` 子專案到 root
2. 在 `next-site/lib/projects.ts` 的 `PROJECTS` 物件新增條目
3. `mkdir -p next-site/content/{project}/features` 與 `echo '[]' > next-site/content/{project}/quiz.json`
4. 寫 MDX（須通過 zero-fabrication 規則 — 見 `skills/analyzing-source-code/SKILL.md`）
5. `make validate`

### 分析新專案的方法論

完全沿用 `skills/analyzing-source-code/SKILL.md` 的 6 個 Phase（Setup → Explore × 5 → Plan → Write → Story → Integrate → Verify）。

## Lab 指令的驗證等級

30 天 lab 的指令必須先驗證才能寫進文件，但**驗證的等級依環境決定**：

- 可在 kind / minikube 跑的指令 → 必須在我本機跑過確認回傳值
- 需要真實 Proxmox + 3-node k8s + ceph cluster 的指令 → 以原始碼層級 + 官方文件交叉驗證；MDX 內以「在你環境跑後對照」標註
- 涉及破壞性操作（drain、reboot、ceph pool delete）→ 必須附明確警告與回退步驟

## 不要做的事

- 翻譯 never-translate 清單裡的詞
- 用大陸用語（程序 / 默认 / 视频 / 网络 / 文件…）
- 在 MDX 中 import `<Callout>` / `<QuizQuestion>` 等元件（它們是全域註冊的，加 import 反而會壞）
- 直接在 MDX 中寫測驗題；測驗一律放 `quiz.json`
- 加 Mermaid 圖表；圖表一律靜態 PNG，存 `next-site/public/diagrams/{project}/`
- 在 MDX 寫不存在的函式 / 型別名稱（zero-fabrication，違反就退稿）

## 技術 stack 對照

| Layer | Tech | 備註 |
|---|---|---|
| Framework | Next.js 14.2.5 App Router | `output: 'export'`，可純靜態部署 |
| MDX | next-mdx-remote 5 | frontmatter 用 gray-matter |
| Validation | Python 3 + `scripts/validate.py` | 跑 `make validate` 觸發 |

## 工作流程：brainstorm → spec → plan → implement

每個子計畫（SP-N）都走這個循環：

1. `superpowers:brainstorming` → spec 落到 `docs/superpowers/specs/`
2. `superpowers:writing-plans` → plan 落到 `docs/superpowers/plans/`
3. `superpowers:subagent-driven-development` 或 `superpowers:executing-plans` → 實作

不要省略任何階段。
