# Ceph Incident Bundle — Prefer direct `ceph` over `cephadm shell`

- 日期：2026-06-30
- 對象：`experiments/ceph-incident-bundle/`
- 目標：cluster-ceph 收集時,若 `ceph` 指令**能連上 cluster** 就優先直接用 `ceph`(快,免每條 container 啟動);否則退回 `cephadm shell -- ceph`。「可用」= **連得上**,不是 binary 存在。

## 緣起

現狀每條 cluster ceph 指令都跑 `ssh <seed> sudo -n cephadm shell -- ceph …`,每條起一個 container(~24 條,~2 分鐘)。在有 ceph CLID + admin keyring 的 host(traditional / external 叢集)上,直接 `ceph …` 快得多。lab(cephadm host)上 host 沒有 ceph CLI,必須退回 cephadm shell。

## 決策（使用者已確認：方案 A）

- 用**連線測試**挑 runner,而非 `command -v`。
- ceph-only 的 node(沒有 cephadm)也能當 ceph 來源。

## Runner 抽象

一個 "ceph runner" = 在來源 node 上實際跑 ceph 指令的前綴。依序探測,第一個**連得上**的勝出:

| token | 前綴 | 連線探測 |
|---|---|---|
| `direct` | `ceph` | `ssh <t> ceph --connect-timeout 5 -s` |
| `sudo` | `sudo -n ceph` | `ssh <t> sudo -n ceph --connect-timeout 5 -s` |
| `cephadm` | `sudo -n cephadm shell -- ceph` | `ssh <t> sudo -n cephadm shell -- ceph --connect-timeout 5 -s` |

探測 exit 0 = 連得上(`--connect-timeout 5` 界定 ceph 連 mon 的等待;ssh 另有 ConnectTimeout / timeout_cmd 外層)。binary 不存在 → ssh 回 127 → 該 token 失敗 → 試下一個。函式 `ceph_runner_for <target> <ssh_key> <timeout>` → 印出 token 或空。

## 來源選擇與執行

- **候選**:`HOST_TARGETS` 中 caps 含 `ceph` **或** `cephadm` 的 node(cheap `command -v` 先濾,免對無關 node 連線探測)。`detect_node_caps` 擴充:除 cephadm/kubectl 也回報 `ceph` binary。
- **挑來源**:候選裡**第一台** `ceph_runner_for` 回非空的,當 `ceph_source` + `ceph_runner`(early-break)。
- **`--seed`**:仍釘住來源 node;runner 一樣由 `ceph_runner_for(seed)` 連線測試決定(seed 上 ceph 連得上也優先直連)。
- **執行**:`collect_cluster_cephadm` 新增 runner 參數(預設 `cephadm`,維持既有直呼測試相容);`collect_cephadm_command` 依 runner 組前綴:`ceph` / `sudo -n ceph` / `sudo -n cephadm shell -- ceph`。24 條指令全用該前綴。
- **fallback**:候選的所有 token 都連不上 → 換下一個候選;全沒有 → ceph 層 SKIPPED + exit 2(cephadm mode)或資訊性 skip(auto,不算硬失敗)。lab(host 無 ceph)→ direct/sudo 探測 127、cephadm 連得上 → 用 cephadm shell,行為同今日。

## 觀測 / 相容性

- 進度:`collecting ceph cluster from <src> via <runner>…`(runner = ceph / sudo ceph / cephadm shell)。
- `environment.txt` 多記一行 `ceph_runner=<token>`。
- 純粹改「怎麼跑 ceph 指令」與「哪台當來源」;收集的 artifact、exit code(0/2/1)、redaction、bundle 內容不變。
- 既有 `--mode cephadm --seed` 在 lab 上行為不變(退回 cephadm shell)。

## 測試

1. `test-cephadm-collector`：以 runner=`cephadm`(預設)既有斷言不變;新增 runner=`direct` → ssh log 出現 `ceph status …` 且**不含** `cephadm shell` / `sudo`;runner=`sudo` → `sudo -n ceph status` 不含 `cephadm shell`。
2. `test-collect`(fake ssh 擴充:連線探測分 direct/sudo/cephadm 依環境變數成敗;target 改用「跳過 -i/-o 選項」穩定取得):
   - direct 連得上的來源 → 用 `ceph`(log 無 `cephadm shell`),進度 `via ceph`。
   - direct/sudo 失敗、cephadm 連得上 → fallback 用 cephadm shell,進度 `via cephadm shell`。
   - 連線探測失敗的 node 不被選為來源。
   - `environment.txt` 有 `ceph_runner=`。
3. lab 真機:`--mode auto`(host 無 ceph CLI)→ 退回 cephadm shell、ceph 層照收、exit 0。

## 範圍外（YAGNI）

- 平行連線探測。
- 對 rook/kubectl 套相同 runner 邏輯(rook 已是 kubectl,不涉 cephadm shell)。
- 每條 ceph 指令各自加 `--connect-timeout`(沿用既有 timeout 包裝)。
