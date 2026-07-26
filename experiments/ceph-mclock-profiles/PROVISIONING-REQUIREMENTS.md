# Azure Provisioning 需求規格 — ceph-mclock-profiles 實驗叢集

> 交付對象：IaC 實作 agent。本文件是完整需求；實驗設計背景見
> `docs/superpowers/specs/2026-07-24-ceph-mclock-profiles-azure-design.md`。
> 驗收方式：§9 的 acceptance checklist 全過。實驗 harness（Ceph 部署、fio、故障注入）
> **不在本次範圍**——IaC 只負責把 VM 帶到「OS-ready」狀態。

## 1. 總覽

| 項目 | 值 |
|---|---|
| Region | **japanwest**（唯一可行：L8s_v3 對本 subscription 只在此 region 開放） |
| Resource Group | `ceph-mclock-profiles`（新建；實驗收官後整組刪除） |
| VM 總數 | 15 台 / 88 vCPU |
| 計價 | on-demand（**不可用 Spot**）；**不可設定 auto-shutdown 排程** |
| Tags（所有資源） | `project=ceph-mclock-profiles`, `owner=ikaros`, `lifetime=ephemeral` |

**Quota 前提**（provision 前必查，需求：Total Regional 88 / LSv3 family 64 / DSv5 family 24）：
舊 RG `CYSHIH-KUBEVIRT-CEPH-LAB` 必須已刪除（由使用者親手，非本次範圍）。
LSv3 quota 上限 65、本次要用 64——**只剩 1 vCPU 餘裕**，8 台 L8s_v3 必須全數建成，
任何一台失敗即視為 provision 失敗（可重試，但不可交付殘缺拓撲）。

## 2. VM 清單

| 主機名 | SKU | 數量 | 角色 | 備註 |
|---|---|---|---|---|
| `mclock-admin` | Standard_D4s_v5 | 1 | Ceph admin / mon.a / mgr / prometheus / 跳板 | **唯一有 public IP 的 VM**；OS disk 128 GB（prometheus 資料要放 96h+） |
| `mclock-mon-1`, `mclock-mon-2` | Standard_D2s_v5 | 2 | Ceph mon | |
| `mclock-osd-1` … `mclock-osd-8` | Standard_L8s_v3 | 8 | Ceph OSD | 各含 1× 1.92TB local NVMe，**保持 raw 不動**（§5） |
| `mclock-client-1` … `mclock-client-4` | Standard_D4s_v5 | 4 | fio 負載機（krbd） | |

- OS disk：未特別註明者 64 GB，StandardSSD_LRS 即可（OS disk 效能不在實驗路徑上）。
- 不需要 availability set / zone（japanwest 無 zone）；不需要 proximity placement group。
- 開啟 boot diagnostics（managed storage 即可）——夜間 reboot 自救時要能看 console。

## 3. 網路

- 1 個 VNet（例 `10.60.0.0/16`）、1 個 subnet（例 `10.60.1.0/24`）；15 台全部在同一 subnet。
- **每台 VM 單 NIC + Accelerated Networking 開啟**（Azure 頻寬是 per-VM，多 NIC 無意義，不要加第二張）。
- private IP：**靜態分配**（實驗 harness 依 inventory 綁定 IP，DHCP 變動不可接受）。建議按序：admin=10.60.1.10、mon-1/2=10.60.1.11-12、osd-1..8=10.60.1.21-28、client-1..4=10.60.1.31-34（可調，但必須固定並反映在 inventory）。
- Public IP：只有 `mclock-admin` 一顆（Static, Standard SKU）。
- NSG（掛 subnet 或 admin NIC 皆可，效果須等價）：
  - inbound：只允許 `<OPERATOR_IP>/32`（參數化，使用者提供）→ admin:22。其他 internet inbound 全拒。
  - subnet 內部：全開（Ceph 需要 3300/6789/6800-7300 等大量 port，內網不設限最單純）。
  - outbound：全開（apt / container registry 拉包）。
- 其餘 14 台無 public IP，一律經 admin 跳板 ssh。

## 4. OS 與帳號（全部 15 台一致）

- Image：**Ubuntu 22.04 LTS**（`Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest`），x86_64。**必須是 22.04，不可用 24.04**——理由見下方 kernel 條目。
- 帳號：`ikaros`，passwordless sudo（`NOPASSWD:ALL`）。
- SSH authorized key（全部 VM 都裝這把）：

  ```
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGTPObK0yNl7+z15+cLNJPoaOS6AFLa7xQA9XNDUdeP learning-k8s-2026-05-22
  ```

- 密碼登入停用（PasswordAuthentication no）。
- hostname 設成 §2 的主機名；**所有 VM 的 `/etc/hosts` 寫入全部 15 台的「主機名 ↔ private IP」對照**（cephadm 依 hostname 運作，必須可互解）。
- timezone：UTC。

## 5. OS 層 desired state（關鍵，逐條驗收）

1. **unattended-upgrades 完全停用**：`apt-daily.timer`、`apt-daily-upgrade.timer` disabled + masked，`unattended-upgrades` 套件移除或停用。**理由：實驗連續跑 72–96h，任何自動更新/自動重啟都會污染資料。**
2. **時間同步**：`chrony` 安裝並啟用（Ceph mon 對 clock skew 敏感）；`systemd-timesyncd` 停用（避免兩套並存）。
3. **swap 關閉**（無 swap 分割/檔案）。
4. **OSD node 的 local NVMe 保持 raw**：`/dev/nvme*n1`（1.92TB 那顆）**不得**分割、不得建立檔案系統、不得掛載、不得進 fstab、不得被 cloud-init 的 disk_setup/mounts 碰到。Ceph OSD 要直接吃 raw block device。（L8s_v3 另有一顆 SCSI resource disk `/dev/sdb`，cloud-init 預設會掛在 `/mnt`——那顆隨意，不影響。）
5. **kernel 必須是 6.8（HWE），15 台一致**——這是**對映生產環境的硬需求**，不是「有就好」：實驗用 krbd（kernel RBD）打 client IO，krbd 行為隨 kernel 版本改變，lab 與生產（Ubuntu 22.04 + kernel 6.8）不一致的話結論無法外推。
   - jammy 的**預設 GA kernel 是 5.15**，必須顯式安裝 HWE：`apt install linux-generic-hwe-22.04` → **reboot** → 確認 `uname -r` 是 `6.8.*`。
   - 不要裝 Azure 專用 kernel（`linux-azure`）——生產不是那個。
   - 交付前請自行 `uname -r` 抽查 15 台皆為 `6.8.*`；驗收腳本會逐台查（`kernel-version` check）。
   - 參考：repo 的 `linux` submodule 已 pin 在 `6.8.0-52.53_22.04.1`，即此 kernel 系列。
6. client node 需確認 `rbd` kernel module 可載入（`sudo modprobe rbd` 成功）。
7. 不做任何 sysctl / IO scheduler / CPU governor 調整（實驗 harness 自己管；IaC 動了反而引入未記錄變因）。

## 6. 套件安裝（apt）

**全部 15 台**：`chrony curl jq python3 lvm2 sysstat iperf3 nvme-cli netcat-openbsd fping`（另確認 `iptables` 指令存在——jammy 預設有，驗收會查）

**osd-1..8 另加**：`fio`（Phase 0 要在 OSD 建立前對 raw NVMe 跑基線量測）

**Ceph 套件——版本必須 pin 19.2.2（squid）**，用 Ceph 官方 apt repo（不要用 Ubuntu distro 的 ceph 版本）：

```
repo: deb https://download.ceph.com/debian-19.2.2/ jammy main
（含 https://download.ceph.com/keys/release.asc 金鑰）
```

> **必須用「按版號」的 repo，不可用滾動的 `debian-squid/`**（2026-07-26 實查）：
> - `debian-19.2.2/dists/` = `bookworm` + `jammy`，`binary-amd64/Packages.gz` 內確有 `ceph-common 19.2.2-1jammy` ✓
> - `debian-squid/` 目前已滾到 **19.2.5**，pool 內**沒有任何 19.2.2 的 deb** → 對它下 `apt install ceph-common=19.2.2-1jammy` 會失敗
> - 兩個 repo 都**沒有 `noble`**（HTTP 404）。加上 Ceph 官方 Squid OS 支援矩陣把 **Ubuntu 22.04 列為 tier A**、24.04 根本不在表上——22.04 才是受支援平台。
> - 相依性已逐條解析：19.2.2-1jammy 的 28 個外部相依在 jammy archive **全部存在且版本約束全滿足**（`libc6>=2.34`、`libstdc++6>=12`、`libssl3`、`libicu70`、`libthrift-0.16.0` 皆為 jammy 原生版本，證明是針對 jammy 建的）。
>
> **兩個容易漏的 apt 設定**：
> 1. **`universe` 必須啟用**——相依的 `librdkafka1`、`libthrift-0.16.0` 在 universe（cloud image 預設開，仍請明確確認）。
> 2. **加 apt pin 指向 `download.ceph.com`**——`jammy-updates` 自帶 `ceph-common 17.2.9`（Quincy），沒 pin 好日後 `apt upgrade` 會打架。

| 目標 | 套件 |
|---|---|
| admin | `cephadm ceph-common`（19.2.2） |
| mon-1/2、osd-1..8 | `podman`（cephadm 的 container runtime；ceph daemon 本體由 harness 用 cephadm 拉 `quay.io/ceph/ceph:v19.2.2` container，IaC 不裝） |
| client-1..4 | `ceph-common`（19.2.2，提供 `rbd` CLI）+ `fio`（jammy distro 版即可，記錄版本） |

> **版本查證（2026-07-26 實查）**：jammy 的 distro `fio` = **3.28**，已確認支援 harness 用到的全部 time-series 選項（`log_avg_msec` / `log_unix_epoch` / `log_hist_msec` / `write_iops_log` / `write_lat_log` / `write_hist_log`）——**不是 blocker**。
> jammy 的 distro `ceph-common` = 17.2（quincy），**這正是必須掛 Ceph 官方 19.2.2 repo 的原因**；裝完請確認 `ceph --version` 顯示 19.2.2 而非 17.2（apt pin/優先序沒設好會裝到 distro 版）。

admin 也要裝 `podman`（mon.a 會跑在 admin 上）。

## 7. 明確的非目標（IaC 不要做）

- 不 bootstrap / 不部署 Ceph cluster（harness 的工作，含 CRUSH rack 拓撲、OSD 建立）。
- 不格式化、不掛載 OSD NVMe。
- 不裝 prometheus/grafana（cephadm 內建 monitoring stack 由 harness 啟用）。
- 不建 load balancer、不建 Azure Bastion 服務（admin VM 就是跳板）、不建 backup/recovery services vault。
- 不設定 VM auto-shutdown、不用 Spot。

## 8. 交付物（handoff 契約）

1. **inventory 檔**（JSON，路徑交付時告知），格式：

   ```json
   {
     "admin_public_ip": "x.x.x.x",
     "nodes": [
       {"name": "mclock-admin",  "role": "admin",  "private_ip": "10.60.1.10"},
       {"name": "mclock-mon-1",  "role": "mon",    "private_ip": "10.60.1.11"},
       {"name": "mclock-osd-1",  "role": "osd",    "private_ip": "10.60.1.21", "rack": "rack1",
      "nvme_device": "/dev/disk/by-id/nvme-..."},
       {"name": "mclock-client-1","role": "client","private_ip": "10.60.1.31"}
     ]
   }
   ```

   osd 條目必須含 `rack` 標籤（osd-1/2=rack1、osd-3/4=rack2、osd-5/6=rack3、osd-7/8=rack4，harness 據此建 CRUSH 拓撲）與 **`nvme_device`**（該台 1.92TB NVMe 的 canonical 路徑，建議 `/dev/disk/by-id/...` 穩定路徑；harness 逐台指定建 OSD，不用 all-available-devices）。
2. **attestation JSON**（與 inventory 同交付）：ssh 進去驗不到的 Azure 控制面事實由 IaC 出具證明，欄位至少：

   ```json
   {
     "accelerated_networking_all": true,
     "vm_priority_all": "Regular",
     "auto_shutdown_none": true,
     "tags_applied": true,
     "public_ip_only_admin": true,
     "hourly_rate_usd": {"L8s_v3": 0.0, "D4s_v5": 0.0, "D2s_v5": 0.0}
   }
   ```

   另需 `generated_at`（ISO 時戳）與 `subscription_id` 欄位。harness 驗收驗**值**而非僅驗存在：boolean 欄位必須為期望值（true/Regular/…）、費率必須為正數、`generated_at` 距驗收時間 <24h、`subscription_id` 與 bastion `az account show` 相符；缺欄位、未提供、或值不符 → **FAIL**，不會 skip。
3. IaC 程式碼與 state 的存放位置（之後 teardown 用同一套刪整個 RG）。

## 9. Acceptance checklist（harness 開跑前逐條驗，任一不過退回）

從 operator 機器（透過 admin 跳板）驗證：

- [ ] 15 台全部 ssh 可達（`ikaros@` + 上述 key；14 台經 admin ProxyJump）。
- [ ] `sudo -n true` 全部成功（passwordless sudo）。
- [ ] 全部主機名正確；任一台 `getent hosts mclock-osd-8` 等 15 個名字皆可解出正確 private IP。
- [ ] **15 台 OS = Ubuntu 22.04**（`/etc/os-release` 的 `VERSION_ID="22.04"`）。
- [ ] **15 台 `uname -r` = `6.8.*`**（HWE kernel；生產對映的硬需求，5.15 即 FAIL）。
- [ ] osd-1..8：`lsblk` 可見 ~1.92TB（1.75TiB）NVMe 裝置，**無分割、無檔案系統、未掛載**。
- [ ] `systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer` → masked/disabled（15 台）。
- [ ] `chronyc tracking` 正常、offset < 100ms（15 台）。
- [ ] `swapon --show` 輸出為空（15 台）。
- [ ] admin：`cephadm version` 與 `ceph --version` = 19.2.2。
- [ ] mon/osd/admin：`podman --version` 正常。
- [ ] client-1..4：`ceph --version` = 19.2.2、`fio --version` 正常、`sudo modprobe rbd` 成功。
- [ ] osd-1..8：`fio --version` 正常；inventory 的 `nvme_device` 路徑存在且與 lsblk 相符。
- [ ] 15 台：`iostat -V`（sysstat）、`iperf3 --version`、`sudo iptables -L -n` 皆正常。
- [ ] attestation JSON 存在且欄位齊全（缺 = FAIL）。
- [ ] client/osd 任兩台間 **背靠背** `ping`（`sudo ping -f`）avg < 2ms。
      **量法很重要**（2026-07-26 真機實測）：每秒一發的 `ping -c 3` 量到 1.3–2.4 ms，
      背靠背量到 0.87–0.99 ms，差 2–3 倍。**與 CPU C-state 無關**——發送端與接收端
      各自壓滿 CPU 都不會改善；那是收端每封包的中斷聚合／排程喚醒成本，pipeline 化
      之後被攤平。實驗跑的是高 queue depth 連續流量＝pipeline 情境，所以 gate 量背靠背；
      間距版的數字仍會收成 covariate 進 environment snapshot（供報告引用），不當 gate。
- [ ] admin 以外的 VM 從 internet 不可達（抽查 1 台 osd 無 public IP）。
- [ ] Accelerated Networking：15 台 NIC 屬性 `enableAcceleratedNetworking=true`。
- [ ] 全部資源帶 §1 tags；無 auto-shutdown 排程；VM priority = Regular（非 Spot）。
