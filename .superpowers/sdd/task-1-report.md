# Task 1 報告：Scaffold And Common Helpers

## RED

先加入 `experiments/ceph-alert-real-lab/tests/run-tests.sh` 與 `experiments/ceph-alert-real-lab/tests/test-common.sh`，再執行：

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

第一次失敗結果如下：

```text
FAIL: missing /Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
```

這證明測試確實在等 `lib/common.sh`，RED 成立。

## GREEN

補上以下檔案與目錄後，測試通過：

- `experiments/ceph-alert-real-lab/.gitignore`
- `experiments/ceph-alert-real-lab/lib/common.sh`
- `experiments/ceph-alert-real-lab/README.md`
- `experiments/ceph-alert-real-lab/results/.gitkeep`
- `experiments/ceph-alert-real-lab/rendered/.gitkeep`
- `experiments/ceph-alert-real-lab/run/.gitkeep`

完成後重新執行：

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

通過結果：

```text
[2026-07-04T03:02:00Z] PASS: counter reaches 2
ok: common helpers
ok: unit tests
```

另外也跑了：

```bash
shellcheck -x experiments/ceph-alert-real-lab/lib/common.sh experiments/ceph-alert-real-lab/tests/run-tests.sh experiments/ceph-alert-real-lab/tests/test-common.sh
make validate
```

兩者都成功。

## Files Changed

- `experiments/ceph-alert-real-lab/.gitignore`
- `experiments/ceph-alert-real-lab/lib/common.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`
- `experiments/ceph-alert-real-lab/tests/test-common.sh`
- `experiments/ceph-alert-real-lab/README.md`
- `experiments/ceph-alert-real-lab/results/.gitkeep`
- `experiments/ceph-alert-real-lab/rendered/.gitkeep`
- `experiments/ceph-alert-real-lab/run/.gitkeep`

## Fix Review Findings

### RED

1. `new_result_dir` collision proof against the parent commit:

```bash
bash -lc 'tmp=$(mktemp); git show HEAD:experiments/ceph-alert-real-lab/lib/common.sh >"$tmp"; source "$tmp"; result_dir=$(new_result_dir smoke); second_result_dir=$(new_result_dir smoke); if [[ "$result_dir" == "$second_result_dir" ]]; then printf "FAIL: new_result_dir returned the same path twice\n" >&2; exit 1; fi'
```

Output:

```text
FAIL: new_result_dir returned the same path twice
```

2. `run_capture` with only an output path against the parent commit:

```bash
bash -lc 'tmp=$(mktemp); git show HEAD:experiments/ceph-alert-real-lab/lib/common.sh >"$tmp"; source "$tmp"; capture_file=$(mktemp); capture_err_file=$(mktemp); run_capture "$capture_file" 2>"$capture_err_file"; status=$?; printf "STATUS=%s\n" "$status"; printf "FILE:\n"; cat "$capture_file"; printf "ERR:\n"; cat "$capture_err_file"'
```

Output:

```text
STATUS=0
FILE:
# started: 2026-07-04T03:10:37Z
# command: ''

# ended: 2026-07-04T03:10:37Z
# exit_code: 0
ERR:
```

### GREEN

After the fixes, the focused helper test passes:

```bash
bash experiments/ceph-alert-real-lab/tests/test-common.sh
```

Output:

```text
[2026-07-04T03:08:52Z] PASS: counter reaches 2
ok: common helpers
```

And the repo gates pass:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/common.sh experiments/ceph-alert-real-lab/tests/run-tests.sh experiments/ceph-alert-real-lab/tests/test-common.sh
make validate
```

Outputs:

```text
[2026-07-04T03:09:04Z] PASS: counter reaches 2
ok: common helpers
ok: unit tests
```

```text
<shellcheck produced no output and exited 0>
```

```text
==================================================
  Summary
==================================================

  ✓ All checks passed!
```

Task 1 only ran shellcheck on its actual `.sh` files. The exact `shellcheck -x ... run/*.sh` gate becomes applicable once Task 2 adds real run scripts under `experiments/ceph-alert-real-lab/run/`.

## Self-review

- `lab_root` 回傳實驗目錄根目錄，與測試預期一致。
- `new_result_dir` 會在 `results/` 下建立帶時間戳的目錄。
- `ssh_base_opts` 以逐個 argv 項目輸出，符合 Bash 與 SSH 參數拆分要求。
- `run_capture` 同時保留 stdout、stderr 與 exit code。
- `poll_until` 會重試直到成功或逾時，並保留狀態訊息到 stderr。
- `README.md` 只放 scaffold 階段能確定的安全界線與建議順序，沒有塞進未驗證的行為。

## Concerns

- `require_destructive_ack` 在被 `source` 進來的測試環境中使用 `return 2`，而不是 `exit 2`，這樣測試才能接住失敗狀態並繼續跑後續斷言；對呼叫端來說仍然是失敗碼 2。
