---
name: content-writing-guide
description: learning-k8s 寫 MDX 的具體規範。SKILL.md 講「怎麼分析」，本檔講「怎麼寫得讓初學者讀得進去」。每篇 next-site/content/{project}/features/*.mdx 應通過本檔的檢查表。
---

# Content Writing Guide

> SKILL.md 是分析方法（讀 source、跑 5 個 exploration、產出 facts）；
> 這份是寫作品質規範（讓 facts 變成讀者可吸收的內容）。
>
> 每篇 `next-site/content/{project}/features/*.mdx` 在送 PR 前都應對照本檔最後的「檢查清單」過一遍。

---

## 為什麼需要這份規範

技術正確 ≠ 讀得懂。常見的失敗模式：

- 第一段直接丟出 `apiserver 透過 watch 通道 broadcast event 到 controller-manager 的 informer cache`——讀者連 informer 是什麼都還不知道。
- 連續 7 個 bullet 列 7 個 component，每個 1 行，沒有任何串接散文——讀者讀完只記得最後一個。
- 貼一坨 60 行 Go code，前後沒有任何說明——讀者不知道該看哪一行。

learning-k8s 是個人深度學習網站，不是公開教學站，但**讀者就是未來的你自己**。半年後回來看這頁，能不能 30 秒內想起「這頁在講什麼」、能不能 5 分鐘內定位到關鍵那段 code？這份規範就是為了確保「能」。

---

## 5 條 UX 原則（先有原則再有模板）

### 1. Scene Before Mechanism（場景先於機制）

**每頁都應以「使用者會遇到的具體場景」開場，再帶入機制。**

場景回答：「真正的工程師在什麼情境下會關心這頁？沒有這頁的知識會怎樣？」

反例：

```mdx
## 控制平面架構

Kubernetes control plane 由 kube-apiserver、etcd、kube-scheduler、
kube-controller-manager、cloud-controller-manager 等元件組成。
本文介紹這些元件的功能。
```

正例（取自 `next-site/content/kubernetes/features/architecture.mdx:7-11`）：

```mdx
## 場景

你第一次 ssh 進 control plane node，跑 `ps -ef | grep kube`，
期待看到一堆熟悉的 process。結果只有一個 kubelet 在跑。
kube-apiserver、etcd、kube-scheduler、kube-controller-manager
都不見了——它們竟然是 container。整個 control plane 是 Pod。
```

差別：反例告訴你「是什麼」；正例告訴你「為什麼你會在意」，且埋下後續 static Pod 那段的伏筆。

> 場景不一定是「使用者操作」。也可以是「除錯時你看到的怪現象」、「你以為 X 但其實 Y」、「跨 project 的設計選擇對比」。重點是**讀者能立刻代入**。

---

### 2. No Waterfall Listing（不要瀑布式列舉）

**不要連續用「A 呼叫 B、B 呼叫 C、C 呼叫 D」這種一行一句的條列堆滿一段。**

這種寫法強迫讀者把零散事實塞進工作記憶，讀完一段腦袋是空的。**改用「流程化敘述」**：什麼觸發什麼、什麼 block 什麼、失敗會怎樣。

反例：

```mdx
Migration controller 呼叫 reconcile()。
reconcile() 呼叫 validateVMI() 檢查 VMI 狀態。
validateVMI() 檢查 VMI.status.conditions 是否有 LiveMigratable。
然後呼叫 createTargetPod() 建立 target Pod。
createTargetPod() 呼叫 podClient.Create()。
patchVMIStatus() 更新 migrationState。
```

正例（取自 `next-site/content/kubevirt/features/live-migration.mdx:13-53`）：先用 ASCII flow 圖把「VMIM CRD → controller → target Pod → virt-handler → libvirt」整段串起來，再針對其中 **一個** 步驟貼 code。讀者先有 mental model，code 才有意義。

> 一個簡易判準：如果你的段落第一句是「然後」「接著」「接下來」「最後」這四個之一連續超過 3 個 bullet，就應該改寫成編號流程或圖。

---

### 3. Diagram Before Code（圖在 code 之前）

**有跨元件互動、有時序的概念，先畫圖再貼 code。**

Code 講「實作怎麼寫」，圖講「系統長怎樣」。讀者要先有 mental model 才看得懂 implementation。

順序定錨（每個小節內）：

1. 場景 / 問題（Rule 1）
2. 圖（架構 / 流程 / 時序）
3. 對圖的 1-2 段散文解釋
4. Code（每塊都要有 Rule 5 的鋪陳）
5. 邊界條件 / 注意事項

learning-k8s 的圖檔規範：

- **靜態 PNG**，存 `next-site/public/diagrams/{project}/{name}.png`
- 引用：`![alt text 描述圖在說什麼](/diagrams/{project}/{name}.png)`
- **禁止 Mermaid**（CLAUDE.md 規定）
- ASCII art flow 圖也算「圖」，可接受。實際上現存大多數頁面 (`architecture.mdx:13-37`、`agent-and-datapath.mdx:14-24`、`live-migration.mdx:13-53`) 都用 ASCII art——夠表達就不用畫 PNG。
- **嚴禁 1×1 placeholder PNG**（`make validate` 會擋）

---

### 4. Progressive Disclosure（漸進式揭露）

**按「為什麼存在 → 怎麼用 → 原始碼怎麼實作 → 進階邊界」分四層。每層內部不要跳級。**

讀者分兩種：junior 從上往下讀到夠用就停；senior 直接跳到 code 區塊。**任何一種都不該被迫讀完另一種人需要的內容**才能拿到自己要的。

四層的內容約束：

| 層 | 該寫 | **不該** 寫 |
|---|---|---|
| 1. 為什麼存在 | 場景、痛點、跟相鄰元件的對比 | cgroup namespace 細節、syscall 名 |
| 2. 怎麼用 | YAML 範例、kubectl 指令、概念上的流程 | 內部 struct 名稱、goroutine 模型 |
| 3. 原始碼怎麼實作 | file:line 引用、函式簽章、關鍵 code 片段 | 太細節的 helper（除非是核心邏輯）|
| 4. 進階 / 邊界 | corner case、效能調優、版本差異、跟其他 project 的整合陷阱 | 會 distract 主線的 trivia |

跳級的反例：「為什麼存在」段就出現 `mount propagation = rslave`——讀者第一次看會直接放棄。

---

### 5. Explain Before Quote（先說明再貼）

**任何 code block / YAML / table / 圖之前，至少 1 段話描述「等下要看什麼、為什麼貼這段」。**

不是「以下是 code：」這種空洞句。要具體到讓讀者知道**該注意哪一行**。

反例：

```mdx
reconcile 函式如下：

\`\`\`go
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... 60 行 ...
}
\`\`\`
```

正例（取自 `next-site/content/cilium/features/agent-and-datapath.mdx:30-39`）：

```mdx
`Regenerate()` 是入口。當 endpoint 的 desired state 變動
（label 改、policy 變、新建立）時呼叫：

\`\`\`go
// File: cilium/pkg/endpoint/policy.go (line 759)
func (e *Endpoint) Regenerate(...) <-chan bool {
    // 排隊到 endpoint 自己的 regen queue
    // worker goroutine 真正執行 regenerateBPF
}
\`\`\`
```

讀者看到 code block 時已經知道：(a) 入口函式叫什麼、(b) 什麼時機觸發、(c) 該注意它是 async 排隊。

---

## 三段式模板（每篇 features/*.mdx 的骨架）

learning-k8s 的 feature 頁強制以這個結構開場、收尾。中段隨內容彈性調整。

```mdx
---
layout: doc
title: {Project} — {Feature 名稱}
description: {1-2 句說這頁在講什麼。要具體，避免「介紹 X 元件」這種空話。}
---

## 場景
（Rule 1）
{2-4 句描述：使用者會遇到的具體情境 / 怪現象 / 設計問題。}

{1 段話列出本頁要解開哪些問題（可選；若場景已經帶出問題就省）。}

## {主要機制名稱}
（中段；隨內容寫。可拆 2-5 個小節。每節遵守 Rule 2-5。）

### 第 1 個概念（圖 → 解說 → code）

{1 段散文鋪陳場景中的某個面向。}

```
{ASCII flow 圖 或 PNG ![alt](/diagrams/{project}/x.png)}
```

{1-2 段對圖的解釋——arrow 方向是什麼、numbered step 對應什麼。}

{1 段話交代「以下這塊 code 為什麼貼」。}

```go
// File: {real/path/from/repo}.go (line N)
{actual code, 不超過 20 行}
```

{1-2 句解讀這塊 code 的「非顯然之處」。}

### 第 2 個概念……

（同上）

## 接下來 / 相關頁面

- [{相關 feature 1}](/{project}/features/{slug}) — {1 行說那邊講什麼}
- [{相鄰 project 的相關概念}](/{other-project}/features/{slug}) — {1 行}
```

> 不要 import 任何 component（`<Callout>`、`<QuizQuestion>` 等）。它們是全域註冊，加 import 反而會壞掉。

---

## Glossary 規範（解 pain-points 跨 project 共通主題：「術語首次出現未鋪陳」）

每個 project **第一頁** features（通常是 `architecture.mdx`）的 frontmatter 之後、`## 場景` 之前，應放一個 blockquote 列出**會用到的外部術語**。一句話交代是什麼，不展開。

格式：

```mdx
---
layout: doc
title: ...
description: ...
---

> **會用到的外部術語**
> - **Paxos quorum**：分散式系統「過半節點同意才算數」的共識協定
> - **netlink**：Linux kernel 給 user-space 設定 network 的 syscall family
> - **mount propagation**：bind mount 在 namespace 之間是否傳遞掛載事件
> - **Hive cell DI**：cilium 用的 dependency injection 容器，每個 cell 是一個可注入單元
> - **Paxos / Raft**：兩種主流的分散式共識演算法，etcd 用 Raft
> - **PodResources gRPC**：kubelet 暴露給 device-plugin 查詢 Pod 與 device 對應關係的 gRPC service

## 場景
...
```

判準：**這個術語在本 project source code 之外（kernel、外部 library、學術名詞）也存在，且讀者不一定學過**——就列進來。

learning-k8s 自己的概念（k8s 的 Pod、cilium 的 endpoint、ceph 的 OSD）**不**列進 glossary，那些在內文第一次出現時用半句話帶過即可。

---

## 連結規範

learning-k8s 是純靜態網站（`output: 'export'`），所有連結都應該離線可用。

| 場景 | 寫法 |
|---|---|
| 同 project 內的 forward link | `[kubelet](/kubernetes/features/kubelet)`（絕對路徑） |
| 跨 project 引用概念 | `[cilium 的 endpoint regeneration](/cilium/features/agent-and-datapath)` |
| 引原始碼某個檔案 | 用 `File: project-name/pkg/foo/bar.go (line N)` 註解，**不**外連 GitHub |
| 引外部規範 / RFC | 可外連，但僅在 Glossary 或「接下來」段 |

**禁止**外連 GitHub blob URL 當作主要 reference。原因：(a) 學習者可能離線、(b) submodule 已經 pin 在特定版本，外連到 master 會錯版。改用相對路徑 + line number。

範例（取自 `next-site/content/kubernetes/features/architecture.mdx:100-106`）有外連 GitHub 是因為它在「進入點對照表」末段，當作 v1.36.0 specific 的版本參考——這種**輔助性**外連可以接受，但**不是**正文的主要 reference。

---

## QuizQuestion 規範

- 每個 features/*.mdx **至少 1 道 quiz**，放在 `next-site/content/{project}/quiz.json`，**不要** inline 進 MDX
- distractor（錯誤選項）要是「真的可能誤解」的內容，不是隨手寫的廢話
  - 反例：`A. 對 / B. 錯 / C. 我不知道 / D. 以上皆非`
  - 正例：4 個選項都是「乍看合理但其中只有 1 個 source code 真的這樣寫」
- `id` 是整數、`answer` 是 0-indexed
- 每題附 `explanation` 解釋「為什麼這個對、其他為什麼錯」

格式（與 `make validate` 對齊）：

```json
[
  {
    "id": 1,
    "question": "kube-apiserver 啟動時，誰是第一個 client？",
    "options": [
      "kube-controller-manager",
      "kubelet（以 static Pod 模式啟動 apiserver 自己）",
      "etcd（apiserver 主動連 etcd）",
      "kubectl"
    ],
    "answer": 2,
    "explanation": "apiserver 啟動時做的第一件事是連 etcd 拉狀態。它自己是被 kubelet 以 static Pod 啟動，但那是『誰起 apiserver』，不是 apiserver 的『第一個 client』。"
  }
]
```

---

## 圖表規範

| 規則 | 細節 |
|---|---|
| 格式 | **PNG**（禁 Mermaid、禁 SVG、禁 GIF） |
| 路徑 | `next-site/public/diagrams/{project}/{name}.png` |
| 引用前 | 1 段話描述「等下要看什麼」（Rule 5） |
| alt text | 必須有，且能描述圖的內容（不是「圖一」這種廢話） |
| 1×1 placeholder | **嚴禁**（`make validate` 會擋下） |
| ASCII art | 接受。簡單的 flow / box diagram 用 ASCII 即可。複雜時序圖才畫 PNG |

命名慣例：

- `architecture.png`：整體系統架構
- `state-machine.png`：CRD 的 phase / state 轉換
- `{feature}-flow.png`：某個 feature 的流程
- `{feature}-sequence.png`：multi-actor 時序

---

## 常見反模式

### Anti-pattern 1：Definition Dump

```mdx
## 基本概念

**Endpoint**: cilium 的 endpoint 是...
**Identity**: cilium 的 identity 是...
**Policy**: cilium 的 policy 是...
```

修正：開頭用一個場景（「Pod 落地半秒就能通訊，中間發生了什麼？」），讓 endpoint / identity / policy 在故事流程裡**該出現的時候才出現**，不要批次 dump。

### Anti-pattern 2：Wall of Code

一個小節 80% 是 code block，每塊 30+ 行，前後幾乎沒有解釋。

修正：套 Rule 5，每塊 code 之前 1 段、之後 1-2 句解讀。code 不要超過 20 行（超過就應該分塊或省略）。

### Anti-pattern 3：Missing Cross-References

頁面寫完沒有「接下來」段，讀者不知道下一步該看哪頁。

修正：每篇 MDX 最後都應該有 2-4 個相關連結。同 project 為主，跨 project 為輔。

### Anti-pattern 4：Translating the Untranslatable

把 `Pod`、`namespace`、`reconcile` 等名詞翻成中文。

修正：對照 CLAUDE.md 的 never-translate 清單。技術名詞保留英文原文。

### Anti-pattern 5：Code Without `File:` Comment

```go
func reconcile() { ... }
```

讀者不知道這 code 是哪裡來的，無法去 source 對照。

修正：每塊 code block 第一行加 `// File: project/pkg/foo/bar.go (line N)`。沒有 `File:` 註解的 code block 在 review 時應退稿。

### Anti-pattern 6：Untyped Quotes

引用上游文件 / spec / RFC 的內容，但沒標出處。

修正：引用 spec / kep / blog 等外部來源時，至少加一行「`-- source: KEP-1234`」。

---

## 語言規範速查（補 CLAUDE.md）

| 場景 | 用法 |
|---|---|
| 動詞連接 K8s 名詞 | 「watch Service」「list Pod」「reconcile VirtualMachine」——**動詞用英文也可以** |
| 「使用者透過 X 來 Y」 | 「使用者用 `kubectl apply` 建 Deployment」——比「使用者通過 kubectl apply 來建立 Deployment」自然 |
| 否定式 | 「不會」「不能」「不該」——避免「不可以」「不可能」這類書面腔 |
| 比較句 | 「A 比 B 快」「A 跟 B 不同」——避免「相比於」「與……相比」 |
| 條件式 | 「如果 X，那 Y」 / 「X 的時候 Y」——避免「在 X 的情況下」 |

never-translate 清單（從 CLAUDE.md 摘）：`node`, `cluster`, `controller`, `namespace`, `container`, `image`, `workload`, `bare-metal`, `gateway`, `scheduling`, `rolling update`, `label`, `Pod`, `Deployment`, `Service`, `ConfigMap`, `Secret`, `PV`, `PVC`, `StorageClass`, `CRD`, `webhook`, `reconcile`, `operator`, `daemon`, `sidecar`, `taint`, `toleration`, `affinity`。

學習過程也禁用大陸 / 港式用語：軟體（非软件 / 软体）、網路（非网络）、檔案（非文件）、程式（非程序）、預設（非默认）、資料（非数据）、使用者（非用户）、影片（非视频）、解析度（非分辨率）、滑鼠（非鼠标）。

---

## 送 PR 前的檢查清單

打勾後再 commit：

### 結構
- [ ] 三段式齊全（`## 場景` → 中段機制 → `## 接下來`）？
- [ ] 第一頁 features（架構頁）有 Glossary blockquote？
- [ ] frontmatter 有 `layout: doc` + `title:` + `description:`？

### 內容
- [ ] 每個 code block 前都有 1 段話鋪陳（Rule 5）？
- [ ] 每個 code block 第一行有 `// File: ...` 註解？
- [ ] 沒有連續超過 5 個 bullet 的瀑布式列舉？
- [ ] 沒有跳級（「為什麼存在」段沒出現過深的細節）？
- [ ] 圖在 code 之前？

### 視覺
- [ ] 圖是 PNG（或 ASCII art），**不是** Mermaid？
- [ ] PNG 不是 1×1 placeholder？
- [ ] PNG 引用前有 1 段話描述「等下要看什麼」？
- [ ] PNG 有 alt text？

### 測驗
- [ ] `quiz.json` 有對應這頁的題目（至少 1 題）？
- [ ] `id` 是整數、`answer` 是 0-indexed？
- [ ] 每題有 `explanation`？
- [ ] distractor 是「真的可能誤解」的選項？

### 連結
- [ ] 「接下來」段有 2-4 個相關連結？
- [ ] 沒有把主要 reference 設成外連 GitHub？
- [ ] 跨 project 引用用 `/{project}/features/{slug}` 絕對路徑？

### 語言
- [ ] 全篇台灣繁中？
- [ ] never-translate 詞保留英文原文？
- [ ] 沒有大陸 / 港式用語？

### 自動驗證
- [ ] `make validate` exit 0？

---

## 回頭讀自己的文章

寫完隔 1 天回來讀一次。問自己 3 個問題：

1. **半年後的我** ssh 進 cluster 除錯時，能不能用這頁的內容快速定位問題？
2. **沒讀過 source** 的工程師，看完這頁能不能講出大致流程？
3. **讀過 source** 的工程師，看完這頁有沒有「喔，這個設計原來是為了 X」這種收穫？

3 題只要有 1 題答不出來，這頁就還沒寫完。
