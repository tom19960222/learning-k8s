# Ceph Incident Bundle — Per-node Auto-detect Design

- 日期：2026-06-30
- 對象：`experiments/ceph-incident-bundle/`
- 目標：一份 inventory 即可,逐台 node 自動判斷能力 —— 有 cephadm 就收 ceph 層、有 kubectl 就收 rook 層;kubectl 可指定 context。
- 主要使用情境：rook 接 **external ceph cluster**(k8s node 與 ceph 主機分離),一次收齊兩層。

## 緣起

現狀 `--mode` 把「cluster 層收集」綁死成二選一:cephadm(ssh 到顯式 `seed` 跑 `cephadm shell`)或 rook(在**工作機本機**跑 kubectl)。external-rook 拓樸下,儲存層證據在 external ceph 主機、k8s 層證據在 k8s node,使用者被迫填兩份 inventory、跑兩次。

node 層收集本來就已逐台 ssh 並自動偵測 ceph(`command -v cephadm`、`/var/log/ceph` 等),不需改。要改的是 **cluster 層**:讓它也逐台偵測、兩層都有就都收。

## 決策(使用者已確認)

1. kubectl 在 **inventory 裡有 kubectl 的 node 上**透過 ssh 跑(不是工作機本機)。
2. `auto`(新 default)= 兩層都偵測、都有就都收。
3. `--seed` / `SEED_HOST` 保留為「手動指定 cluster-ceph 來源 node」的覆寫;不填則自動挑。
4. context 用單一全域 `--kube-context`(不做 per-node)。

## 架構(方案 A:能力探測 + 雙層 cluster 收集)

```
1. 探測：對每台 HOST ssh 跑 `command -v cephadm; command -v kubectl`（短 timeout）。
   - ceph_source  = 第一台有 cephadm 的（或 --seed 指定的）
   - rook_source  = 第一台有 kubectl 的
2. cluster-ceph：若有 ceph_source → collect_cluster_cephadm（seed=ceph_source）
3. cluster-rook：若有 rook_source → collect_cluster_rook（透過 ssh 在 rook_source 上跑 kubectl --context）
4. node 層：對每台 HOST 收集（同現狀，未變）
每層只收一次。
```

### mode 行為
- `auto`（default）：步驟 1–4 全跑;兩層各自有來源才收,沒有就 SKIPPED。
- `cephadm`：只跑 cluster-ceph(來源 = `--seed` 或第一台有 cephadm 的)+ node 層。
- `rook`：只跑 cluster-rook(來源 = 第一台有 kubectl 的)+ node 層。

## 介面變更

- 新旗標 `--kube-context <ctx>`:套到所有遠端 kubectl 呼叫(`kubectl --context <ctx> ...`)。預設空(不帶 `--context`)。
- `collect_cluster_rook` 取得新參數,讓 kubectl 透過 ssh 在指定 node 上執行,而非本機。介面:
  - `collect_cluster_rook --out DIR --manifest PATH --namespace NS --since DUR --timeout S [--allow-skip] [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]`
  - 內部用一個 `rook_kubectl()` helper 包住 kubectl:給了 `--ssh-target` 就 `ssh -i KEY <robust opts> TARGET kubectl [--context CTX] "$@"`;沒給就本機 `kubectl [--context CTX] "$@"`(維持舊行為,給測試與「工作機本機就是 k8s client」用)。argv 透過 helper 陣列傳遞,避免字串拼接 quoting。
- `--seed` 語意收斂為「cluster-ceph 來源 node」。
- inventory 不變:一份 `HOSTS`,external ceph 主機與 k8s node 混列。

## 資料流與去重

- cluster-ceph、cluster-rook 各最多收一次(來源 node 為第一台符合者)。
- 多台有 cephadm(如 3 mon)→ 只從第一台收 cluster ceph;每台的 node 層仍各收。
- ceph_source 與 rook_source 可能是不同 node(external 情境)或同一台(converged)。

## 錯誤處理(沿用既有語意)

- 探測某台 ssh 失敗 → 該台不列入來源候選,node 層照常嘗試(失敗則該 node SKIPPED + exit 2)。
- 某 cluster 層有來源但收集失敗 → 該層 artifact 記錄、exit 2、bundle 仍產出。
- `auto` 下完全找不到 ceph 也找不到 kubectl 來源 → 兩層各寫 SKIPPED、exit 2、node 層仍收。
- 遠端 kubectl 的 jsonpath(`-o jsonpath={.items[0].metadata.name}`)透過 ssh 要正確 quote。

## 測試

擴充 fake ssh fixture,使其能依「目標 node」回報能力:
- `command -v cephadm` / `command -v kubectl` 依環境變數(如 `FAKE_CAP_<alias>=ceph|kube|both|none`)回傳對應結果。
- 遠端 `kubectl ...` 在 fake ssh 內模擬(沿用現有 kubectl fixture 邏輯,改成經 ssh 觸發)。

驗證點:
1. 探測挑對 ceph_source / rook_source。
2. external 拓樸(node1=ceph、node2=kube)→ 兩層都收、各一次。
3. `--kube-context ctx` 有出現在遠端 kubectl 指令。
4. 多台有 cephadm → cluster ceph 只收一次。
5. `--mode cephadm` / `--mode rook` 仍只收單層。
6. 都沒能力 → 兩層 SKIPPED、exit 2、node 層仍收。
7. exit code 0/2/1 與既有契約一致。

## 範圍外(YAGNI)

- per-node 不同 kube-context。
- 平行探測 / 平行收集。
- 從多個 k8s context 各收一份 rook。

## 相容性

- 既有 `--mode cephadm --seed ...` 用法不變。
- 既有「工作機本機 kubectl」rook 用法:`collect_cluster_rook` 在 ssh prefix 為空時維持本機行為(測試直接呼叫該函式即走此路)。
