# Task 3 報告：Evidence Collection Helpers

## 目標

為 `experiments/ceph-alert-real-lab` 補上 evidence collection helper，提供 baseline / postcheck 收集與 Ceph health check assertion，並保留本地可跑的 smoke / syntax / lint 驗證。

## RED 證據

先依 TDD 加入 `tests/run-tests.sh` 的檔案存在檢查：

```bash
[[ -f "$ROOT/lib/evidence.sh" ]] || fail "missing $ROOT/lib/evidence.sh"
```

執行：

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

結果：

```text
FAIL: missing /Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/evidence.sh
```

## GREEN 證據

實作後完成以下驗證：

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/lib/evidence.sh experiments/ceph-alert-real-lab/run/baseline.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

結果摘要：

- `tests/run-tests.sh`：PASS
- `bash -n ...`：PASS
- `shellcheck -x ...`：PASS
- `make validate`：PASS

## Fix Review Findings

### What I fixed

- Removed the capture suppression from `assert_ceph_health_check` so a failed Ceph health query now returns immediately instead of falling through to the grep.
- Kept the literal health-name match as fixed-string grep with `grep -Fq --`.
- Added a focused local regression test that overrides `ceph_seed_cmd` in shell to simulate both success and failure without live SSH.

### RED evidence

Command:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Output:

```text
[2026-07-04T03:30:56Z] PASS: counter reaches 2
ok: common helpers
FAIL: assert_ceph_health_check should fail when ceph_seed_cmd fails
```

### GREEN evidence

Command:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/lib/evidence.sh experiments/ceph-alert-real-lab/run/baseline.sh experiments/ceph-alert-real-lab/tests/test-evidence.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

Output:

```text
[2026-07-04T03:31:59Z] PASS: counter reaches 2
ok: common helpers
ok: evidence helpers
ok: monitoring manifest render
ok: unit tests
```

`bash -n`, `shellcheck`, and `make validate` all exited 0.

`make validate` 內容包含：

- MDX frontmatter 驗證
- 圖片引用驗證
- QuizQuestion syntax 驗證
- quiz.json 驗證
- `projects.ts` 對應檢查
- Next.js build 與 `/learning-k8s` basePath 驗證

## 變更檔案

- `experiments/ceph-alert-real-lab/lib/evidence.sh`
- `experiments/ceph-alert-real-lab/run/baseline.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`

## 自我檢查

- Bash 3.2 相容：未使用 `mapfile`、nameref、process substitution 以外的新版語法
- 沒有執行真實 lab 的 `ssh` / `kubectl` / `curl` evidence collection
- 沒有加入破壞性 cluster 指令
- 沒有碰 `linux` submodule
- `baseline.sh` 只負責初始化結果目錄與呼叫 `collect_baseline`
- `evidence.sh` 只提供 helper，不直接觸發真實環境操作

## 風險與注意事項

- 這次只做本地驗證；`collect_baseline` / `collect_postcheck` / `assert_ceph_health_check` 尚未在真 lab 上跑過
- `assert_ceph_health_check` 目前以 `ceph health detail` 的輸出內容做 literal grep，符合目前 Task 3 需求，但未額外擴充比對邏輯
