# Ceph Alert 真機故障驗證 — 設計（spec）

> 日期：2026-07-04
> 被測對象來源：`next-site/content/ceph/features/prometheus-alert-design.mdx`
> 範圍：用既有 cephadm + Rook external lab 製造真實故障，驗證 `CephClientBlocked` 與 `CephMonQuorumLost` 真的在 Prometheus firing，且真的進 Alertmanager pager receiver。

## 1. 目標

這次不是再做合成 metric 測試，而是用真 lab 證明 alert 對真故障有效。成功標準採使用者指定的 **B 級驗證**：

1. Ceph 真的進入對應 health check。
2. k8s 內 Prometheus scrape 真 mgr/prometheus endpoint 後，對應 alert 進入 `firing`。
3. Alertmanager 依 `prometheus-alert-design` 的 routing 把 alert 送到 pager receiver。
4. webhook sink 收到 pager payload，payload label 能辨識是哪條 alert 與哪個 health check。
5. 每個故障都完成回復，最後 Ceph 回到 `HEALTH_OK`，Rook external cluster 回到 `Connected / HEALTH_OK`。

要驗證的 alert：

| Alert | 分支 | 真實故障 |
|---|---|---|
| `CephClientBlocked` | `PG_AVAILABILITY` | 停掉測試 pool 某個 PG 的多個 acting OSD，讓 PG 掉到 `min_size` 以下 |
| `CephClientBlocked` | `SLOW_OPS` | 對測試 OSD 的 backing block device 做 cgroup v2 I/O throttle，再用 `rados` 打真 workload |
| `CephMonQuorumLost` | mon quorum 低於 3-mon majority | 停掉兩台 mon daemon，保留 active mgr host 以便 Prometheus 盡量仍可 scrape |

## 2. 現有 lab 基線

已 read-only 確認目前 lab 狀態：

- Ceph FSID：`0c9bf37e-514a-11f1-b72a-bc24113f1375`
- Ceph health：`HEALTH_OK`
- mon：
  - `ceph-lab-mon-01` = `192.168.18.166`
  - `ceph-lab-mon-02` = `192.168.18.167`
  - `ceph-lab-mon-03` = `192.168.18.164`
- active mgr：`ceph-lab-mon-02.wmkpax`，Prometheus endpoint `http://192.168.18.167:9283/`
- OSD hosts：
  - `ceph-lab-osd-01` = `192.168.18.169`，OSD `0,1,2`
  - `ceph-lab-osd-02` = `192.168.18.171`，OSD `3,4,5`
  - `ceph-lab-osd-03` = `192.168.18.174`，OSD `6,7,8`
- k8s / Rook：
  - k0s node：`ceph-lab-k8s` = `192.168.18.160`
  - local kubeconfig：`/Users/ikaros/.kube/ceph-lab-k8s.kubeconfig`
  - Rook operator namespace：`rook-ceph`
  - external CephCluster namespace：`rook-ceph-external`
  - current Rook health：`Connected / HEALTH_OK`

## 3. 設計原則

**優先使用現實世界會發生的故障。** 測試不能只靠手刻 metric 或 Ceph debug hook，否則只能證明 alert chain，不能證明 alert 能抓到真事故。

故障注入優先順序：

1. 真 daemon / block I/O / quorum 故障。
2. Linux kernel 或 systemd 層可回復控制，例如 cgroup v2 `io.max`、systemd stop/start。
3. Ceph debug hook 只當備援或對照，不當主 PASS 證據。

每個情境都必須有：

- baseline capture：`ceph -s`、`ceph health detail`、Prometheus target 狀態、目前 firing alerts。
- inject：明確列出改了哪台 host、哪個 OSD/mon、哪個 cgroup 或 systemd unit。
- observe：先看 Ceph health，再看 Prometheus，再看 Alertmanager/webhook sink。
- rollback：無論 PASS/FAIL 都先回復。
- post-check：`HEALTH_OK`、PG `active+clean`、Prometheus target `up`、Rook `Connected / HEALTH_OK`。

## 4. k8s 內監控 stack

在 `ceph-lab-k8s` 上建立臨時 namespace `ceph-alert-lab`，部署三個元件：

1. `prometheus`
   - `scrape_interval: 5s`
   - `evaluation_interval: 5s`
   - scrape target：`192.168.18.167:9283`
   - rule：載入 `experiments/ceph-alert-rules/rules/ceph-stability-first.yml`
   - alerting：送到 in-cluster `alertmanager`
2. `alertmanager`
   - routing 使用 `prometheus-alert-design` 同邏輯
   - pager receiver 指向 `alert-sink` 的 `/pager`
   - slack receiver 指向 `alert-sink` 的 `/slack`
3. `alert-sink`
   - 一個簡單 HTTP receiver
   - 將 receiver、alertname、`name`、`source`、`severity`、完整 labels 寫到 Pod log

PASS 判準不是只看 sink log；必須同時查：

```bash
kubectl -n ceph-alert-lab port-forward svc/prometheus 9090:9090
curl -fsS 'http://127.0.0.1:9090/api/v1/alerts'

kubectl -n ceph-alert-lab logs deploy/alert-sink
```

Alertmanager receiver 只作為 pager path 的證據；Prometheus `firing` 是 alert rule 真被評估的證據。

## 5. 情境一：`CephClientBlocked{name="PG_AVAILABILITY"}`

### 故障模型

真實世界對應：多顆 OSD daemon crash、host 斷電、或 disk 故障讓某個 PG 副本數低於 `min_size`，client I/O 對該 PG 被擋。

### 注入方式

1. 建立獨立測試 pool，例如：
   ```bash
   ceph osd pool create alert-pg-availability 1
   ceph osd pool set alert-pg-availability size 3
   ceph osd pool set alert-pg-availability min_size 2
   rados -p alert-pg-availability put sentinel /etc/hosts
   ```
2. 用 `ceph osd map alert-pg-availability sentinel` 找 acting set。
3. 停掉 acting set 中兩顆 OSD daemon。優先用 systemd 在對應 host stop，因為這比較像 daemon crash / host local failure：
   ```bash
   sudo systemctl stop ceph-0c9bf37e-514a-11f1-b72a-bc24113f1375@osd.N.service
   ```
4. 等 `ceph health detail` 出現 `PG_AVAILABILITY`。

### 觀察

預期：

- `ceph health detail` 有 `PG_AVAILABILITY`。
- mgr metrics 有：
  ```text
  ceph_health_detail{name="PG_AVAILABILITY",severity="HEALTH_WARN"} 1
  ```
- Prometheus alert：
  ```text
  CephClientBlocked{name="PG_AVAILABILITY", source="ceph_stability", severity="critical"} firing
  ```
- webhook sink 收到 pager receiver payload，alertname 是 `CephClientBlocked`，label `name="PG_AVAILABILITY"`。

### 回復

1. start 停掉的 OSD systemd units。
2. 等 `ceph osd tree` 顯示 OSD `up/in`。
3. 等測試 pool PG 回到 `active+clean`。
4. 刪除測試 pool，或保留到所有情境結束後統一清理。

## 6. 情境二：`CephClientBlocked{name="SLOW_OPS"}`

### 故障模型

真實世界對應：底層 disk、controller、hypervisor storage、或 SAN path 變慢，OSD op 還在 in-flight 且超過 `osd_op_complaint_time`。這比 Ceph debug sleep 更接近 production 會發生的 slow disk。

### 主測注入方式：cgroup v2 block I/O throttle

OSD hosts 已確認有 `dmsetup` 與 `tc`，OSD block device 是 LVM over `/dev/sdb/sdc/sdd`。本設計不改 live OSD device mapping，避免 `dm-delay` 插入既有 LVM path 的高風險；改用 cgroup v2 `io.max` 對 OSD systemd service cgroup 施加 block I/O 限速。

流程：

1. 確認 host 使用 cgroup v2：
   ```bash
   stat -fc %T /sys/fs/cgroup
   ```
   預期為 `cgroup2fs`。
2. 建立獨立測試 pool，例如 `alert-slow-ops`，`size=3`、`min_size=2`、`pg_num=1`。
3. 找這個 pool 的 acting set，選一顆 acting OSD 作為 throttle target。優先選 OSD host 上只有測試流量會被打到的目標，降低對其他 pool 的干擾。
4. 找該 OSD backing device 與 major:minor：
   ```bash
   ceph-volume lvm list --format json
   lsblk -no MAJ:MIN /dev/sdX
   ```
5. 對 OSD service cgroup 寫入極低 I/O 上限，例如：
   ```bash
   echo 'MAJ:MIN rbps=65536 wbps=65536 riops=max wiops=max' \
     | sudo tee /sys/fs/cgroup/system.slice/ceph-0c9bf37e-514a-11f1-b72a-bc24113f1375@osd.N.service/io.max
   ```
6. 用真 RADOS workload 打測試 pool：
   ```bash
   rados bench -p alert-slow-ops 180 write -b 4194304 -t 16 --no-cleanup
   ```
7. 等 `ceph health detail` 出現 `SLOW_OPS`。

### 為什麼不用 `dm-delay` 當主測

`dm-delay` 可以製造更接近 block layer latency 的故障，但對既有 ceph-volume LVM OSD 來說，安全做法通常要先建 delayed mapper，再把 OSD 建在 mapper 上。對 live OSD 硬插 delayed mapper 需要改 block path，風險遠高於這次驗證目標。

若未來要測 `dm-delay`，應建立一顆臨時犧牲 OSD，而不是改現有 9 顆 OSD 的 block mapping。

### 備援注入方式：Ceph dispatch delay

若 cgroup throttle 在實測中沒有穩定觸發 `SLOW_OPS`，可以用 Ceph dev option 作為備援，證明 alert chain 對真 Ceph health check 有效：

```bash
ceph config set osd.N osd_op_complaint_time 5
ceph config set osd.N osd_debug_inject_dispatch_delay_probability 1
ceph config set osd.N osd_debug_inject_dispatch_delay_duration 10
```

這不能取代主測，因為它是 Ceph debug hook，不是現實 disk I/O 故障。最終報告必須把它標成 fallback。

### 觀察

預期：

- `ceph health detail` 有 `SLOW_OPS`。
- mgr metrics 有：
  ```text
  ceph_health_detail{name="SLOW_OPS",severity="HEALTH_WARN"} 1
  ```
- 可額外查 per-daemon 佐證：
  ```text
  ceph_daemon_health_metrics{type="SLOW_OPS",ceph_daemon="osd.N"} > 0
  ```
- Prometheus alert：
  ```text
  CephClientBlocked{name="SLOW_OPS", source="ceph_stability", severity="critical"} firing
  ```
- webhook sink 收到 pager receiver payload，alertname 是 `CephClientBlocked`，label `name="SLOW_OPS"`。

### 回復

1. 停止 `rados bench`。
2. 還原 cgroup I/O 上限：
   ```bash
   echo 'MAJ:MIN rbps=max wbps=max riops=max wiops=max' \
     | sudo tee /sys/fs/cgroup/system.slice/ceph-0c9bf37e-514a-11f1-b72a-bc24113f1375@osd.N.service/io.max
   ```
3. 若用了備援 debug hook，必須移除 config：
   ```bash
   ceph config rm osd.N osd_op_complaint_time
   ceph config rm osd.N osd_debug_inject_dispatch_delay_probability
   ceph config rm osd.N osd_debug_inject_dispatch_delay_duration
   ```
4. 等 `SLOW_OPS` 從 `ceph health detail` 消失，PG 回到 `active+clean`。
5. 清掉 `rados bench --no-cleanup` 留下的 objects。

## 7. 情境三：`CephMonQuorumLost`

### 故障模型

真實世界對應：兩台 mon host 掛掉、mon daemon crash、或 network partition，3-mon cluster 剩不到 majority。

### 注入方式

active mgr 目前在 `ceph-lab-mon-02` (`192.168.18.167`)。為了讓 Prometheus endpoint 盡量持續可 scrape，先保留這台，停止另外兩台 mon：

```bash
# on 192.168.18.166
sudo systemctl stop ceph-0c9bf37e-514a-11f1-b72a-bc24113f1375@mon.ceph-lab-mon-01.service

# on 192.168.18.164
sudo systemctl stop ceph-0c9bf37e-514a-11f1-b72a-bc24113f1375@mon.ceph-lab-mon-03.service
```

### 觀察

預期：

- cluster 無法維持 mon quorum，或 `ceph_mon_quorum_status` 低於 2。
- Prometheus alert：
  ```text
  CephMonQuorumLost{source="ceph_stability", severity="critical"} firing
  ```
- webhook sink 收到 pager receiver payload，alertname 是 `CephMonQuorumLost`。

重要邊界：

- 真 quorum loss 可能讓 mgr/prometheus endpoint 也不穩。若 target down，`CephExporterDown` 可能同時 firing。
- `CephMonQuorumLost` 的 rule 有 `or vector(0)`，所以在 `ceph_mon_quorum_status` series stale / absent 後仍應 fire；但如果實測沒有 fire，這是 alert 設計的高價值 finding，不能用合成測試蓋過。

### 回復

1. 先 start 兩個 mon systemd units。
2. 等 `ceph quorum_status` 回到 3 mon quorum。
3. 等 `ceph -s` 回到 `HEALTH_OK`。
4. 確認 Prometheus target `up{job="ceph"} == 1`。

## 8. 執行順序

建議順序：

1. 部署 k8s 內監控 stack，確認 baseline 無測試 alert firing。
2. 跑 `SLOW_OPS`，因為這會造成效能退化但不預期造成資料不可用。
3. 跑 `PG_AVAILABILITY`，因為它會讓測試 pool 的 I/O unavailable。
4. 跑 `CephMonQuorumLost`，因為它可能造成整個 cluster control plane downtime。
5. 最後清理監控 stack 與測試 pools。

每個情境之間必須等 Ceph 回到穩定狀態再進下一個。

## 9. 失敗判讀

| 現象 | 判讀 |
|---|---|
| Ceph health 沒出現目標 health check | 故障注入不足或選錯 target，不算 alert 失敗 |
| Ceph health 有目標 health check，但 Prometheus 沒有對應 metric | mgr/prometheus scrape 或 Ceph exporter 層問題 |
| Prometheus 有 metric，但 alert 沒 pending/firing | PromQL / rule 載入 / `for:` 問題 |
| Prometheus 已 firing，但 sink 沒收到 pager | Alertmanager routing 或 receiver 問題 |
| 故障回復後 alert 不 resolve | recovery 或 Alertmanager resolve path 問題，需記錄但先確保 cluster 健康 |

## 10. 不做

- 不用手刻 `ceph_health_detail` metric 當 PASS 證據。
- 不在 live ceph-volume OSD 下硬插 `dm-delay` mapper。
- 不把 Ceph debug hook 當 `SLOW_OPS` 主測證據。
- 不讓破壞性步驟交給背景 subagent 執行；故障注入與回復要由主流程同步控制。
- 不在 production namespace 裡部署臨時監控 stack；全部限定在 `ceph-alert-lab`。

## 11. 交付物

Implementation plan 應產出：

1. `ceph-alert-lab` k8s manifests 或一個可重跑的 shell orchestrator。
2. 每個情境的 baseline、inject、observe、rollback log。
3. Prometheus `/api/v1/alerts` 查詢結果。
4. `alert-sink` pager log。
5. 最終健康檢查結果。
6. 若任何 alert 未如預期 firing，保留原始證據並標成設計 finding。

