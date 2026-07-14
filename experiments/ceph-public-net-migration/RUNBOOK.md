# Runbook：把 Ceph public_network 從 1G 管理網段搬到獨立 10G 網段

> 目標叢集：PVE cluster `banqiao`（pve / pve2 / pve3），Proxmox VE 9.0.11，內建 Ceph 19.2.3（squid）。
> 全程用 **PVE 原生工具**（`pveceph` / `/etc/pve/*` / ifupdown2），不使用 cephadm / `ceph orch`。
> 撰寫依據：2026-07-07 對 pve3（192.168.16.7）跑的 read-only 盤點。**動手前每個 node 都要重跑一次 §1 的盤點確認沒有漂移。**

---

## 0. 為什麼這個遷移相對安全（安全模型）

三個「不動」讓風險大幅下降，動手前先理解它們，否則會誤判：

1. **管理網段（vmbr0 / 192.168.16.0/24）全程不動。** 你的 ssh 與 PVE GUI 都走這條。遷移只是「新增一個 10G 網段、把 ceph public 搬過去」，vmbr0 不碰 → **不會把自己鎖在門外**（這是網路變更最常見的地雷，這裡結構上避開了）。
2. **Corosync 全程不動。** 已查證 corosync 是雙 ring 冗餘：ring1 = `172.17.0.x`（10G cluster net，primary）、ring2 = `192.168.16.x`（管理網，backup）。兩條都不在這次遷移的變更面上 → PVE cluster quorum 穩定。
3. **cluster_network（vmbr2 / 172.17.0.0/29）不動。** OSD 複寫流量本來就走這條 10G。這次只搬 client↔OSD/mon 的 **public** 流量。

真正有風險的只有兩段，runbook 對這兩段特別保守：
- **Phase 3 mon 遷移**：PVE 一台一顆 mon（mon 名綁 hostname），必須「destroy 再 create」，過程中會短暫掉到 2/3 mon。
- **Phase 5 OSD rebind**：`ioperf` pool 是 size=2/min_size=2，只有 osd.0 + osd.8 兩顆 SSD，任一 down 該 pool 全停 → 這兩顆要最保守、逐顆等 `HEALTH_OK`。

> ⚠️ 本 runbook 由 AI 依 read-only 盤點撰寫，`pveceph` 破壞性指令（mon destroy/create、OSD restart）我**沒有在你叢集上實跑過**。每一步都附前後斷言，請在場逐步執行、看到綠燈再走下一步，不要背景批次跑完。

---

## 1. 已盤點的現況（evidence，2026-07-07）

| 項目 | 值 | 來源指令 |
|---|---|---|
| PVE | 9.0.11（kernel 6.14.11-4-pve） | `pveversion` |
| Ceph | 19.2.3-pve2 squid，fsid `ec9ee5e3-…ae283` | `ceph -s` / `ceph mon dump` |
| 健康 | `HEALTH_WARN`：osd.0 BlueStore slow ops（**既有基線**，非本次造成） | `ceph -s` |
| mon | 3 顆 quorum：pve2,pve3,pve，全在 `192.168.16.5/6/7` | `ceph mon dump` |
| mgr | active=pve2，standby pve/pve3 | `ceph -s` |
| mds | 1 up + 1 standby（pve/pve2） | `ceph -s` |
| OSD | 11 顆全 up：hdd×9 + ssd×2（osd.0@pve、osd.8@pve3） | `ceph osd tree` |
| pools | 7 pools / 289 pg，預設 size=3/min_size=2；**ioperf pool = size2/min_size2** | `ceph -s` / preflight |

### 現行網路（三張卡，pve3 實測；pve/pve2 待 §3 gate 確認同構）

| bridge | 實體 NIC | 速率/MTU | host IP | 承載 |
|---|---|---|---|---|
| `vmbr0` | enp5s0（Realtek 1G） | **1000Mb/s**（已從 100Mb 恢復）/ 1500 | `192.168.16.7/24`，gw `.2` | 管理 + **ceph public（front）** + corosync ring2 |
| `vmbr1` | enp1s0f0（Intel 10G） | 10000Mb/s / **9000** | **無 host IP** | guest 網（VM 192.168.18.0/24），`#to-core-switch` |
| `vmbr2` | enp1s0f1（Intel 10G） | 10000Mb/s / 9000 | `172.17.0.67/29` | **ceph cluster（back）** + corosync ring1，`#inter-node` |

**核心事實**：`vmbr1`（10G，接 core switch）在 host 上目前**沒有 IP**，是唯一閒置的 10G L2 → 這就是新 public network 的落點。

現行 `ceph.conf` 關鍵行：
```
cluster_network = 172.17.0.66/29
public_network  = 192.168.16.6/24          # ← 要改的就是這行
mon_host        = 192.168.16.6 192.168.16.7 192.168.16.5
[mon.pve]  public_addr = 192.168.16.5
[mon.pve2] public_addr = 192.168.16.6
[mon.pve3] public_addr = 192.168.16.7
```
OSD 目前 front_addr（public）全在 `192.168.16.x`、back_addr（cluster）全在 `172.17.0.x`（`ceph osd metadata` 確認）。
`storage.cfg` 的 rbd/cephfs storage（ceph-vm / ceph-ssd / ioperf / cephfs）**都沒有明寫 `monhost`** → 直接吃 `/etc/pve/ceph.conf` 的 mon_host，mon 換址後**不需逐一改 storage**（PVE 會在 mon create/destroy 時同步 mon_host）。

---

## 2. 目標設計與待你確認的參數

新 public network 落在 `vmbr1`（enp1s0f0，10G），與現有 guest 網 `192.168.18.0/24` **共用同一張實體卡**（guest 流量很輕，可接受；要更乾淨可走 VLAN 隔離，見附註）。

**⚠️ 動手前確認/替換以下參數（本文件以此為預設值）：**

| 參數 | 預設值 | 說明 |
|---|---|---|
| `NEW_PUB_CIDR` | `10.16.0.0/24` | 新 public 網段，須與 192.168.18.0/24（guest）、172.17.0.0/29（cluster）都不重疊 |
| pve 新 IP | `10.16.0.5/24` | 沿用尾碼 .5 對齊管理網 |
| pve2 新 IP | `10.16.0.6/24` | .6 |
| pve3 新 IP | `10.16.0.7/24` | .7 |
| 掛載 bridge | `vmbr1` | 10G、`#to-core-switch` |
| public MTU | `9000`（jumbo）→ **須先過 §3 core-switch jumbo 測試**，不過就退回 `1500` | cluster net 已 9000；public 走 core switch，未證實前不要假設 |
| VLAN 隔離 | 否（flat，與 guest 同 L2） | 預設最簡；要隔離見附註 A |

> 這三個是「你的」決定：網段號、要不要 jumbo、要不要 VLAN。其餘步驟不受選擇影響，改上表即可。

---

## 3. Phase 0 — 前置 gate（全程 read-only + 只加不改，可隨時放棄）

### G0-1（**硬性**）pve / pve2 網卡同構確認
我只盤點了 pve3。**在 pve 與 pve2 各跑一次**，確認也有一張接 core switch、目前閒置的 10G：
```bash
ip -br a | grep -E 'vmbr1|enp1s0f0'
grep -A6 'vmbr1' /etc/network/interfaces
ethtool enp1s0f0 | grep -E 'Speed|Link detected'   # 期望 10000Mb/s / yes
```
> 三台不同構（例如某台 vmbr1 已被佔用、或 NIC 名不同）→ **停，先解決硬體/命名，再回來**。這是整個計畫的地基。

### G0-2 記錄回退基準（存檔備查）
在**任一 mon node**跑，輸出存到本機 `results/`：
```bash
ceph -s
ceph mon dump
ceph osd tree
ceph osd metadata | grep -E '"(id|hostname|front_addr|back_addr)"'
pvecm status
cat /etc/pve/ceph.conf
cat /etc/pve/storage.cfg
cat /etc/network/interfaces          # 三台都存
```

### G0-3 進場健康門檻
```bash
ceph -s
```
必須滿足才進 Phase 1：
- `mon: 3 daemons, quorum ...`（3 顆齊）
- `osd: 11 osds: 11 up ... 11 in`
- PG 全 `active+clean`（容許 1 個 `scrubbing+deep`）
- health 至多是**既有** `HEALTH_WARN: osd.0 BlueStore slow ops`；出現**任何其他** WARN/ERR、或有 recovery/backfill → **停，等乾淨**。

> `iperf3` 目前**未裝**在 node 上。頻寬測試二選一：(a) `apt install iperf3`（需你同意，裝在 host 是持久變更）；(b) 用下面 Phase 1 的 DF-ping 只驗 MTU/連通，頻寬事後在正常運轉時用 rbd bench 觀察。預設走 (b)。

---

## 4. Phase 1 — 建新 10G 網段（三台，只加不改，非破壞性）

> 這步不碰 ceph、不碰 vmbr0/vmbr2、不碰 corosync。做錯最多是新網段不通，回退＝把新增的 iface 段刪掉 `ifreload -a`。

在**每台** node 的 `/etc/network/interfaces`，於 `vmbr1` 區塊**新增一段 host IP**（不要動既有 `vmbr1` 的 bridge-ports/guest 用途）。以 pve3 為例：

```
# 新增：ceph public on 10G（原 vmbr1 定義保持不變，只加 address/mtu 呈現）
auto vmbr1
iface vmbr1 inet static
	address 10.16.0.7/24
	bridge-ports enp1s0f0
	bridge-stp off
	bridge-fd 0
	mtu 9000
#to-core-switch  +ceph-public
```
（pve → `10.16.0.5/24`，pve2 → `10.16.0.6/24`。原本 `iface vmbr1 inet manual` 改成 `inet static` 加 address 即可；**不加 gateway**，public net 不需預設路由。）

套用（**逐台**，不要三台同時，套完立即確認 vmbr1 沒掉、ssh 還在）：
```bash
ifreload -a
ip -br a | grep vmbr1                 # 應看到 10.16.0.x/24
```

三台都上好後，**連通與 MTU gate**（在 pve3 對 pve、pve2 測）：
```bash
ping -c3 10.16.0.5 && ping -c3 10.16.0.6                       # 基本連通
ping -M do -s 8972 -c3 10.16.0.5                               # jumbo：9000 不分片
```
- 基本 ping 不通 → core switch 的對應 port 沒接好/VLAN 不對，先修，**不要往下**。
- jumbo ping 不通但一般 ping 通 → core switch 沒開 9000。**選擇**：開 switch jumbo；或把三台 public MTU 改 `1500` 再測（仍是 10G，只是沒 jumbo）。**public MTU 三台必須一致**。

> ✅ 到這裡 ceph 完全沒動。可以在此停留任意久、隔夜再繼續。

---

## 5. Phase 2 — public_network 併列新舊網段（一次設定，不重啟任何 daemon）

編輯 `/etc/pve/ceph.conf`（pmxcfs，改一次三台同步），把 public_network 改成**新舊併列**：
```
public_network = 192.168.16.0/24, 10.16.0.0/24
```
（順序：舊在前。mon 之後用 `--mon-address` 明指位址，OSD 這階段不重啟，所以順序不影響誰 bind 哪。）

**這步不重啟任何 daemon**，只是讓「之後」建立/重啟的 daemon 認得新網段（`pveceph mon create` 要求新址必須落在 public_network 內——這就是為何要先做這步）。

斷言：
```bash
grep public_network /etc/pve/ceph.conf     # 應含兩個 CIDR
ceph -s                                     # 應與 Phase 0 完全一致（沒東西動）
```
回退：把該行改回 `192.168.16.0/24` 單一即可。

---

## 6. Phase 3 — mon 逐台遷移（最需要盯的一段）⚠️

**PVE 模型**：一台一顆 mon、名字＝hostname，**不能同名共存** → 只能「destroy 舊址 → create 新址」。3 mon 叢集 quorum=2，過程短暫 2/3，**任一步都不可再少一顆**。

**每台重複以下，一次一台，順序建議 pve3 → pve → pve2（把 active-mgr 所在的 pve2 留最後）：**

前置斷言（每台開始前）：
```bash
ceph -s | grep -E 'mon:|health'          # 必須 3 mon quorum、健康如基線
ceph mon stat
```

動作（以 pve3 為例，**在 pve3 本機執行**）：
```bash
# 1) 退掉舊址 mon（此刻掉到 2/3，仍 quorate）
pveceph mon destroy pve3

# 2) 立刻確認仍 quorate（2 顆都在）
ceph -s | grep -E 'mon:|quorum'          # 應顯示 quorum 2 顆、Quorate

# 3) 用新 10G 位址重建
pveceph mon create --mon-address 10.16.0.7

# 4) 確認回到 3 mon、且 pve3 已在新址
ceph mon dump | grep -A0 -E 'mon\.pve3'  # 應看到 10.16.0.7:3300/6789
ceph -s | grep -E 'mon:|health'          # 3 mon quorum、健康回基線
```

**Gate（每台之間）**：必須看到 3 mon 全 quorum、`ceph mon dump` 該台已是 `10.16.0.x`、health 回到基線（只剩 osd.0 slow ops），才動下一台。
- destroy 後若 `ceph -s` 卡住/quorum 不 quorate → **立刻 `pveceph mon create --mon-address <該台舊址>` 復原到舊網段**，停止排查，不要再退第二台。
- create 後新 mon 沒入 quorum（常見：Phase 1 的新網段其實不通/防火牆擋 3300/6789）→ destroy 這顆、回舊址、去查 Phase 6 firewall 與 Phase 1 連通。

三台都換完後：
```bash
ceph mon dump                             # 三顆都在 10.16.0.5/6/7
grep -E 'mon_host|public_addr' /etc/pve/ceph.conf   # PVE 應已自動更新成新址
```

> PVE 的 `pveceph mon create` 同時會處理 mgr。若某台 mgr 被一起重建，`ceph -s` 的 mgr 行短暫 standby 切換屬正常。

---

## 7. Phase 4 — mgr / mds 收尾（低風險）

mgr 無 monmap 硬約束、有 standby，直接讓它在新網段重生：
```bash
# 逐台（非 active 的先做），確認 active/standby 正常切換
pveceph mgr destroy <node>
pveceph mgr create  <node>
ceph -s | grep mgr                        # active + standbys 齊
```
mds 綁 pool 資料流、會走 public network，跟隨 OSD/mon 即可，本階段**不需特別動**；Phase 5 後確認 `mds: 1/1 up + standby` 即可。

---

## 8. Phase 5 — OSD rebind 到新 public（noout + 逐顆，最保守）⚠️

先把 public_network 收斂成**只剩新網段**，強制 OSD 重啟後 bind 新 front：
```bash
# /etc/pve/ceph.conf
public_network = 10.16.0.0/24
```
（mon 已在新址、client 走新 mon_host，收斂成單一網段最乾淨。管理網 192.168.16.x 仍照常給 vmbr0/corosync ring2 用，與 ceph public_network 無關。）

設 noout（避免短暫重啟被判 out 觸發不必要 rebalance）：
```bash
ceph osd set noout
ceph osd dump | grep flags                 # 應含 noout
```

**逐顆重啟**（**一次一顆**，順序：先動 hdd、**osd.0 與 osd.8 兩顆 SSD 最後、且彼此間隔最久**——它們是 ioperf pool 的唯二副本）：
```bash
# 在該 OSD 所在 node 執行，<id> 換成實際編號
systemctl restart ceph-osd@<id>

# 等這顆回穩再動下一顆：
ceph osd metadata <id> | grep front_addr   # 應變成 10.16.0.x
ceph -s                                     # PG 回 active+clean、health 回基線
```

**Gate（每顆之間）**：該 OSD `front_addr` 已是 `10.16.0.x`、且 `ceph -s` PG 全 `active+clean`（容許既有 osd.0 slow ops WARN）、無 recovery 卡住，才動下一顆。
- 建議 SSD 兩顆（osd.0、osd.8）之間至少間隔數分鐘並確認 ioperf pool 的 PG `active+clean`；min_size=2 下若同時只剩 1 副本會停 IO。

全部 11 顆都遷完：
```bash
ceph osd unset noout
ceph osd metadata | grep front_addr        # 11 顆全 10.16.0.x
ceph osd dump | grep -v noout > /dev/null && echo "noout cleared"
```

---

## 9. Phase 6 — client / storage / firewall 驗證

1. **PVE storage**（rbd/cephfs 都沒明寫 monhost → 吃 ceph.conf，已隨 mon 換址更新）：
   ```bash
   pvesm status                              # ceph-vm / ceph-ssd / ioperf / cephfs 都 active
   grep -E 'monhost' /etc/pve/storage.cfg || echo "無明寫 monhost（正確，走 ceph.conf）"
   ```
   隨手開一台既有 VM 的 console 確認磁碟可讀寫（例如 VM 103 已在跑）。
2. **Firewall**（若 Datacenter/Node 層有開 PVE firewall）：確認新網段放行 mon `3300`/`6789`、OSD `6800-7300`。
   ```bash
   ss -tlnp | grep -E ':3300|:6789|:680[0-9]|:681[0-9]'   # 應 listen 在 10.16.0.x
   ```
3. **確認沒有殘留在舊網段**：
   ```bash
   ceph mon dump | grep 192.168.16 && echo "!! 還有 mon 在舊網段" || echo "mon OK"
   ceph osd metadata | grep 'front_addr' | grep 192.168.16 && echo "!! 還有 OSD front 在舊網段" || echo "osd front OK"
   ```

---

## 10. Phase 7 — 收尾與最終核對

```bash
ceph -s                                     # HEALTH：回到僅 osd.0 slow ops 的基線
ceph mon dump                               # 3 mon 全 10.16.0.x
ceph osd metadata | grep -c '10.16.0'       # front_addr 命中數合理
pvecm status                                # PVE quorum 仍 3 節點 Quorate（應全程未變）
pvesm status                                # 所有 ceph storage active
```
- GUI：Datacenter → Ceph 面板應全綠；Datacenter → Ceph → Monitor 三顆 address 為新網段。
- `ceph.conf` 此時 `public_network = 10.16.0.0/24` 單一；`mon_host` 三個新址。
- 更新 `experiments/rbd-io-perf/preflight-snapshot-*.md` 的網路段（public 已非 1G 管理網），H-034 的 1G 天花板假設在新環境作廢/重估。

---

## 11. 回退 playbook（依你走到哪一步）

| 走到 | 回退方式 |
|---|---|
| Phase 1（網路） | 移除 `/etc/network/interfaces` 新增的 address/mtu，`ifreload -a`。ceph 從未動。 |
| Phase 2（雙網段） | `public_network` 改回 `192.168.16.0/24` 單一。無 daemon 動過。 |
| Phase 3（mon，某台失敗） | 對失敗那台 `pveceph mon destroy <node>` 後 `pveceph mon create --mon-address <該台舊 192.168.16.x>` 回舊網段。**一次只回一台、確認 quorum**。 |
| Phase 3 全遷完想整體回退 | 反向重跑 Phase 3：逐台 destroy→create 回 `192.168.16.x`，並把 `public_network` 改回舊值。 |
| Phase 5（OSD） | 該 OSD 尚未 restart 者不受影響；已 restart 想回退＝把 `public_network` 改回含舊網段、逐顆 restart 回 `192.168.16.x`。全程 `noout` 已設，rebalance 風險低。 |

**通則**：新舊網段共存的中間態本身是安全穩定狀態，不是「必須一次做完」。任何一步卡住都可停在中間態排查或隔夜再續。管理網（vmbr0）與 corosync 全程未動，ssh/GUI 不會斷。

---

## 12. 與 rbd-io-perf 實驗的關係（重要）

這個遷移屬於「動 ceph daemon / 重啟 OSD / 改 ceph config」，與 `experiments/rbd-io-perf` charter 的 `out: 任何 ceph cluster/daemon/config 變更、不重啟 ceph` **直接衝突**。兩條 timeline 二選一，不要疊做：

- **建議**：先把 rbd-io-perf 那批實驗跑完收尾，再排這個遷移當獨立 maintenance window；或
- 明確**暫停** rbd-io-perf、把本 runbook 當一次獨立 gated 變更走完，事後再以「新的 10G public」為前提重跑受網路影響的實驗（H-002/H-001 這類頁面修正不受影響；H-034 的 1G 天花板需作廢重估）。

---

## 附註 A：要更乾淨的隔離（VLAN，可選）

預設把 ceph public 與 guest 網放同一張 vmbr1 的 L2（省事、guest 流量輕）。若要把 ceph public 流量與 guest 流量在 L2 隔離：在 core switch 為新網段配一個 VLAN，node 端用 `vmbr1.<vlanid>` 或 VLAN-aware bridge 承載 `10.16.0.x`。代價是要動 switch VLAN 設定、Phase 1 的連通測試要在 VLAN 上做。除非 guest 網之後會變重，否則預設 flat 已足夠。

## 附註 B：本 runbook 未驗證、你要現場核對的點
- `pveceph mon create --mon-address` 的實際行為（我只讀了 help，沒實跑 create/destroy）。
- pve / pve2 的 vmbr1/enp1s0f0 是否與 pve3 同構（G0-1 硬性 gate）。
- core switch 是否讓 `10.16.0.0/24` 三台互通、是否放行 jumbo 9000（Phase 1 gate）。
- 是否有啟用 PVE firewall（Phase 6）。
