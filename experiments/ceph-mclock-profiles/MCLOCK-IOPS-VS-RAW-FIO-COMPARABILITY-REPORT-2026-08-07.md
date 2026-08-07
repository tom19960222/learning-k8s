# mClock 的 SSD IOPS 為什麼不能直接跟 SSD raw fio 比

> 讀者：熟悉基礎架構、儲存或效能測試，但不一定熟悉 Ceph 內部實作的工程師
>
> 資料期間：2026-07-26 ～ 2026-08-07
>
> 受測版本：Ceph v19.2.2；另以 v19.2.3 原始碼確認相關行為沒有改變

## 先講結論

這次看到的三個 IOPS 數字都是真的，但它們量的不是同一件事：

| 數字 | 它量的是什麼 | 適合拿來做什麼 |
|---|---|---|
| SSD raw fio：每顆 276,735～304,158 IOPS | fio 直接讀寫裸 NVMe 的裝置層能力 | 檢查硬體上限與八顆裝置是否有明顯快慢差異 |
| OSD 開機測試：每顆 6,057～6,646 IOPS | 單顆 OSD 經過 ObjectStore／BlueStore 的短時間 4 KiB 寫入測試 | 提供 mClock 計算排程成本時使用的每顆 OSD 數字 |
| RBD fio：整個 cluster 63,634 IOPS | 四台 client 經過 RBD、網路、OSD 與三副本寫入後的整體吞吐 | 決定這個 cluster 能承受多少 client 測試負載 |

因此，不能用 raw fio 除以 OSD 開機測試，宣稱差額就是 BlueStore 的效能損失；也不能因為 raw fio 比較大，就把 raw fio 的數字直接寫進 `osd_mclock_max_capacity_iops_ssd`。

比較精確的工程結論是：

- raw fio 可以當作裝置層的診斷上限，但不是 mClock 容量參數的直接答案。
- OSD 開機測試最接近 mClock 想描述的每顆 OSD 層級，但它非常短，也不等於一般 RBD 測試負載。
- RBD fio 反映完整 cluster 的 client 體驗，但它是整個 cluster 的總數，不能直接變成單顆 OSD 或單顆 SSD 的能力。
- 2026-08-07 另外在 Azure Ceph lab 重跑相同參數的 OSD bench，主要 10 筆結果介於 5,831～6,264 IOPS，中位數 6,013 IOPS。這支持「先前約 6–7K 的量級可重現」，但仍不會讓它變成 raw fio。

### 幾個後面會用到的 Ceph 名詞

- **mClock**：Ceph OSD 的 I/O 排程器。當 client I/O 與資料修復同時排隊時，它決定不同工作要先拿到多少資源，以及剩餘資源怎麼分。
- **profile**：mClock 內建的排程設定組合。每個 profile 都替不同工作類別設定最低保障（reservation）、競爭剩餘資源時的權重（weight）與上限（limit）。
- **宣告容量**：`osd_mclock_max_capacity_iops_ssd` 記錄的每顆 OSD IOPS。它是 mClock 計算排程成本時使用的輸入，不是 SSD 規格，也不是硬性限速值。

## 1. 先認識三條 I/O 路徑

### 1.1 raw fio：只測裸 NVMe

這次 raw fio 的路徑最短：

```text
fio → 裸 NVMe
```

測試在 Ceph OSD 建立前執行。fio 使用 4 KiB 隨機寫入、佇列深度 32、單一 job、`direct=1`，正式量測 60 秒，前面另有 5 秒暖身。它不經過 Ceph、不處理物件、不做副本複製，也沒有 client 到 cluster 的網路傳輸。

這個數字回答的是：「這顆空白 NVMe 在這份 fio job 下，可以完成多少次 4 KiB 寫入？」

### 1.2 OSD 開機測試：經過 Ceph 儲存層

OSD 是 Ceph 裡負責保存資料的 daemon。BlueStore 是 OSD 用來管理磁碟資料的儲存引擎，ObjectStore 則是 OSD 操作底層儲存引擎的介面。

OSD 開機測試的路徑是：

```text
OSD → ObjectStore transaction → BlueStore → NVMe
```

Ceph 先建立 100 個 4 MiB object，等待這批準備工作完成，才開始計時。計時開始後，單一程式迴圈連續排入 3,000 筆隨機 4 KiB 覆寫，全部排入後再等待寫入完成；清理測試 object 的時間也不算在內。以本次結果換算，這個計時區段每顆 OSD 約 0.45～0.50 秒。

這不是 fio job，因此沒有可直接對照的 `numjobs` 或 `iodepth`。它的提交方式是「連續排入多筆 ObjectStore 寫入，再做一次完成確認」，不能把它當成 raw fio 的單一 job、佇列深度 32。

它確實經過 BlueStore，所以不能稱為裸裝置測試；但它也沒有走一般 client request、RBD、網路、三副本寫入與 mClock 佇列。因此，它仍不等於應用程式真正使用 Ceph 時走過的完整路徑。

### 1.3 RBD fio：測完整 client 路徑

RBD 是 Ceph 提供的區塊裝置。這次四台 client 都透過 Linux kernel 裡的 RBD 驅動程式存取各自的 image：

```text
fio → kernel RBD → 網路 → primary OSD → replica OSD → BlueStore → NVMe
```

4 KiB 測試負載使用 70% 讀取、30% 寫入；每台 client 有 4 個 job，每個 job 的佇列深度是 16。pool 使用三副本，所以 client 完成一次寫入，cluster 內部還要處理 primary OSD 與 replica OSD 的工作。

校準在 cluster 健康、mClock 使用 `balanced` profile 時進行。每輪先暖身 30 秒，再量測 120 秒；三輪都不替 fio 設定 IOPS 上限，最後取中位數作為後續測試負載的校準天花板。「天花板」在本報告只代表這三輪測試的中位數，不代表硬體或 Ceph 的永久極限。

這個數字最接近應用程式看到的結果，但它同時受到 client、網路、資料分布、primary／replica 分工、BlueStore 與 NVMe 影響。它是整個 cluster 的總吞吐，不是單顆裝置測試。

## 2. 三個測試的條件並不相同

即使三個輸出都叫 IOPS，也只有在受測物與測試條件相同時，數字才可以直接互比。

| 比較項目 | SSD raw fio | OSD 開機測試 | RBD fio |
|---|---|---|---|
| 統計範圍 | 單顆 NVMe | 單顆 OSD | 八顆 OSD 組成的 cluster |
| 每次 I/O | 4 KiB 隨機寫入 | 4 KiB 隨機 overwrite | 4 KiB、70% 讀取與 30% 寫入 |
| 測試時間 | 60 秒，另有 5 秒暖身 | 約 0.45～0.50 秒；準備與清理不計時 | 三輪；每輪暖身 30 秒、量測 120 秒 |
| fio 並行度 | 1 個 job，佇列深度 32 | 不是 fio job | 共 16 個 job，每個佇列深度 16 |
| 寫入提交方式 | fio 依佇列深度送出 | 單一迴圈排入 3,000 筆，最後等待完成 | 四台 client 各自透過 RBD 送出 |
| 經過 BlueStore | 否 | 是 | 是 |
| 經過 mClock 佇列 | 否 | 否 | 是，但不是所有內部工作都一定走同一類佇列 |
| 經過 client 到 cluster 的網路 | 否 | 否 | 是 |
| 包含副本工作 | 否 | 否 | 是，pool 為三副本 |
| 主要用途 | 裝置診斷 | mClock 容量參數輸入 | 測試負載校準與 client 效能觀察 |

差異不只一項，而是受測範圍、I/O 路徑、讀寫比例、並行度與測試時間同時不同。這種情況下，就算數字相差很大，也無法把差額歸因給其中某一層。

## 3. 現有資料實際顯示什麼

### 3.1 八顆 raw NVMe

八顆裝置的 raw fio 結果如下：

| OSD node | raw fio IOPS |
|---|---:|
| `mclock-osd-1` | 304,158 |
| `mclock-osd-2` | 276,735 |
| `mclock-osd-3` | 300,842 |
| `mclock-osd-4` | 278,011 |
| `mclock-osd-5` | 303,349 |
| `mclock-osd-6` | 277,924 |
| `mclock-osd-7` | 277,790 |
| `mclock-osd-8` | 278,425 |

這組資料可以拿來比較八顆 NVMe：最低是 276,735 IOPS，最高是 304,158 IOPS，兩者相差 27,423 IOPS。本報告沒有替 raw NVMe 預先設定合格門檻，因此只陳述範圍，不把它寫成「全部相同」或「其中一顆不合格」。

它不能回答 BlueStore、OSD 或完整 cluster 最後會留下多少 IOPS，因為那些軟體層根本沒有出現在這次測試裡。

### 3.2 八顆 OSD 開機測試

| OSD | OSD 開機測試 IOPS |
|---|---:|
| `osd.0` | 6,646 |
| `osd.1` | 6,637 |
| `osd.2` | 6,507 |
| `osd.3` | 6,057 |
| `osd.4` | 6,566 |
| `osd.5` | 6,457 |
| `osd.6` | 6,226 |
| `osd.7` | 6,417 |

平均是 6,439 IOPS，最低與最高相差 589 IOPS；實驗記錄的變異係數是 3.19%，低於事前設定的 20% 裝置異質性門檻。這組結果的用途，是確認八顆 OSD 通過同一個一致性判準，避免其中一顆的排程基準明顯偏離其他 OSD。

不能把這張表與上一張表逐列相除，再把差額全部歸給 BlueStore。除了是否經過 BlueStore，兩個測試的並行度、時間與操作方式也都不同。

### 3.3 線上重跑 OSD bench：確認約 6K 可重現

2026-08-07 另外在 Azure Ceph lab 對 5 顆 SSD OSD 執行相同參數的手動 bench，每顆各跑 2 次，共 10 筆主要樣本。使用的指令參數是 12,288,000 bytes、4 KiB block、4 MiB object、100 個 object，與 OSD 開機時替 mClock 量容量所用的參數相同；原始碼也確認兩者呼叫同一個 `run_osd_bench_test()`。

| OSD | 第一次 | 第二次 | 兩次中位數 | 先前開機值 |
|---|---:|---:|---:|---:|
| `osd.0` | 6,002 | 6,027 | 6,015 | 6,646 |
| `osd.2` | 5,951 | 6,024 | 5,988 | 6,507 |
| `osd.4` | 5,903 | 5,831 | 5,867 | 6,566 |
| `osd.6` | 6,264 | 6,065 | 6,164 | 6,226 |
| `osd.7` | 5,862 | 6,141 | 6,001 | 6,417 |

這 10 筆的平均是 6,007 IOPS，中位數是 6,013 IOPS，最低與最高相差 433 IOPS。每次執行前，測試記錄都顯示 cache drop 成功；每次執行後，8 顆 OSD 都是 `up/in`，129 個 PG 都是 `active+clean`。

這批資料的價值是把「先前 6–7K 會不會只是一次偶然結果」縮小成較明確的答案：同一個 OSD bench 在不同時間重跑，仍落在約 6K IOPS。它不證明先前每顆 OSD 的精確數字永遠不變；5 顆 OSD 這次的兩次中位數，與各自先前開機值相差 62～699 IOPS。

執行工具曾把仍在進行的遠端批次誤判成停止，因此後來又留下 5 筆完整的補充結果。這 5 筆沒有混入上表與主要統計；即使納入，15 筆總範圍是 5,831～6,494 IOPS，中位數是 6,007 IOPS，仍不改變約 6K 的結論。

最重要的界線沒有改變：這次只是重跑 OSD bench，沒有補跑 raw fio，也沒有把兩種測試的時間、提交方式與 I/O 路徑對齊。因此它能驗證 OSD bench 的量級，不能量化 BlueStore 相對 raw NVMe 的成本。

### 3.4 完整 RBD client 路徑

4 KiB、70% 讀取與 30% 寫入的三輪校準結果是：

| 輪次 | 整個 cluster 的 IOPS |
|---|---:|
| 第一次 | 64,942 |
| 第二次 | 63,232 |
| 第三次 | 63,634 |

三輪的中位數是 63,634 IOPS，所以後續測試負載使用這個數字作為校準天花板。它不是挑第三輪，也不是取最高值；實驗程式在讀取結果前就固定採用三輪中位數，避免單一偏高或偏低的輪次決定後續負載。

這三個數字可以彼此比較，因為三輪使用相同的 cluster、相同的 RBD 路徑與相同測試負載。它們不能直接拿來和單顆 OSD 或單顆 NVMe 比，因為統計範圍已經不同。

## 4. mClock 容量參數不是硬性吞吐上限

`osd_mclock_max_capacity_iops_ssd` 的名稱很容易讓人以為：「設成 6,439，這顆 OSD 最多就只能跑 6,439 IOPS。」原始碼不是這樣使用它。

mClock 會把這個 IOPS 數字和宣告的連續讀寫頻寬一起使用，算出每筆小 I/O 在排程器裡至少要占多少成本。簡化成一句話：

> 宣告的 IOPS 越小，mClock 帳上每筆小 I/O 的成本越高；宣告的 IOPS 越大，每筆小 I/O 的成本越低。

接下來的關係是：

1. 宣告容量先影響每筆 I/O 在 mClock 帳上的成本。
2. profile 的 reservation 決定各類工作至少保證多少排程能力；同一份 reservation 在每筆成本變高時，可以先服務的 I/O 數量就會減少。
3. 當多類工作同時排隊，而且已超過最低保障時，weight 決定剩餘資源怎麼分。
4. limit 若有設定，才是該工作類別的上限。

本次比較的三個內建 profile，client 與 `background_recovery` 的 limit 都是 `0`；在 Ceph 這裡代表不設上限。因此，宣告容量會改變它們的排程成本與競爭時機，但不會自動把整個 OSD 或 cluster 的合計 IOPS 硬鎖在宣告數字上。其他工作類別可能有不同 limit，不能把這句話外推成「mClock 永遠不會限速」。

因此，看到 cluster 跑出超過八顆 OSD 容量參數加總的 client IOPS，不代表 Ceph 違反設定；它只再次說明這個參數是排程模型的輸入，不是實體限速器。

## 5. 哪些說法有證據，哪些沒有

| 說法 | 判斷 | 理由 |
|---|---|---|
| 八顆 raw NVMe 的裝置層結果介於 276,735～304,158 IOPS | 有證據 | 八顆使用同一份 raw fio job，可以直接橫向比較 |
| 八顆 OSD 通過事前設定的一致性門檻 | 有證據 | 變異係數 3.19%，低於 20% 門檻；最低與最高相差 589 IOPS |
| 先前約 6–7K 的 OSD bench 量級可重現 | 有證據 | 5 顆 SSD OSD 各重跑 2 次，10 筆介於 5,831～6,264 IOPS，中位數 6,013 IOPS |
| 完整 RBD 路徑的校準天花板約為 63,634 IOPS | 有證據 | 三輪相同條件分別量到 64,942、63,232、63,634 IOPS |
| raw fio 與 OSD 開機測試的差額就是 BlueStore 額外成本 | 沒有證據 | 除了 I/O 路徑，並行度、測試時間與操作方式也不同 |
| OSD 開機測試低估真正能力數十倍 | 沒有證據 | raw fio 不是同一個受測系統，不能用兩者的倍數下結論 |
| 應把 raw fio 數字直接寫進 mClock | 沒有證據 | raw fio 沒有量到每顆 OSD 的 ObjectStore／BlueStore 路徑 |
| 原本的 profile 比較因 raw fio 較高而全部失效 | 沒有證據 | 原本三個 profile 都使用同一組每顆 OSD 容量參數，沒有在 profile 間混用不同基準 |
| 原本實驗已證明 6,057～6,646 是唯一正確容量參數 | 沒有證據 | 原本所有 profile 都使用同一組容量參數，沒有隔離容量設定本身的影響 |

## 6. 對既有 mClock 實驗的影響

既有實驗比較 `balanced`、`high_client_ops` 與 `high_recovery_ops` 三個 profile。每一次比較都把八顆 OSD 的容量參數固定在 6,057～6,646 IOPS，所以 profile 之間的測試條件一致。

這代表兩件事要分開說：

第一，raw fio 比 OSD 開機測試大很多，這件事本身不足以否定原本在相同條件下做的 profile 比較。本報告沒有重新審查原 profile 實驗的重複性與判定標準，因此不在這裡替它重新下結論。

第二，因為原本沒有改變容量參數，所以它也無法回答另一個問題：「如果容量參數設得更高或更低，profile 差異會不會更明顯？」這需要固定其他條件、只改容量參數的配對測試。不能拿 raw fio 與 OSD 開機測試的現成差額代替這個實驗。

舊報告曾把 63,634 IOPS 的 cluster 總數拆回每顆 OSD，並用來說明 OSD 開機測試可能偏低。這只能當作粗略的一致性檢查：它沒有完整處理 primary／replica 工作差異、資料在 OSD 間的分布、快取、網路與不同 I/O 成本。若把這個拆算稱為「單顆 OSD 的真實能力」，結論就超過證據；本報告以較嚴格的界線取代該說法。

## 7. 現在需要補跑線上測試嗎

如果問題是「這三種 IOPS 能不能直接互比」，答案已經足夠明確：不能。原始碼、fio job 與既有結果已證明三者的量測契約不同，原本不需要為了重複證明這件事而改動線上 cluster。

另一項獨立工作已在 Azure Ceph lab 重跑手動 OSD bench。這項測試有用，因為它確認約 6K 的 OSD bench 可重現；但它不是判斷三者能否直接互比所必需的證據，也沒有改變本報告的比較界線。

而且本次 raw fio job 只允許在空白、可拋棄的裝置上執行。對仍承載有效 BlueStore 資料的裝置重跑，會直接覆寫 OSD 資料。現有工具會檢查裝置簽章、分割區、OSD 目錄與 `ceph-volume` 狀態，只要裝置仍被 Ceph 使用就拒絕執行。裝置日後若已安全移出 cluster、資料確定不再需要並完成清除，才可以重新作為空白裝置測試。

只有要回答以下新問題時，才值得另外規劃測試：

1. 同一顆裝置從 raw block 到 BlueStore，實際多出多少成本？
2. 什麼樣的持續型 OSD 路徑測試最適合校準 mClock？
3. 正式環境應該使用哪一個宣告容量？

這類測試必須使用可拋棄的空白 NVMe，並依序保存 raw 測試、建立 OSD、執行持續型 OSD 路徑測試。block size、讀寫比例、並行度、佇列深度、執行時間與 cache 狀態都要對齊，否則仍然無法把差額歸因給 Ceph 儲存層。

## 8. 工程建議

這一節提供決策原則，不是可以直接在線上執行的 runbook。若要改正式環境的容量參數，仍需另寫包含候選值、執行輪數、觀察指標、停止條件、cluster health gate 與回退步驟的實驗計畫。

| 場景 | 建議做法 | 不要做的事 |
|---|---|---|
| 驗收新 SSD | 用固定 raw fio job 比較同批裝置，找明顯異常的裝置 | 把 raw fio 當成應用程式或 OSD 吞吐 |
| 設定 mClock | 保存每顆 OSD 的容量參數、來源、時間與測試條件 | 沒有對照就直接填入 raw fio IOPS |
| 校準 client 測試負載 | 使用相同 RBD 路徑重跑多輪，直接記錄每輪 IOPS 與 p99 毫秒 | 把整個 cluster 的合計 IOPS 除以 OSD 數量後稱為單顆能力 |
| 驗證容量設定的影響 | 固定測試負載、故障條件與 profile，只改宣告容量，做配對測試 | 同時更換測試負載、硬體或 cluster 組成 |
| 撰寫報告 | 每個數字都標示「每顆裝置、每顆 OSD 或整個 cluster」 | 只寫 IOPS，不寫它的分母與 I/O 路徑 |

最安全的預設是保留 Ceph OSD 測得並經過一致性檢查的每顆 OSD 數值。若要人工覆寫，應先完成同層級、可重複的 OSD 路徑校準，並把新值當成需要驗證的設定，不要稱為硬體真值。

## 9. 侷限與尚未回答的問題

- 本報告能證明三種 IOPS 不可直接互比，但不能量化 BlueStore 的獨立成本。
- OSD 開機測試使用 OSD 內部的特殊 metadata 寫入路徑，不等於一般 RBD request 的資料路徑。
- RBD 結果同時包含 client、網路、副本寫入、資料分布與儲存層影響，不能只靠現有資料拆出每一層的成本。
- 現有結果不能指出唯一正確的正式環境 mClock 容量參數。
- Ceph 原始碼在 OSD 開機測試超出接受範圍時，會建議使用 fio 等工具另行評估；這不代表任意 raw fio job 的輸出都能直接成為 mClock 設定。新的測試仍必須對齊每顆 OSD 的受測範圍與測試條件。

## 10. 我們實際核對了什麼

| 核對項目 | 結果 |
|---|---|
| raw fio job 的 block size、讀寫方式、queue depth、job 數與時間 | 已從實驗程式確認 |
| OSD 開機測試是否經過 ObjectStore／BlueStore | 已從 Ceph v19.2.2 與 v19.2.3 原始碼確認 |
| 八顆 raw NVMe、八顆 OSD 容量參數與三輪 RBD 校準數字 | 已從本機保留的原始 JSON 重新讀取 |
| Azure lab 手動 OSD bench 的 10 筆主要樣本與 5 筆補充樣本 | 已從本機保留的 raw log 逐筆核對；主要統計只採原定 10 筆 |
| 線上重跑 raw fio | 裁定不做；目前仍承載有效 OSD 資料的裝置不可安全重跑，而且不影響本報告結論 |
| 新的容量參數配對測試 | 不屬於本報告；它回答的是容量設定是否影響 profile 差距，不是三種測試能否直接互比 |

## 附錄：證據位置

### Ceph 原始碼

- `ceph/src/osd/OSD.cc:3400-3542`：OSD bench 建立 ObjectStore transaction、寫入與等待 commit。
- `ceph/src/osd/OSD.cc:3069-3093`：手動 `osd bench` 指令呼叫相同的 `run_osd_bench_test()` 並輸出 IOPS。
- `ceph/src/osd/OSD.cc:10064-10167`：mClock 啟用條件、4 KiB 測試參數、IOPS 計算與接受範圍。
- `ceph/src/common/options/osd.yaml.in:1202-1214`：`osd_mclock_max_capacity_iops_ssd` 的 per-OSD 4 KiB random-write 定義。
- `ceph/src/osd/scheduler/mClockScheduler.cc:215-248`：容量參數如何換算成每筆 I/O 的排程成本。
- `ceph/src/osd/scheduler/mClockScheduler.cc:392-400`：request cost 與最低成本的取大邏輯。

### 實驗程式與資料

- `experiments/ceph-mclock-profiles/lib/fio.sh:1403-1432`：raw fio job 與空白裝置保護。
- `results/raw-nvme-baseline.json`：八顆 raw NVMe 結果。
- `results/capacity-lock.json`：八顆 OSD 開機測試與實際鎖定值。
- `results/calibration.json`：4 KiB RBD 三輪校準與 63,634 IOPS 天花板。
- `experiments/ceph-mclock-profiles/results/manual-osd-startup-bench-20260807T044414Z/raw.log`：5 顆 SSD OSD、每顆 2 次的 10 筆主要結果與逐次 health gate。
- `experiments/ceph-mclock-profiles/results/manual-osd-startup-bench-20260807T044414Z/valid-continuation.log`：執行工具誤判後多跑的 5 筆補充結果。

上述 `results/` 保留在原始實驗 worktree，本報告只提交可閱讀的摘要，不把大量原始資料放進 Git。
