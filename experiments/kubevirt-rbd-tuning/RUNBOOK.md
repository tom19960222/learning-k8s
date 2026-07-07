# kubevirt-rbd-tuning — 執行 RUNBOOK（給下一個 agent 的完整操作手冊）

> **你是誰**：接手執行本研究 T3 實驗的 agent（可能不是原本設計實驗的那位）。
> **讀檔順序**：`HYPOTHESES.md`（charter + 假設）→ `EXPERIMENT-PLAN.md`（每實驗的目的/變因/預期）→ 本文件（怎麼做）→ `STATE.md`（做到哪）。
> **鐵則**：本文件的指令照抄可跑；任何偏離（環境不符、指令失敗改用替代方案）都要記進 `STATE.md` 的 deviation log。預期（prediction）在 `EXPERIMENT-PLAN.md` 各實驗已寫死——**跑之前**把它抄進 bundle 的 `prediction.md`，跑完只准比對、不准改寫。

---

## 0. 環境與存取（✅ 2026-07-08 已交付實填；體檢通過）

環境 = `cyshih-kubevirt-ceph-lab`（japanwest；IaC 在 `~/Documents/code/azure-iac-lab`，
連線細節與生命週期見該 repo `ACCESS.md`——public IP、`make stop/start/destroy`）。
**NSG 只放行使用者固定 IP 的 22/6443 → 必須在使用者的 Mac（同對外 IP）上執行。**

| 變數 | 值 |
|---|---|
| `MON1/2/3` | `20.89.248.174` / `40.74.64.220` / `20.89.232.116`（cyshih-mon-{0,1,2}） |
| `OSD1/2/3` | `20.89.233.19` / `20.78.146.15` / `20.89.232.246`（cyshih-osd-{0,1,2}；私網 10.0.2.x、**ceph cluster 網 10.0.3.x**） |
| `K8SCP` | `20.89.248.121`（cyshih-k8s-0；worker：`20.63.217.150` / `20.78.153.64`） |
| `FSID` | `ab33c12c-7a5c-11f1-913a-894a658522d3` |
| ssh | user=`azureuser`、key=`~/.ssh/azure-lab`（**不是** repo key） |
| pool / SC | `kubevirt`（size3/min_size2/pg64）；SC=`ceph-rbd`（default，krbd，`imageFeatures: layering`，secret=`csi-rbd-secret@ceph-csi-rbd`） |
| 版本 | ceph **19.2.4**（pinned 19.2.3，patch 差）、ceph-csi **v3.14.0** ✓、KubeVirt **v1.5.0** ✓、k8s v1.32.13、Ubuntu 22.04 + kernel **6.8**-azure ✓ |
| OSD 硬體 | **L8s_v3 fallback 案**：每台 1 顆實體 NVMe 1.7T 切 3 OSD（各 ~100G，叢集 900G）——E-22/per-OSD 隔離解讀力降（同碟鄰居），寫結論時標註 |

**本機（macOS bastion）注意**：bash 3.2（無 mapfile/nameref、空陣列 + `set -u` 會爆）、無 `timeout`、無 `gh`；中文字串內變數一律寫 `${var}`。詳見 repo `CLAUDE.md`。

**標準入口**（zsh 下用函式，不要用含空白的變數展開）：

```bash
s(){ ssh -i ~/.ssh/azure-lab -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$@"; }
ceph_c(){ s azureuser@20.89.248.174 "sudo ceph $*"; }        # mon 有 ceph-common，不用 cephadm shell
kc(){ s azureuser@20.89.248.121 "kubectl $*"; }              # cp 的 azureuser 已有 kubeconfig
# kubectl 也可直接在 Mac 跑（ACCESS.md §3 匯 kubeconfig）——大量操作時比 ssh 快
```

**guest 存取**：VMI 起來後 `kc get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'`，經 cp 跳板：

```bash
guest(){ s -o ProxyJump=azureuser@20.89.248.121 ubuntu@$GUEST_IP "$*"; }
# 不通則 fallback：s azureuser@20.89.248.121 "ssh -o StrictHostKeyChecking=no ubuntu@$GUEST_IP '$*'"
#（cloud-init 注入的 key 用 ~/.ssh/azure-lab.pub，manifest §3 的 YOUR_PUBKEY 以它取代）
```

**環境特性（影響實驗的三件事）**：
1. `make stop` = deallocate = **NVMe 清空**；`make start` 自動重建 ceph（IaC 內建）→ 每個 ceph 世代 E-01 sentinel 要重驗（§4 E-01）、跨世代數字不可直接比。
2. RWX Block PVC 已實測 Bound ✓（migration 前提成立）；Kyverno policy `rbd-block-disk-group` 給 pod GID 6 開 RBD 裸裝置——E-00 snapshot 要收這條 policy。
3. E-31/E-41 的 `az vm stop` 操作 **RG=cyshih-kubevirt-ceph-lab、只准動 cyshih-* 資源**（共享訂閱）；無 az 權限就把指令交給使用者。

---

## 1. 目錄結構與資料格式（先建好，全程遵守）

```
experiments/kubevirt-rbd-tuning/
  HYPOTHESES.md  EXPERIMENT-PLAN.md  AZURE-ENV-SPEC.md  RUNBOOK.md（本檔）
  STATE.md                     ← 進度 + deviation log（每完成一步就更新，git 追蹤）
  manifests/                   ← 本 runbook §3 的 YAML 全放這（git 追蹤）
  tools/                       ← §2 的三支小工具（git 追蹤）
  results/                     ← evidence bundle（.gitignore，不進版控）
    E-XX/<UTC 時戳 yyyymmdd-HHMMSS>/
      prediction.md            ← 跑前抄自 EXPERIMENT-PLAN 該節「預期結果」
      env-snapshot.txt         ← 本輪開跑時 ceph -s + kc get nodes + 日期
      effect-verify-<variant>.txt ← 生效驗證輸出（§2.4）
      round-<N>-<variant>/     ← 每輪一目錄
        fio-<pattern>.json     ← fio --output-format=json 原檔
        fio-<pattern>_clat.*.log ← latency log
        ceph-before.json / ceph-after.json （ceph -s -f json，含本機時戳首行）
        guest-iostat.txt / host-iostat.txt / qmp-blockstats.json（能收則收）
      verdict.md               ← tools/fio_stats.py 輸出 + 三態判定（機器產生）
  EVIDENCE-SUMMARY-<date>.md   ← 索引（git 追蹤）：每實驗一節，結論+關鍵數字+bundle 路徑
```

**記錄規則**：
- 頁面/總結裡出現的每個數字必須能對到某個 bundle 檔案。
- verdict 三態：`confirmed` / `violated` / `indistinguishable`，由 §2.5 演算法判定，不准手改。
- 每完成一個實驗：更新 `STATE.md`（一行：`E-XX done <bundle path> <一句話結論>`）→ 更新 `EVIDENCE-SUMMARY` → 更新 `HYPOTHESES.md` 對應假設的 Status/Evidence → **commit + push**（見 §7）。

---

## 2. 共用工具與程序

### 2.1 fio 矩陣（正常態，所有 E-1x 用同一套）

guest 內執行（資料盤固定 `/dev/vdb`，**必須已 pre-fill**，見 2.3）。8 個 pattern：

```bash
# 在 guest 內建 /home/ubuntu/run_matrix.sh（內容如下），每輪呼叫一次
# 用法：bash run_matrix.sh <輸出目錄>
OUT=$1; mkdir -p $OUT
run(){ # name rw bs iodepth
  sudo fio --name=$1 --filename=/dev/vdb --direct=1 --ioengine=libaio \
    --rw=$2 --bs=$3 --iodepth=$4 --numjobs=1 --time_based --runtime=60 \
    --ramp_time=15 --randseed=8675309 --group_reporting \
    --output-format=json --output=$OUT/fio-$1.json \
    --write_lat_log=$OUT/fio-$1 --log_avg_msec=1000
}
run rr-qd1  randread  4k 1;  run rr-qd8  randread  4k 8;  run rr-qd32 randread  4k 32
run rw-qd1  randwrite 4k 1;  run rw-qd8  randwrite 4k 8;  run rw-qd32 randwrite 4k 32
run sr-1m   read      1M 16; run sw-1m   write     1M 16
```

跑完 `scp` 回本機 bundle 的 `round-<N>-<variant>/`。

### 2.2 degraded 固定負載（所有 E-3x 用）

兩個 fio job 並行 + 三個收集迴圈，統一時間軸（全部記 **epoch 秒**）：

```bash
# guest 內（背景跑，總長 = 注入前 120s + 注入期 + 恢復後 300s，runtime 給足 1800 手動 kill）：
sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite \
  --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=1800 --output-format=json \
  --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 &
sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread \
  --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=1800 --output-format=json \
  --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 &
sudo dmesg -T -w > /home/ubuntu/dg/dmesg.log 2>&1 &

# 本機另開收集迴圈（打到 mon1，5s 粒度，輸出 jsonl，每行首欄=epoch）：
while true; do
  echo "$(date +%s) $($SSH ikaros@$MON1 'sudo cephadm shell -- ceph health detail -f json' 2>/dev/null | tr -d '\n')"
  sleep 5
done >> results/E-3X/<ts>/health.jsonl &

# 注入與回復時刻戳記（照抄，别省）：
date +%s > results/E-3X/<ts>/T0-inject.txt   # 注入瞬間
date +%s > results/E-3X/<ts>/T1-recover.txt  # 回復動作瞬間
# 收尾：kill 兩個 fio（guest 內 sudo pkill fio）→ 收檔 → 停收集迴圈
```

**每個 degraded 實驗跑完必收 5 件**：lat log 時序、health.jsonl（哪些健康碼亮）、guest dmesg（hung task？）、恢復後 guest `mount | grep vdb` + `dmesg | grep -iE "hung|readonly|remount"`、fs 是否需人工介入（`touch` 測試盤上的檔案）。

### 2.3 pre-fill（每顆新資料盤建立後、量測前，一次）

```bash
guest 'sudo fio --name=prefill --filename=/dev/vdb --rw=write --bs=1M --iodepth=8 --direct=1 --size=100%'
```

### 2.4 生效驗證（每個變體開跑 fio 前必過，輸出存 effect-verify-<variant>.txt）

```bash
# (a) QEMU cmdline（cache/aio/num-queues/iothread 全在這）：
POD=$(kc get pod -n vmtest -l kubevirt.io/domain=baseline -o jsonpath='{.items[0].metadata.name}')
kc exec -n vmtest $POD -c compute -- sh -c 'tr "\0" "\n" < /proc/$(pgrep -f qemu-system | head -1)/cmdline' \
  | grep -E 'blockdev|device|iothread|cache|aio' > effect-verify-X.txt
# (b) domain XML（佐證）：
kc exec -n vmtest $POD -c compute -- virsh dumpxml 1 >> effect-verify-X.txt
# (c) krbd 側（在 VM 所在 worker 上；map options 全文在 config_info）：
NODE=$(kc get pod -n vmtest $POD -o jsonpath='{.spec.nodeName}')
$SSH ikaros@$NODE 'for d in /sys/bus/rbd/devices/*; do echo "$d: $(cat $d/config_info)"; done; grep . /sys/block/rbd*/queue/nr_requests /sys/block/rbd*/queue/read_ahead_kb' >> effect-verify-X.txt
# (d) guest 側：
guest 'grep . /sys/block/vdb/queue/scheduler /sys/block/vdb/queue/nr_requests /sys/block/vdb/queue/read_ahead_kb; ls /sys/block/vdb/mq/ | wc -l' >> effect-verify-X.txt
```

**斷言**：輸出裡的值必須符合該變體宣稱（例：cache=writeback ⇒ cmdline 出現 `"cache":{"direct":false`…；queue_depth=256 ⇒ nr_requests=256）。不符 ⇒ 停，查原因，記 deviation。

### 2.5 統計與 verdict（tools/fio_stats.py——第一次開工時照此建檔）

```python
#!/usr/bin/env python3
"""用法:
  fio_stats.py cov  <dir含多輪同variant>            # E-01: 每 pattern 的 mean/CoV
  fio_stats.py cmp  <A_rounds_dir> <B_rounds_dir> <band.json>  # A/B 比對出 verdict 表
band.json = E-01 產出 {pattern: {metric: band_fraction}}
規則: band = max(2*CoV_E01, 0.05)。|relative_diff| > band → 有方向, 否則 indistinguishable。
p99.9 僅在樣本數(iops*60)>=1e5 時輸出。"""
import json,sys,glob,statistics as st,os
def load(d):
    out={}
    for f in glob.glob(os.path.join(d,'**','fio-*.json'),recursive=True):
        j=json.load(open(f));job=j['jobs'][0]
        pat=os.path.basename(f)[4:-5]
        rw='read' if job['read']['iops']>job['write']['iops'] else 'write'
        s=job[rw];pct=s['clat_ns']['percentile']
        m={'iops':s['iops'],'p50':pct['50.000000'],'p99':pct['99.000000'],
           'p999':pct['99.900000'],'max':s['clat_ns']['max'],'samples':s['iops']*60}
        out.setdefault(pat,[]).append(m)
    return out
def cov(vals): m=st.mean(vals); return (st.stdev(vals)/m if len(vals)>1 and m else 0)
if sys.argv[1]=='cov':
    r=load(sys.argv[2]);band={}
    for p,ms in sorted(r.items()):
        band[p]={k:max(2*cov([m[k] for m in ms]),0.05) for k in('iops','p99','p999')}
        print(p,{k:f"mean={st.mean([m[k] for m in ms]):.0f} cov={cov([m[k] for m in ms]):.1%}" for k in('iops','p99')})
    json.dump(band,open('band.json','w'),indent=1);print('band.json written')
else:
    A,B=load(sys.argv[2]),load(sys.argv[3]);band=json.load(open(sys.argv[4]))
    for p in sorted(A):
        for k in('iops','p99','p999','max'):
            if k=='p999' and st.mean([m['samples'] for m in A[p]])<1e5: continue
            a,b=st.mean([m[k] for m in A[p]]),st.mean([m[k] for m in B[p]])
            d=(b-a)/a if a else 0;bd=band.get(p,{}).get(k,0.10)
            v='indistinguishable' if abs(d)<bd else ('B_higher' if d>0 else 'B_lower')
            print(f"{p:8s} {k:5s} A={a:12.0f} B={b:12.0f} diff={d:+7.1%} band={bd:.0%} -> {v}")
```

**stall 斷言**（正常態實驗）：fio json 的 `clat_ns.max > 1e9`（>1s）即 flag，寫進 verdict.md 並人工看 lat log 확認是否整段 stall。

### 2.6 標準量測迴圈（所有 E-1x 照此，A=baseline，B=變體）

1. bundle 目錄建好，抄 `prediction.md`，收 `env-snapshot.txt`。
2. 套用變體（§4 各實驗的「套用」步驟）→ **生效驗證**（2.4）。
3. A/B 交錯 3 輪：`for N in 1 2 3: [切到A→驗證→ceph-before→run_matrix→ceph-after] [切到B→同上]`。
   - 切換代價高的變體（要 stop/start VM 的）：允許改為 A×1,B×1,A×1,B×1,A×1,B×1 共各 3 輪，嚴禁 AAABBB。
   - 每輪 ceph-before/after 若出現 `recovery|backfill|degraded` → 該輪作廢重跑（記 tainted）。
4. `python3 tools/fio_stats.py cmp <A輪> <B輪> band.json > verdict.md`，對照 prediction 寫三態。
5. 回退到 baseline 設定 → 生效驗證確認回到 A → 更新 STATE/SUMMARY/HYPOTHESES → commit。

**guardrails（每輪自查）**：`ceph -s` 出現 HEALTH_ERR 或新增 slow ops → 全停排查；SSD 用量 >70% → 清理舊 image 再繼續。

---

## 3. 基準環境建立（E-00 之後、E-01 之前做一次）

### 3.1 namespace / SC / PVC / VM manifest（存 `manifests/`）

`manifests/00-sc-rwx-block.yaml`（若 Rook external 已建同功能 SC 則跳過，記下實際名稱）：

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: rbd-rwx-block}
provisioner: rook-ceph.rbd.csi.ceph.com   # E-00 查實際 provisioner 名（rook external 可能帶 namespace 前綴）
parameters:
  clusterID: rook-ceph-external            # E-00 查實際值
  pool: kubevirt
  imageFeatures: layering,exclusive-lock,object-map,fast-diff
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph-external
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph-external
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph-external
reclaimPolicy: Delete
allowVolumeExpansion: true
```

`manifests/01-pvc-data.yaml`：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data-baseline, namespace: vmtest}
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  storageClassName: rbd-rwx-block
  resources: {requests: {storage: 16Gi}}
```

`manifests/02-vm-baseline.yaml`（**baseline = 什麼都不設**；boot 用 containerDisk 避免 boot 盤噪音；`YOUR_PUBKEY` 換成 repo `.ssh/id_ed25519.pub` 內容）：

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: {name: baseline, namespace: vmtest}
spec:
  runStrategy: Always
  template:
    metadata: {labels: {kubevirt.io/domain: baseline}}
    spec:
      domain:
        cpu: {cores: 4}
        memory: {guest: 8Gi}
        devices:
          disks:
          - name: boot
            disk: {bus: virtio}
          - name: data          # ← 被測盤，一切 driver 欄位留空 = baseline
            disk: {bus: virtio}
          - name: cloudinit
            disk: {bus: virtio}
          interfaces: [{name: default, masquerade: {}}]
      networks: [{name: default, pod: {}}]
      volumes:
      - name: boot
        containerDisk: {image: "quay.io/containerdisks/ubuntu:24.04"}
      - name: data
        persistentVolumeClaim: {claimName: data-baseline}
      - name: cloudinit
        cloudInitNoCloud:
          userData: |
            #cloud-config
            users:
            - name: ubuntu
              sudo: ALL=(ALL) NOPASSWD:ALL
              ssh_authorized_keys: ["YOUR_PUBKEY"]
            packages: [fio, sysstat]
            package_update: true
```

建立與驗收：

```bash
kc create ns vmtest
kc apply -f manifests/00-sc-rwx-block.yaml -f manifests/01-pvc-data.yaml -f manifests/02-vm-baseline.yaml
kc wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s
GUEST_IP=$(kc get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}')
guest 'fio --version && lsblk /dev/vdb'   # fio 裝好 + 資料盤可見才算好
# pre-fill（2.3）→ 完成基準環境
```

### 3.2 變體切換標準程序（B 類旋鈕：改 VM template + 重啟）

```bash
kc patch vm -n vmtest baseline --type=json -p '<該實驗的 patch，見 §4>'
kc get vm -n vmtest baseline -o jsonpath='{.status.conditions[?(@.type=="RestartRequired")]}'  # 應出現（H-001 佐證，顺手截進 bundle）
$SSH ikaros@$K8SCP 'sudo k0s kubectl virt stop baseline -n vmtest' 2>/dev/null || kc patch vm ... # 若無 virt plugin：
#   stop = kc patch vm -n vmtest baseline --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
#   start = 改回 '{"spec":{"runStrategy":"Always"}}'
kc wait -n vmtest vmi/baseline --for=delete --timeout=300s   # stop 後
# start 後重取 GUEST_IP（pod IP 會變！），重跑生效驗證
```

---

## 4. 各實驗 step-by-step

> 每個實驗 = 2.6 標準迴圈 + 本節的「套用/回退」差異。變體 patch 全部先寫進
> `manifests/patch-<EID>-<variant>.json` 再 apply（留檔）。預期結果見 EXPERIMENT-PLAN 同名節。

### E-00 環境盤點（read-only）
```bash
{ date -u; ceph_c -s; ceph_c versions; ceph_c osd tree; ceph_c osd pool ls detail; ceph_c config dump
  kc get nodes -o wide; kc get sc -o yaml; kc -n rook-ceph-external get cephcluster -o yaml
  kc get kubevirt -A -o jsonpath='{..observedKubeVirtVersion}'
  for h in $MON1 $OSD1 $K8SCP $K8SW1; do $SSH ikaros@$h 'hostname; uname -r; lsb_release -ds'; done
  $SSH ikaros@$OSD1 'lsblk -d -o NAME,SIZE,MODEL | grep -i nvme'
  $SSH ikaros@$K8SW1 'ls -l /dev/kvm && egrep -c "vmx|svm" /proc/cpuinfo'   # nested virt 硬斷言
  for h in $OSD1 $OSD2 $OSD3 $K8SW1 $K8SW2; do $SSH ikaros@$K8SCP "ping -c3 -q $h | tail -1"; done
} > results/E-00/<ts>/snapshot.txt 2>&1
# ⚠ 斷言：kernel 6.8.x、ceph 19.2.3、kubevirt v1.5.0、/dev/kvm 存在、9 osd up/in。
# ⚠ cephadm autotune 檢查：ceph_c config get osd osd_memory_target → 若非 4294967296，
#    ceph_c config set osd osd_memory_target 4294967296 並記錄（L32s 大記憶體會被 autotune 抬高，汙染 baseline）。
```

### E-01 噪音帶（先於一切量測）
1. baseline VM 照 2.6 但**只有 A**：run_matrix ×5 輪（至少分兩個時段，如相隔 2h+）。
2. `python3 tools/fio_stats.py cov results/E-01/<ts> > verdict.md`——產出 `band.json`（**放到 repo 目錄下 git 追蹤**，之後所有 cmp 用它）。
3. 判準檢查：若 rw-qd32/sr/sw 的 CoV >15%，之後所有實驗 n 改 5、runtime 改 120（記 deviation）。

### E-02 host 層天花板
```bash
# 在 K8SW1（非 guest）直接 map 一顆 throwaway image：
ceph_c osd pool ls | grep -q '^kubevirt$'
$SSH ikaros@$MON1 'sudo cephadm shell -- rbd create kubevirt/ioperf-host --size 16G'
# 取 key 給 worker map 用（worker 需 ceph-common；沒有就 apt install，記 deviation）：
ceph_c auth get-or-create client.hosttest mon 'profile rbd' osd 'profile rbd pool=kubevirt'  # 輸出 keyring 放到 W1 /etc/ceph/
$SSH ikaros@$K8SW1 'sudo rbd map kubevirt/ioperf-host --id hosttest && lsblk /dev/rbd0'
# pre-fill + run_matrix（把 2.1 腳本放上 W1，--filename=/dev/rbd0）×3 輪
# 收尾：sudo rbd unmap /dev/rbd0；rbd rm kubevirt/ioperf-host；ceph auth rm client.hosttest
```
比對：host vs guest baseline（E-01 的輪）→ 虛擬化稅表。

### E-03 觀測路徑驗證
baseline 負載中（guest 跑 rr-qd8 60s），同窗收三邊界，斷言 IOPS 互洽 ±10%：
```bash
guest 'iostat -x 5 12 /dev/vdb' > guest-iostat.txt &
$SSH ikaros@$NODE 'iostat -x 5 12 $(lsblk -no NAME /dev/rbd* | head -1)' > host-iostat.txt &
kc exec -n vmtest $POD -c compute -- virsh domblkstat 1 vdb > qmp-1.txt; sleep 60
kc exec -n vmtest $POD -c compute -- virsh domblkstat 1 vdb > qmp-2.txt   # 差分/60 = IOPS
```

### E-10 cache mode
- 套用（writethrough 變體；writeback 同理）：
  `manifests/patch-E10-wt.json = [{"op":"add","path":"/spec/template/spec/domain/devices/disks/1/cache","value":"writethrough"}]`
- 生效斷言：cmdline 中 data 盤 blockdev `"cache":{"direct":true,"no-flush":false}` + device `write-cache=off`（wt）／`"direct":false` + `write-cache=on`（wb）／`"direct":true` + `write-cache=on`（none/baseline）。
- 三變體兩兩對 baseline 跑 2.6 迴圈；回退 = patch remove cache 欄位。

### E-11 bus=scsi
- patch：disks/1 改 `{"name":"data","disk":{"bus":"scsi"}}`；guest 內盤名變 **`/dev/sda`**（run_matrix 的 filename 跟著改，記進 bundle）。
- 生效斷言：cmdline 出現 `virtio-scsi-pci` + `scsi-hd`。

### E-12 io=threads
- patch：`add /spec/template/spec/domain/devices/disks/1/io = "threads"`；斷言 cmdline data 盤 `"aio":"threads"`（baseline 是 `"aio":"native"`）。
- 加收 QEMU CPU：每輪 fio 前後 `kc exec $POD -c compute -- cat /proc/$(pgrep -f qemu-system)/schedstat`。

### E-13 多 queue（⚠ 計畫修正）
KubeVirt **沒有欄位能強制 queues=1**（blockMultiQueue 只會設成 vCPU 數）。本實驗降級為「no-op 驗證」：
- A=baseline（不設）vs B=`blockMultiQueue: true`（patch add `/spec/template/spec/domain/devices/blockMultiQueue=true`）。
- 斷言：兩variant guest `ls /sys/block/vdb/mq | wc -l` **都是 4** → 錨點 confirmed；fio 預期 indistinguishable。
- 真 queues=1 對照需 hook sidecar，標 optional-skip（除非時間充裕，見 EXPERIMENT-PLAN）。deviation 已預先記錄於此。

### E-14 dedicatedIOThread
- patch：disks/1 add `dedicatedIOThread: true`；斷言 domain XML data 盤 `<driver ... iothread='N'>` 且 cmdline 有第二條 iothread 物件。
- 雙盤輪：再建 `data2` PVC+patch 加第三顆盤，guest 內兩個 fio 同時打 `/dev/vdb` `/dev/vdc`（各 rr-qd8），合計 IOPS 對照。

### E-15 CPU limit throttle
- A=Guaranteed：patch resources `{"requests":{"cpu":"4","memory":"8Gi"},"limits":{"cpu":"4","memory":"8Gi"}}`。
- B=可 throttle：limits cpu 降到 `4`→`2`（vCPU 仍 4 → CFS 必 throttle）。
- 負載：guest `stress-ng --cpu 2 &` + fio rr-qd8；每輪收 worker 上
  `$SSH ikaros@$NODE 'cat /sys/fs/cgroup/kubepods*/*/*$(kc get pod -n vmtest $POD -o jsonpath={.metadata.uid} | tr - _)*/cpu.stat'`（路徑不合就 `find /sys/fs/cgroup -name cpu.stat | xargs grep -l nr_throttled` 篩，記 deviation）。
- 斷言 B 的 `nr_throttled` 增長 >0；比 p99.9。

### E-16 dedicatedCpuPlacement（2×2）
- 前置：worker 需開 CPUManager static policy——k0s worker profile 加 kubelet 參數 `--cpu-manager-policy=static --kube-reserved=cpu=1`（改完要重啟 k0s worker；這是環境級變更，先在 STATE.md 記錄）。
- patch：cpu 區塊 `{"cores":4,"dedicatedCpuPlacement":true,"isolateEmulatorThread":true}`。
- 競爭注入：同 node 跑 `kc apply` 一個 stress pod（requests cpu=2, `stress-ng --cpu 4`）。
- 四格：{競爭有/無}×{dedicated on/off}，每格 rr-qd1+rr-qd8 n=3。

### E-17 guest scheduler（A 類，免重啟）
```bash
guest 'echo none | sudo tee /sys/block/vdb/queue/scheduler'      # B
guest 'echo mq-deadline | sudo tee /sys/block/vdb/queue/scheduler' # A(Ubuntu 預設，先 cat 確認)
```
同 VM 內 A/B 交錯即可，生效驗證 = cat scheduler。

### E-18 readahead（A 類）
guest：`echo {128,512,4096} | sudo tee /sys/block/vdb/queue/read_ahead_kb`；host 子實驗同路徑改 `/sys/block/rbdX/queue/read_ahead_kb`。主 pattern：sr-1m + 補一個 `sr-4k-qd1`（`--rw=read --bs=4k --iodepth=1`）。

### E-19 krbd queue_depth（D 類：每變體新 SC+PVC）
```bash
# SC 變體：複製 00-sc-rwx-block.yaml，metadata.name=rbd-qd{64,256}，parameters 加：
#   mapOptions: "krbd:queue_depth=64"      （另一份 =256）
# 每變體：新 PVC data-qd64 → patch VM volumes.data 指到新 claim → stop/start → pre-fill
# 生效斷言：host /sys/bus/rbd/devices/*/config_info 含 queue_depth=64 且 nr_requests=64
# placement 記錄：ceph_c osd map kubevirt $(ceph_c rbd ls kubevirt | grep <image>) 存 bundle
# 高並行 pattern 加跑：rr-qd32 增 --numjobs=4 版本（命名 rr-qd32x4）
```

### E-20 image layout（D 類）
```bash
$SSH ikaros@$MON1 'sudo cephadm shell -- rbd create kubevirt/ioperf-16m --size 16G --object-size 16M'
$SSH ikaros@$MON1 'sudo cephadm shell -- rbd create kubevirt/ioperf-stripe --size 16G --stripe-unit 64K --stripe-count 4'
# 掛法：手動建 PV+PVC 指向既有 image（csi 靜態供應，volumeAttributes 填 imageName/pool/clusterID
#   ——照抄一顆動態 PV 的 yaml 改 imageName 最穩），或直接 host 層對照（rbd map 跑矩陣，同 E-02 方法）。
#   優先 host 層（簡單、無 csi 干擾），VM 層有時間再補。記 deviation。
```

### E-21 osd_memory_target（A 類 runtime）
```bash
ceph_c config set osd osd_memory_target 8589934592   # B=8G；A=4294967296
# 等 10 分鐘 cache 暖 → 跑矩陣（重點 rr-qd1/rr-qd8）→ 每輪收：
ceph_c orch ps --daemon-type osd --format json | ...  # 或 ssh OSD node: ps -o rss= -C ceph-osd
# 回退：config set 回 4G。E-52 的行為級證據順手在此收（RSS 變化曲線）。
```

### E-22 osd_op_num_shards（C 類 rolling restart）
```bash
ceph_c config set osd osd_op_num_shards_ssd 16
# rolling：for i in 0..8: ceph_c orch daemon restart osd.$i && 等 HEALTH_OK（while 迴圈 10s 輪詢）
# ↑ rolling 全程 guest 跑 2.2 degraded 負載收 client p99 時序（= C 類代價的免費數據）
# 驗證：ceph_c config show osd.0 osd_op_num_shards_ssd（restart 後才變）→ 跑矩陣 → 回退（再 rolling 一次回 8）
```

### E-30 單 OSD 乾淨 down
```bash
# 2.2 負載跑起 → 120s 後：
ceph_c osd ok-to-stop osd.3            # 必須 ok 才繼續
date +%s > T0-inject.txt; ceph_c orch daemon stop osd.3
sleep 600                               # 覆蓋 mon_osd_down_out_interval 預設 600s → 觀察 out+backfill 啟動
date +%s > T1-recover.txt; ceph_c orch daemon start osd.3
# 等 HEALTH_OK → 再收 300s → 收尾
```

### E-31 OSD node 全滅（需 az 或使用者代操作）
同 E-30 骨架，注入改：`az vm stop --resource-group rg-kubevirt-rbd-tuning --name ceph-osd-2 --skip-shutdown`（或請使用者執行）；回復 `az vm start ...` + 確認 3 OSD 回 up。

### E-32 gray failure（慢 OSD，不 down）
```bash
# 對 osd.3 的 systemd unit 加 IO 上限（cgroup v2）：
$SSH ikaros@$OSD2 'lsblk -no MAJ:MIN /dev/nvme1n1'    # 該 OSD 用的碟（E-00 拓樸對照）
$SSH ikaros@$OSD2 "sudo systemctl set-property --runtime ceph-$FSID@osd.3.service IOReadIOPSMax='MAJ:MIN 100' IOWriteIOPSMax='MAJ:MIN 100'"
# 斷言注入生效：該 unit cgroup 的 io.max 有值；ceph_c osd perf 看 osd.3 latency 飆
# 全程斷言 ceph health 保持 OK（gray 的定義）→ 回退：set-property 值設空字串
# fallback（cgroup 法無效時）：tc netem 對 OSD2 的 ceph 網卡 delay 200ms（影響整台 3 顆，記 deviation）
```

### E-33 封包遺失
```bash
# 在 VM 所在 worker 出口對 ceph subnet 加 loss（先 0.1% 後 0.5% 兩輪）：
$SSH ikaros@$NODE 'sudo tc qdisc add dev eth0 root handle 1: prio && sudo tc qdisc add dev eth0 parent 1:3 handle 30: netem loss 0.1% && sudo tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip dst 10.60.1.0/24 flowid 1:3'
# 回退：sudo tc qdisc del dev eth0 root
# 斷言注入生效：worker ping OSD 100 次丟包 ≈ 設定值
```

### E-34 flapping
```bash
for i in 1 2 3 4 5; do ceph_c orch daemon stop osd.3; sleep 60; ceph_c orch daemon start osd.3; sleep 60; done
# 輪 2 加 ceph_c osd set noout（先）→ 同 5 循環 → ceph_c osd unset noout
```

### E-35 mon 階梯（複合）
```bash
# 段1: ceph_c orch daemon stop mon.ceph-mon-2 → 觀察 5min（預期無感）→ start
# 段2: stop mon-2 + mon-3（quorum 失, ceph_c 會卡——改用預先開好的觀察: guest IO 是否照跑 5min）
#      ⚠ quorum 失後 cephadm shell 指令會 hang：所有恢復指令 = az/systemctl 層面
#        $SSH ikaros@$MON2 "sudo systemctl stop ceph-$FSID@mon.ceph-mon-2.service"（可控、可逆）
# 段3: quorum 失狀態下 $SSH ikaros@$OSD1 "sudo systemctl stop ceph-$FSID@osd.0.service"
#      → 預期打到 osd.0 的 IO 無限 hang 且無 rebalance → 恢復順序：先 mon 回 quorum → osd start → HEALTH_OK
```

### E-36 卡死邊界 × osd_request_timeout（D 類 ×3 顆盤）
```bash
# 前置：三個 SC 變體 mapOptions = "krbd:osd_request_timeout={無,30,120}" → 三顆 PVC 掛 VM（vdb/vdc/vdd）
# 找一個三顆盤都有 object 的 OSD 對：ceph_c osd map kubevirt <各image的一個object> → 選 PG acting set 重疊的 2 顆 OSD
# 注入：同時 systemctl stop 那 2 顆 OSD 的 unit（min_size=2 不滿 → 該 PG IO 全停）
# 觀察（guest 三顆盤各跑 dd/fio 小寫入）：timeout=0 盤 hang；30/120 盤在 T0+N 秒收 Input/output error
# 收 guest dmesg（hung task 出現時刻）、各盤錯誤時刻表
# 回復：start 兩顆 OSD → HEALTH_OK → 收 guest fs 狀態（mount ro? 需 remount?）→ H-010 記錄
```

### E-37 scrub 干擾
```bash
ceph_c config set osd osd_scrub_sleep 0    # 變體 B=0（激進），A=0.1
for pg in $(ceph_c pg ls-by-pool kubevirt -f json | jq -r '.pg_stats[].pgid' | head -16); do ceph_c pg deep-scrub $pg; done
# 2.2 負載對照兩個 sleep 值下的 p99；回退 config rm
```

### E-38 pool full（用調 ratio 注入，不用真填滿）
```bash
ceph_c df -f json > df-before.json                      # 記當前 raw 用量比例 R
ceph_c osd set-nearfull-ratio <R+0.02>; ceph_c osd set-full-ratio <R+0.04>
# guest 對 vdb 持續寫 → 觀察跨過 nearfull（告警）→ full（寫入 hang 而非 EIO）
# 回退：ratio 設回 0.85/0.95 → 寫入應自動恢復 → 刪測試寫入
```

### E-39 mClock degraded A/B
```bash
# 背景：E-30 的注入製造 backfill（stop osd.3 → 等 out 開始 backfill）
ceph_c config set osd osd_mclock_profile high_client_ops   # B；A=balanced
# backfill 進行中 A/B/A 各 10min，2.2 負載收 client p99 + ceph -s 的 recovery 速率（health.jsonl 內）
# 收尾：profile 回 balanced → osd.3 回 up → HEALTH_OK。加收 recovery 完成總時長對照。
```

### E-40 crash consistency
```bash
# 變體 A=cache none、B=writeback（E-10 的 patch）各重複 3 次：
guest 'sudo fio --name=vw --filename=/dev/vdb --rw=randwrite --bs=4k --iodepth=8 --verify=crc32c --verify_backlog=1024 --runtime=300 --time_based' &
sleep 60
$SSH ikaros@$NODE 'sudo kill -9 $(pgrep -f "qemu-system.*baseline")'   # 注入
kc wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s    # virt-launcher 重建
guest 'sudo fio --name=vr --filename=/dev/vdb --rw=randread --bs=4k --verify=crc32c --verify_only --verify_backlog=1024'  # 回讀驗證
# 記錄：verify 錯誤數、dmesg、每變體 3 次的結果矩陣
```

### E-41 node 硬斷 failover 預算
```bash
# 前置：VM 加 evictionStrategy: None（讓它走重建而非 migration）；確認 data PVC 是 RWX
date +%s > T0; az vm stop -g rg-kubevirt-rbd-tuning -n k8s-w-1 --skip-shutdown   # （或使用者執行）
# 時間軸收集（本機 10s 輪詢迴圈全程記錄）：
#   kc get node k8s-w-1 → NotReady 時刻
#   kc get pod -n vmtest -w → 舊 pod Terminating/新 pod Scheduled/Running 時刻
#   kc get volumeattachment -w → detach/attach 時刻
#   guest IO 恢復時刻（新 VMI Ready 後 guest 內 dd 一筆成功）
# ⚠ v1.5.0 對 node 失聯的 VMI 需要強刪：kc delete pod <老pod> -n vmtest --force --grace-period=0
#   （若卡住這就是發現——記進時間預算表）
# 回復：az vm start → node Ready → 收尾
```

### E-42 live migration 代價
```bash
# 前置：virtctl（在 K8SCP 裝 v1.5.0 的 virtctl binary，或 kc patch 觸發）：
#   virtctl migrate = kc create -f - <<EOF
#   {"apiVersion":"kubevirt.io/v1","kind":"VirtualMachineInstanceMigration","metadata":{"generateName":"mig-","namespace":"vmtest"},"spec":{"vmiName":"baseline"}}
#   EOF
# 2.2 負載中觸發 migration ×3（間隔 5min），lat log 找暫停窗；kc get vmim -w 記各階段時刻
# 子輪：cache=writeback 變體重複一次 + fio --verify 跨 migration（H-020 真機確認）
```

### E-43 控制面隔離（P3）
fio rr-qd8 全程跑；依序：`kc delete pod -n rook-ceph-external <csi-rbdplugin-on-node>`、`kc delete pod -n kubevirt <virt-handler-on-node>`、`$SSH ikaros@$NODE 'sudo systemctl stop k0sworker; sleep 60; sudo systemctl start k0sworker'`（名稱以實際 unit 為準）。斷言各段 p99 落噪音帶內。

### E-50 可調性確認：VMI 欄位
```bash
kc patch vm ... cache=writethrough（E-10 的 patch）→ 斷言 RestartRequired condition 出現
virtctl migrate（E-42 方法）→ migration 完成後 cmdline 斷言 cache 仍是 none（不變）
stop/start → cmdline 斷言 writethrough（變了）→ 回退
```

### E-51 可調性確認：mapOptions
```bash
kc patch sc rbd-rwx-block（改 mapOptions 加 queue_depth=256）→ VM stop/start → host config_info 斷言【不變】
kc patch pv <data的PV> --type=merge -p '{"spec":{"csi":{"volumeAttributes":{"mapOptions":"krbd:queue_depth=256"}}}}'
# ⚠ PV spec patch 可能被 API 拒（immutable 部分）——被拒本身就是結論，照實記錄
# 若成功：VM stop/start（確保 unstage/restage）→ config_info 斷言【變 256】
# 回退：PV 改回 + stop/start
```

### E-52 可調性確認：ceph runtime
E-21（osd_memory_target→RSS 曲線）與 E-39（profile→p99 差異）執行時已各收一份行為級證據——本實驗只需把兩份證據整理成表，不用重跑。

---

## 5. degraded 總表（E-30~38 跑完後彙整，一等產出）

`EVIDENCE-SUMMARY` 內做一張表，每情境一列：

| 情境 | 注入方式 | p99 尖峰幅度/持續 | IO 中斷? | guest 症狀(dmesg/fs) | 亮起的健康碼 | 恢復方式/自癒? | bundle |
|---|---|---|---|---|---|---|---|

健康碼欄從 health.jsonl 抽（`jq -r '.checks | keys[]'` 去重）；這張表回饋 ceph-alert 專案。

## 6. Gate 與停點（必守）

- **Gate 2 弱化版**：故障注入（E-3x）不需逐項請示；**例外**（先問使用者）：刪 mon 資料、重灌 cephadm、任何會讓環境要整組重建的操作、az 層級的 VM 刪除。
- **Gate 3**：全部實驗完成（或使用者叫停）後：更新 HYPOTHESES.md 全部 status → 產出 findings 摘要（每假設一行：verdict + 關鍵數字）→ **停下來等使用者 triage**，裁示後才寫 MDX 頁。
- **MDX 頁**（Gate 3 後）：用 `skills/source-first-topic-page/SKILL.md` 流程寫
  `next-site/content/vm-storage-perf/features/`下的新頁（工作名 `rbd-io-production-tuning`），並更新 `rbd-io-tuning-catalog` 舊頁（P0 的 violated 結論要修進去：virtio-scsi timeout 迷思、writeback 不擋 migration、osd_request_timeout 條目、CPU 層旋鈕缺口）；`projects.ts`/`feature-map.json`/`quiz.json` 檢查照該 skill。零 fabrication：每個數字對 bundle。

## 7. Commit / push（每完成一個實驗做一次）

```bash
make validate                                # 必須 exit 0
git add experiments/kubevirt-rbd-tuning/
git commit --no-gpg-sign -m "kubevirt-rbd-tuning: E-XX <一句話結果>"
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push
# results/ 不進 git（.gitignore 應含 experiments/kubevirt-rbd-tuning/results/——第一次開工時確認，沒有就加）
```

## 8. 疑難排解速查

| 症狀 | 處置 |
|---|---|
| quorum 失去後 ceph 指令 hang | 預期行為（E-35）；恢復用 systemctl 直接操作 mon unit，不要等 shell |
| VMI 起不來 | `kc describe vmi -n vmtest baseline` + virt-launcher pod events；常見=PVC pending（SC secret 名不對，回 E-00 查實際 Rook secret 名） |
| guest ssh 不通 | pod IP 會在每次 stop/start 後變，重取；cloud-init 要 ~2min |
| fio 對 /dev/vdb Permission denied | 加 sudo（runbook 內已全帶） |
| 某輪出現 recovery/backfill | 該輪作廢，等 HEALTH_OK 重跑；連續 3 次 → 停，查原因 |
| L 系列 VM 被 deallocate 過 | NVMe 已清空：OSD 全滅。照 AZURE-ENV-SPEC「重建自動化」節重建 OSD → E-00 重跑比對 snapshot |
| tc/cgroup 注入殘留 | 每個注入實驗結尾都有回退指令；懷疑殘留時 `tc qdisc show` / `systemctl show <unit> | grep IO` 檢查 |
```
