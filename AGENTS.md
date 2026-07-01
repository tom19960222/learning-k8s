# learning-k8s — AI 指引（CLAUDE.md = AGENTS.md）

> 給未來 AI session 的指引。讀完這份再動手。
>
> 此檔為單一來源；`CLAUDE.md` 是指向本檔的 symlink。要改規則改這份就好，兩邊同步。

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

### Commit & push 方式（本機環境特例）

這台機器的 ssh-agent 連線會失敗（agent 內那把標 `Windows` 的 key 取不到），而 `~/.ssh/id_ed25519` 沒有註冊到 GitHub。能用的 key 是 **repo 內的 `.ssh/id_ed25519`**（已被 `.gitignore` 擋掉，不會被 commit）。gpg signing 也走同一個壞掉的 agent，所以一併關掉。

```bash
# 1. commit：關閉 gpg signing
git commit --no-gpg-sign -m "..."

# 2. push：指定 repo 內的 key、繞過壞掉的 agent
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push
```

`origin` 是 SSH remote（`git@github.com:tom19960222/learning-k8s.git`）。push 前一樣要先 `make validate` exit 0。

### 加新專案的 5 步驟

詳見 `BOOTSTRAP.md`。摘要：

1. `git submodule add` 子專案到 root
2. 在 `next-site/lib/projects.ts` 的 `PROJECTS` 物件新增條目
3. `mkdir -p next-site/content/{project}/features` 與 `echo '[]' > next-site/content/{project}/quiz.json`
4. 寫 MDX（須通過 zero-fabrication 規則 — 見 `skills/analyzing-source-code/SKILL.md`）
5. `make validate`

### 分析新專案的方法論

完全沿用 `skills/analyzing-source-code/SKILL.md` 的 6 個 Phase（Setup → Explore × 5 → Plan → Write → Story → Integrate → Verify）。

### 分析單一新專題頁的方法論

當需求是「深入研究某個既有 project 的 topic，並新增一個 feature page」時，優先使用 `skills/source-first-topic-page/SKILL.md`。這個 skill 會把 `$using-superpowers`、source-first evidence ledger、MDX 寫作規範、`projects.ts` / `feature-map.json` / `quiz.json` 整合檢查串成一個較小流程。

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

## 本機工作機（macOS bastion）限制與踩雷

- **bash 3.2**：沒有 `mapfile`/nameref。`set -u` 下展開空陣列會直接報 unbound，一定要先 `[[ ${#arr[@]} -gt 0 ]]` 或用 `"${arr[@]+"${arr[@]}"}"` 保護；把命令輸出填進陣列用 `while IFS= read -r x; do a+=("$x"); done < <(cmd)`。
- **沒有 `timeout` / `gtimeout`**：寫需要逾時的 shell 工具要偵測並 fallback（有就用、沒有就印警告，而非靜默無界）。
- **沒有 `gh`**：開／更新 PR 用 `git push` 印出的 `pull/new/<branch>` URL 走 web；別呼叫 `gh`。
- **bsdtar 會塞 `com.apple.provenance` xattr**：送檔給遠端 GNU tar 會噴 `Ignoring unknown extended header`；打包／傳輸時對 bsdtar 加 `--no-xattrs`。
- **這個 harness 擋 `set -m`／job-control，背景程序收不到可靠的 SIGINT**：訊號／Ctrl+C 相關行為別靠真訊號測，改測 handler 的單元邏輯（直接呼叫 handler、驗退出碼與副作用）。
- **ssh/scp 的選項別用「一整串變數」**：`X="-i k -o ..."` 展開常爆；flag 一律逐個寫死。

## Ceph 驗證叢集（子專案需要真機驗證時）

- **cephadm v19.2.3**：3 mon(`.166`/`.167`/`.164`)+ 9 OSD(`.169`/`.171`/`.174`，每台 3)。seed/admin = `.166`（`/etc/ceph` 有 admin keyring，且已裝 `ceph-common` → 可直連 `sudo ceph`）。
- **single-node k8s(k0s)+ Rook external** = `.160`：operator 在 namespace `rook-ceph`、external CephCluster 在 `rook-ceph-external`（kubeconfig API 是 `localhost:6443`，kubectl 只能在 `.160` 本機用）。
- ssh：key = repo 內 `.ssh/id_ed25519`；`ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none ikaros@192.168.18.x`；叢集指令 `sudo cephadm shell -- ceph ...`。
- **破壞性操作**（停 OSD/mon）：先 `ceph osd ok-to-stop` / 確認 quorum → 注入 → 收集 → **立即回退** → 確認 `HEALTH_OK` 才進下一步。

## experiments/ 下的 shell 工具開發約定

- **TDD**：每個修正先寫會紅的測試 → 修 → 綠。測試用 `tests/` 內的 fake `ssh`/`kubectl`（PATH 覆蓋）+ 環境變數注入故障 + 對產出的 bundle/檔案斷言；`bash tests/run-tests.sh` 是總 gate。
- **`shellcheck lib/*.sh run/*.sh tests/*.sh` 必須 0**（含 info 級）；確定是誤報再用「有註解說明理由」的 `# shellcheck disable=SCxxxx`（例：markdown 反引號誤判 SC2016、`sudo cat >file` 的 SC2024、單引號遠端腳本的 SC2016）。
- read-only、bash 3.2 相容、**stdout 只放機器要抓的那行**（其餘 log/progress 一律走 stderr）。
- DRY：重複邏輯（ssh 選項向量、skip-artifact writer…）收斂成 `lib/common.sh` 單一 helper；入口 script 保持精簡 orchestrator，純 helper 抽到 `lib/`。
- 每次改動後跑 **`run-tests.sh` + `shellcheck` + `make validate`** 三個全綠才 commit／push。

## 多視角 review 迴圈

- 需要嚴謹把關時：平行跑 **Code Reviewer agent**（正確性/DRY/SOLID）、**SRE agent**（生產可用性/失敗模式），必要時加 **codex 跨模型**；整併去重 → triage（標 in-scope/out-of-scope）→ 修（TDD）→ 再 review，iterate 到 reviewer 明確 satisfied。
- **codex 省 rate limit**：`codex exec --skip-git-repo-check --sandbox read-only "<prompt>" < /dev/null`（macOS 沒 timeout；可背景跑）。verdict 在輸出**最後一個 `codex` 區塊**。codex 的 read-only sandbox **跑不了 `mktemp`/測試** → 測試 gate 自己在本機跑，別信它「測過了」。
- 破壞性驗證（改真叢集）自己直接控、每步可回退，別丟給無法中斷的背景 subagent。
