# ceph-mon-quorum-blind-spot

研究：3-mon Ceph 停 2 顆（quorum 失守）時，(A) `CephMonQuorumLost` 為何不 fire、如何用純
Prometheus metrics 偵測；(B) client IO（single/multi × random/seq）具體受什麼影響。真機實證
（cephadm v19.2.3 + k0s/Rook，2026-07-08）。

## 入口
- **[REPORT.md](./REPORT.md)** — 結論、根因、方案比較、推薦、IO 衝擊、規則草案（讀這份）。
- [HYPOTHESES.md](./HYPOTHESES.md) — Frame→Enumerate 的 backlog + 各 H 判定。

## 結構
| 路徑 | 內容 |
|---|---|
| `manifests/monitoring.yaml` | Prometheus(NodePort 30090)+blackbox 探 mon:3300+候選規則（可套用） |
| `manifests/io-preconn.yaml` / `io-newclient.yaml` | Thread B：已連線 / 新連線 client |
| `scenarios/mon-quorum-2down.sh` | 注入情境（inject→observe→collect→**trap 保證 rollback**→assert） |
| `scenarios/fio-matrix.sh` | fio 矩陣 runner（random/seq × 1/4 thread，跑在 k8s 節點） |
| `rules/ceph-mon-quorum-blackbox.yml` | **推薦規則草案**（blackbox 偵測 + 守門） |
| `tests/mon-quorum-blackbox.test.yml` | promtool 測試（含 mgr-盲 vs blackbox-fire 頭條對照，SUCCESS） |
| `results/` | 真機 evidence bundle（含 baseline + run 20260708T154019Z） |

## 一句話
偵測盲區的根因是「sensor（mgr metric）與被測物（quorum）同生共死」——修不在 PromQL，在資料
來源：加 blackbox 探 mon port（唯一不經 mgr、逐 mon 獨立又免 per-host agent 的方案）。IO 衝擊
＝「已連線者無感、新建 mon 連線者（krbd map）阻塞」。

> lab 復原：機器重開 IP 會漂移、mon 綁不到舊 monmap IP 而 crash。修法見 memory `project-ceph-lab-cluster`
> 與 REPORT §1.3（各 mon host ens18 補回舊 IP 當 secondary）。
