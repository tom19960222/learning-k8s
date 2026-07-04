# Ceph Alert Real Lab Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repo-native harness that deploys a temporary Prometheus + Alertmanager stack on `ceph-lab-k8s`, injects realistic Ceph faults, captures evidence, rolls back every fault, and proves `CephClientBlocked` plus `CephMonQuorumLost` reach the pager receiver.

**Architecture:** Add a new `experiments/ceph-alert-real-lab/` experiment. The harness is split into small Bash libraries for shared config, monitoring stack rendering, evidence capture, and scenario command generation; destructive scenario scripts call those libraries with explicit confirmation flags and write timestamped results. Unit tests use fake `ssh`, `kubectl`, `curl`, and `ceph` commands to verify generated commands and rollback behavior without touching the real lab.

**Tech Stack:** Bash 3.2-compatible shell, kubectl against `/Users/ikaros/.kube/ceph-lab-k8s.kubeconfig`, cephadm-managed Ceph v19.2.3, k0s/Rook external lab, Prometheus container `prom/prometheus:v3.2.1`, Alertmanager container `prom/alertmanager:v0.28.1`, Python 3 alert sink, `jq`, `shellcheck`.

## Global Constraints

- All zh content must be Traditional Chinese using Taiwan terms.
- Keep Kubernetes terms from the never-translate list in English: `node`, `cluster`, `controller`, `namespace`, `container`, `image`, `workload`, `label`, `Pod`, `Deployment`, `Service`, `ConfigMap`, `Secret`.
- Do not import MDX components; this plan does not add MDX content.
- Do not use Mermaid; no diagrams are needed.
- macOS Bash is 3.2: do not use `mapfile`, nameref, associative arrays, or unsafe empty-array expansion under `set -u`.
- macOS may not have `timeout` or `gtimeout`; scripts must poll with shell loops and print a clear warning if no timeout binary exists.
- SSH commands must pass flags as separate argv items, not one expanded options string.
- Destructive real lab operations require an explicit `--yes-really-inject` flag.
- Do not delegate destructive cluster changes to a background subagent.
- Commit gate remains `bash experiments/ceph-alert-real-lab/tests/run-tests.sh`, `shellcheck experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh`, and `make validate`.
- The existing dirty `linux` submodule must remain untouched.

---

## File Structure

- Create `experiments/ceph-alert-real-lab/.gitignore`: ignore generated results and rendered manifests.
- Create `experiments/ceph-alert-real-lab/README.md`: operator-facing runbook with safety notes, prerequisites, scenario order, and pass/fail evidence.
- Create `experiments/ceph-alert-real-lab/lib/common.sh`: shared constants, SSH argv helper, command capture, destructive confirmation, polling, and result directory helpers.
- Create `experiments/ceph-alert-real-lab/lib/monitoring.sh`: render/apply/delete temporary k8s monitoring stack and query Prometheus / Alertmanager / sink logs.
- Create `experiments/ceph-alert-real-lab/lib/evidence.sh`: collect baseline and post-check evidence from Ceph, Rook, Prometheus, and alert sink.
- Create `experiments/ceph-alert-real-lab/lib/scenarios.sh`: pure command-generation helpers for pool creation, cgroup I/O throttle, OSD stop/start, mon stop/start, and cleanup.
- Create `experiments/ceph-alert-real-lab/run/deploy-monitoring.sh`: deploy `ceph-alert-lab` namespace and wait for readiness.
- Create `experiments/ceph-alert-real-lab/run/baseline.sh`: collect non-destructive baseline evidence.
- Create `experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh`: inject realistic disk I/O slowness via cgroup v2 `io.max`, observe `CephClientBlocked{name="SLOW_OPS"}`, then roll back.
- Create `experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh`: stop acting OSD daemons for a test pool PG, observe `CephClientBlocked{name="PG_AVAILABILITY"}`, then roll back.
- Create `experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh`: stop two mon daemons, observe `CephMonQuorumLost`, then roll back.
- Create `experiments/ceph-alert-real-lab/run/cleanup.sh`: best-effort cleanup for monitoring stack, test pools, cgroup limits, debug options, and stopped daemons.
- Create `experiments/ceph-alert-real-lab/run/all.sh`: guarded orchestrator for the full sequence.
- Create `experiments/ceph-alert-real-lab/tests/run-tests.sh`: local unit-test gate.
- Create `experiments/ceph-alert-real-lab/tests/test-common.sh`: common helper tests.
- Create `experiments/ceph-alert-real-lab/tests/test-monitoring-render.sh`: rendered manifest and routing tests.
- Create `experiments/ceph-alert-real-lab/tests/test-scenario-commands.sh`: command generation and rollback order tests.

### Interfaces

- `common.sh`
  - `lab_root() -> string`
  - `new_result_dir(scenario: string) -> string`
  - `ssh_base_opts(ssh_key: string, timeout_seconds: string) -> newline-separated argv`
  - `require_destructive_ack(args...) -> 0 or exit 2`
  - `run_capture(output_file: string, command...) -> command exit code`
  - `poll_until(description: string, attempts: int, sleep_seconds: int, command...) -> 0 or 1`
- `monitoring.sh`
  - `render_monitoring_manifest(output_file: string) -> writes YAML`
  - `apply_monitoring_stack() -> kubectl apply`
  - `delete_monitoring_stack() -> kubectl delete namespace ceph-alert-lab`
  - `prometheus_query(query: string) -> JSON`
  - `wait_prometheus_alert(alertname: string, label_name: string, label_value: string, result_dir: string) -> 0 or 1`
  - `wait_sink_alert(receiver: string, alertname: string, label_name: string, label_value: string, result_dir: string) -> 0 or 1`
- `evidence.sh`
  - `collect_baseline(result_dir: string) -> files`
  - `collect_postcheck(result_dir: string) -> files`
  - `assert_ceph_health_check(check_name: string, result_dir: string) -> 0 or 1`
- `scenarios.sh`
  - `pool_create_commands(pool: string) -> newline-separated commands`
  - `pool_cleanup_commands(pool: string) -> newline-separated commands`
  - `osd_service_name(fsid: string, osd_id: string) -> string`
  - `mon_service_name(fsid: string, mon_name: string) -> string`
  - `cgroup_io_max_path(fsid: string, osd_id: string) -> string`
  - `io_throttle_command(major_minor: string, bytes_per_second: string, io_max_path: string) -> string`
  - `io_unthrottle_command(major_minor: string, io_max_path: string) -> string`

---

### Task 1: Scaffold And Common Helpers

**Files:**
- Create: `experiments/ceph-alert-real-lab/.gitignore`
- Create: `experiments/ceph-alert-real-lab/lib/common.sh`
- Create: `experiments/ceph-alert-real-lab/tests/run-tests.sh`
- Create: `experiments/ceph-alert-real-lab/tests/test-common.sh`
- Create: `experiments/ceph-alert-real-lab/README.md`

**Interfaces:**
- Consumes: none.
- Produces: `lab_root`, `new_result_dir`, `ssh_base_opts`, `require_destructive_ack`, `run_capture`, and `poll_until` for all later tasks.

- [ ] **Step 1: Write the failing common-helper tests**

Create `experiments/ceph-alert-real-lab/tests/test-common.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

root="$(lab_root)"
[[ "$root" == "$ROOT" ]] || fail "lab_root should be $ROOT, got $root"

result_dir="$(new_result_dir smoke)"
[[ -d "$result_dir" ]] || fail "new_result_dir did not create directory"
[[ "$result_dir" == "$ROOT/results/smoke-"* ]] || fail "unexpected result dir: $result_dir"

opts_file="$(mktemp)"
ssh_base_opts "$ROOT/test-key" 7 >"$opts_file"
grep -qx -- '-i' "$opts_file" || fail "ssh opts missing -i"
grep -qx -- "$ROOT/test-key" "$opts_file" || fail "ssh opts missing key path"
grep -qx -- '-o' "$opts_file" || fail "ssh opts missing -o entries"
grep -qx -- 'IdentitiesOnly=yes' "$opts_file" || fail "ssh opts missing IdentitiesOnly"
grep -qx -- 'IdentityAgent=none' "$opts_file" || fail "ssh opts missing IdentityAgent"
grep -qx -- 'ConnectTimeout=7' "$opts_file" || fail "ssh opts missing ConnectTimeout"

if require_destructive_ack scenario-name >/tmp/ack.out 2>/tmp/ack.err; then
  fail "require_destructive_ack should fail without --yes-really-inject"
fi
grep -q 'requires --yes-really-inject' /tmp/ack.err || fail "ack failure message missing"
require_destructive_ack scenario-name --yes-really-inject

capture_file="$(mktemp)"
if ! run_capture "$capture_file" bash -c 'printf stdout-line; printf stderr-line >&2'; then
  fail "run_capture should return success"
fi
grep -q 'stdout-line' "$capture_file" || fail "run_capture missed stdout"
grep -q 'stderr-line' "$capture_file" || fail "run_capture missed stderr"
grep -q '# exit_code: 0' "$capture_file" || fail "run_capture did not record exit code"

attempt_file="$(mktemp)"
printf 0 >"$attempt_file"
poll_until "counter reaches 2" 5 0 bash -c 'n=$(cat "$1"); n=$((n+1)); printf "%s" "$n" >"$1"; test "$n" -ge 2' _ "$attempt_file"
[[ "$(cat "$attempt_file")" == "2" ]] || fail "poll_until did not retry until success"

ok "common helpers"
```

Create `experiments/ceph-alert-real-lab/tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

for path in \
  "$ROOT/lib/common.sh" \
  "$ROOT/tests/test-common.sh"; do
  [[ -f "$path" ]] || fail "missing $path"
done

bash "$ROOT/tests/test-common.sh"
ok "unit tests"
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Expected: FAIL with `missing .../lib/common.sh`.

- [ ] **Step 3: Implement common helpers**

Create `experiments/ceph-alert-real-lab/.gitignore`:

```gitignore
results/*
!results/.gitkeep
rendered/*
!rendered/.gitkeep
```

Create directories:

```bash
mkdir -p experiments/ceph-alert-real-lab/{lib,run,tests,results,rendered}
touch experiments/ceph-alert-real-lab/results/.gitkeep
touch experiments/ceph-alert-real-lab/rendered/.gitkeep
```

Create `experiments/ceph-alert-real-lab/lib/common.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

LAB_NAMESPACE="${LAB_NAMESPACE:-ceph-alert-lab}"
LAB_KUBECONFIG="${LAB_KUBECONFIG:-/Users/ikaros/.kube/ceph-lab-k8s.kubeconfig}"
LAB_SSH_KEY="${LAB_SSH_KEY:-/Users/ikaros/Documents/code/learning-k8s/.ssh/id_ed25519}"
LAB_SSH_USER="${LAB_SSH_USER:-ikaros}"
LAB_FSID="${LAB_FSID:-0c9bf37e-514a-11f1-b72a-bc24113f1375}"
LAB_MGR_ENDPOINT="${LAB_MGR_ENDPOINT:-http://192.168.18.167:9283}"
LAB_MON_01_HOST="${LAB_MON_01_HOST:-192.168.18.166}"
LAB_MON_02_HOST="${LAB_MON_02_HOST:-192.168.18.167}"
LAB_MON_03_HOST="${LAB_MON_03_HOST:-192.168.18.164}"
LAB_MON_01_NAME="${LAB_MON_01_NAME:-ceph-lab-mon-01}"
LAB_MON_02_NAME="${LAB_MON_02_NAME:-ceph-lab-mon-02}"
LAB_MON_03_NAME="${LAB_MON_03_NAME:-ceph-lab-mon-03}"
LAB_OSD_01_HOST="${LAB_OSD_01_HOST:-192.168.18.169}"
LAB_OSD_02_HOST="${LAB_OSD_02_HOST:-192.168.18.171}"
LAB_OSD_03_HOST="${LAB_OSD_03_HOST:-192.168.18.174}"
LAB_TIMEOUT="${LAB_TIMEOUT:-10}"

lab_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

die() {
  log "FATAL: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

new_result_dir() {
  local scenario=$1 root stamp dir
  root="$(lab_root)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$root/results/${scenario}-${stamp}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

ssh_base_opts() {
  local ssh_key=$1 timeout_seconds=$2
  printf '%s\n' \
    -i "$ssh_key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o LogLevel=ERROR \
    -o "ConnectTimeout=$timeout_seconds" \
    -o "ServerAliveInterval=$timeout_seconds" \
    -o ServerAliveCountMax=1 \
    -o StrictHostKeyChecking=accept-new
}

require_destructive_ack() {
  local scenario=$1
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--yes-really-inject" ]]; then
      return 0
    fi
  done
  printf '%s requires --yes-really-inject\n' "$scenario" >&2
  exit 2
}

run_capture() {
  local output_file=$1
  shift
  local started ended rc
  started="$(date -u +%FT%TZ)"
  {
    printf '# started: %s\n' "$started"
    printf '# command:'
    printf ' %q' "$@"
    printf '\n'
  } >"$output_file"
  set +e
  "$@" >>"$output_file" 2>&1
  rc=$?
  set -e
  ended="$(date -u +%FT%TZ)"
  {
    printf '\n# ended: %s\n' "$ended"
    printf '# exit_code: %s\n' "$rc"
  } >>"$output_file"
  return "$rc"
}

poll_until() {
  local description=$1 attempts=$2 sleep_seconds=$3
  shift 3
  local i
  i=1
  while [[ "$i" -le "$attempts" ]]; do
    if "$@"; then
      log "PASS: $description"
      return 0
    fi
    if [[ "$sleep_seconds" -gt 0 ]]; then
      sleep "$sleep_seconds"
    fi
    i=$((i + 1))
  done
  log "TIMEOUT: $description"
  return 1
}

kubectl_lab() {
  KUBECONFIG="$LAB_KUBECONFIG" kubectl "$@"
}

ssh_lab() {
  local host=$1
  shift
  local -a opts
  local opt
  while IFS= read -r opt; do
    opts+=("$opt")
  done < <(ssh_base_opts "$LAB_SSH_KEY" "$LAB_TIMEOUT")
  ssh "${opts[@]}" "${LAB_SSH_USER}@${host}" "$@"
}
```

Create `experiments/ceph-alert-real-lab/README.md`:

````markdown
# Ceph Alert Real Lab

這個 harness 會在隔離 lab 裡製造真實 Ceph 故障，驗證 `prometheus-alert-design` 的 `CephClientBlocked` 與 `CephMonQuorumLost` 是否真的 firing 並送到 Alertmanager pager receiver。

## 安全界線

- 每個注入腳本都需要 `--yes-really-inject`。
- 先跑 `run/deploy-monitoring.sh` 與 `run/baseline.sh`。
- 每個情境完成後都要確認 Ceph 回到 `HEALTH_OK` 再跑下一個。
- 不要在非 lab 環境執行。

## 建議順序

```bash
bash experiments/ceph-alert-real-lab/run/deploy-monitoring.sh
bash experiments/ceph-alert-real-lab/run/baseline.sh
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/cleanup.sh
```
````

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Expected: output contains `ok: common helpers` and exits 0.

- [ ] **Step 5: Commit**

Run:

```bash
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add Ceph alert real lab harness scaffold"
```

Expected: commit succeeds.

---

### Task 2: Monitoring Stack Rendering And Deployment

**Files:**
- Create: `experiments/ceph-alert-real-lab/lib/monitoring.sh`
- Create: `experiments/ceph-alert-real-lab/run/deploy-monitoring.sh`
- Create: `experiments/ceph-alert-real-lab/run/cleanup.sh`
- Create: `experiments/ceph-alert-real-lab/tests/test-monitoring-render.sh`
- Modify: `experiments/ceph-alert-real-lab/tests/run-tests.sh`

**Interfaces:**
- Consumes: `kubectl_lab`, `LAB_NAMESPACE`, `LAB_MGR_ENDPOINT`, `lab_root`.
- Produces: `render_monitoring_manifest`, `apply_monitoring_stack`, `delete_monitoring_stack`, `prometheus_query`, `wait_prometheus_alert`, `wait_sink_alert`.

- [ ] **Step 1: Write the failing monitoring render test**

Create `experiments/ceph-alert-real-lab/tests/test-monitoring-render.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

out="$(mktemp)"
render_monitoring_manifest "$out"

grep -q 'name: ceph-alert-lab' "$out" || fail "namespace missing"
grep -q 'prom/prometheus:v3.2.1' "$out" || fail "Prometheus image missing"
grep -q 'prom/alertmanager:v0.28.1' "$out" || fail "Alertmanager image missing"
grep -q 'python:3.12-alpine' "$out" || fail "alert sink image missing"
grep -q '192.168.18.167:9283' "$out" || fail "mgr scrape target missing"
grep -q 'alertname=~\"CephClientBlocked|CephClientRisk|CephMonQuorumLost|CephExporterDown|CephOSDHostDownScoped|CephOSDDaemonDownScoped|CephMonDownScoped\"' "$out" || fail "pager route matcher missing"
grep -q 'CephClientBlocked' "$out" || fail "CephClientBlocked rule missing"
grep -q 'CephMonQuorumLost' "$out" || fail "CephMonQuorumLost rule missing"

ok "monitoring manifest render"
```

Modify `experiments/ceph-alert-real-lab/tests/run-tests.sh` so it includes:

```bash
for path in \
  "$ROOT/lib/common.sh" \
  "$ROOT/lib/monitoring.sh" \
  "$ROOT/tests/test-common.sh" \
  "$ROOT/tests/test-monitoring-render.sh"; do
  [[ -f "$path" ]] || fail "missing $path"
done

bash "$ROOT/tests/test-common.sh"
bash "$ROOT/tests/test-monitoring-render.sh"
ok "unit tests"
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Expected: FAIL with `missing .../lib/monitoring.sh`.

- [ ] **Step 3: Implement monitoring rendering and deployment**

Create `experiments/ceph-alert-real-lab/lib/monitoring.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

render_monitoring_manifest() {
  local output_file=$1 root rules route
  root="$(lab_root)"
  rules="$root/../ceph-alert-rules/rules/ceph-stability-first.yml"
  route="$root/../ceph-alert-rules/rules/alertmanager-route.yml"
  [[ -f "$rules" ]] || die "missing rules file: $rules"
  [[ -f "$route" ]] || die "missing route file: $route"

  {
    cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_NAMESPACE}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-alert-rules
  namespace: ${LAB_NAMESPACE}
data:
  ceph-stability-first.yml: |
YAML
    sed 's/^/    /' "$rules"
    cat <<YAML
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-sink
  namespace: ${LAB_NAMESPACE}
data:
  alert-sink.py: |
    import json
    import sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            payload = json.loads(body.decode("utf-8"))
            receiver = self.path.strip("/") or "unknown"
            for alert in payload.get("alerts", []):
                labels = alert.get("labels", {})
                row = {
                    "receiver": receiver,
                    "alertname": labels.get("alertname", ""),
                    "name": labels.get("name", ""),
                    "source": labels.get("source", ""),
                    "severity": labels.get("severity", ""),
                    "labels": labels,
                }
                print(json.dumps(row, sort_keys=True), flush=True)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, fmt, *args):
            return

    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: ${LAB_NAMESPACE}
data:
  prometheus.yml: |
    global:
      scrape_interval: 5s
      evaluation_interval: 5s
    rule_files:
      - /etc/prometheus/rules/ceph-stability-first.yml
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
                - alertmanager.${LAB_NAMESPACE}.svc.cluster.local:9093
    scrape_configs:
      - job_name: ceph
        static_configs:
          - targets:
              - "${LAB_MGR_ENDPOINT#http://}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: ${LAB_NAMESPACE}
data:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
    route:
      receiver: slack-ceph
      group_by: ['alertname', 'name', 'hostname', 'ceph_daemon']
      group_wait: 0s
      group_interval: 5s
      repeat_interval: 30m
      routes:
        - receiver: pager-ceph
          group_wait: 0s
          matchers:
            - type="ceph_default"
            - alertname="CephHealthError"
        - receiver: pager-ceph
          group_wait: 0s
          matchers:
            - alertname=~"CephClientBlocked|CephClientRisk|CephMonQuorumLost|CephExporterDown|CephOSDHostDownScoped|CephOSDDaemonDownScoped|CephMonDownScoped"
        - receiver: slack-ceph
          matchers:
            - alertname="CephLowPriorityNotice"
        - receiver: slack-ceph
          matchers:
            - type="ceph_default"
    receivers:
      - name: slack-ceph
        webhook_configs:
          - url: http://alert-sink.${LAB_NAMESPACE}.svc.cluster.local:8080/slack
      - name: pager-ceph
        webhook_configs:
          - url: http://alert-sink.${LAB_NAMESPACE}.svc.cluster.local:8080/pager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alert-sink
  namespace: ${LAB_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alert-sink
  template:
    metadata:
      labels:
        app: alert-sink
    spec:
      containers:
        - name: alert-sink
          image: python:3.12-alpine
          command: ["python", "/app/alert-sink.py"]
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: alert-sink
---
apiVersion: v1
kind: Service
metadata:
  name: alert-sink
  namespace: ${LAB_NAMESPACE}
spec:
  selector:
    app: alert-sink
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${LAB_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v3.2.1
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --web.enable-lifecycle
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: rules
              mountPath: /etc/prometheus/rules
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: rules
          configMap:
            name: ceph-alert-rules
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: ${LAB_NAMESPACE}
spec:
  selector:
    app: prometheus
  ports:
    - name: http
      port: 9090
      targetPort: 9090
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: ${LAB_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alertmanager
  template:
    metadata:
      labels:
        app: alertmanager
    spec:
      containers:
        - name: alertmanager
          image: prom/alertmanager:v0.28.1
          args:
            - --config.file=/etc/alertmanager/alertmanager.yml
            - --storage.path=/alertmanager
            - --cluster.listen-address=
          ports:
            - containerPort: 9093
          volumeMounts:
            - name: config
              mountPath: /etc/alertmanager
      volumes:
        - name: config
          configMap:
            name: alertmanager-config
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: ${LAB_NAMESPACE}
spec:
  selector:
    app: alertmanager
  ports:
    - name: http
      port: 9093
      targetPort: 9093
YAML
  } >"$output_file"
}

apply_monitoring_stack() {
  local root manifest
  root="$(lab_root)"
  manifest="$root/rendered/monitoring.yaml"
  mkdir -p "$root/rendered"
  render_monitoring_manifest "$manifest"
  kubectl_lab apply -f "$manifest"
  kubectl_lab -n "$LAB_NAMESPACE" rollout status deploy/alert-sink --timeout=180s
  kubectl_lab -n "$LAB_NAMESPACE" rollout status deploy/prometheus --timeout=180s
  kubectl_lab -n "$LAB_NAMESPACE" rollout status deploy/alertmanager --timeout=180s
}

delete_monitoring_stack() {
  kubectl_lab delete namespace "$LAB_NAMESPACE" --ignore-not-found=true
}

prometheus_query() {
  local query=$1 pod
  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')"
  kubectl_lab -n "$LAB_NAMESPACE" exec "$pod" -- wget -qO- "http://127.0.0.1:9090/api/v1/query?query=${query}"
}

wait_prometheus_alert() {
  local alertname=$1 label_name=$2 label_value=$3 result_dir=$4 pod output
  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')"
  poll_until "Prometheus alert $alertname $label_name=$label_value firing" 60 5 bash -c '
    out="$(kubectl "$@" exec "$0" -- wget -qO- http://127.0.0.1:9090/api/v1/alerts)"
    printf "%s\n" "$out" >"$1/prometheus-alerts-$2-$3.json"
    printf "%s\n" "$out" | jq -e --arg an "$2" --arg ln "$3" --arg lv "$4" '"'"'.data.alerts[] | select(.labels.alertname==$an) | select(($ln=="") or (.labels[$ln]==$lv)) | select(.state=="firing")'"'"' >/dev/null
  ' "$pod" "$result_dir" "$alertname" "$label_name" "$label_value" --kubeconfig "$LAB_KUBECONFIG" -n "$LAB_NAMESPACE"
}

wait_sink_alert() {
  local receiver=$1 alertname=$2 label_name=$3 label_value=$4 result_dir=$5
  poll_until "sink $receiver received $alertname $label_name=$label_value" 60 5 bash -c '
    logs="$(kubectl --kubeconfig "$0" -n "$1" logs deploy/alert-sink)"
    printf "%s\n" "$logs" >"$2/sink.log"
    printf "%s\n" "$logs" | jq -r . 2>/dev/null | jq -e --arg r "$3" --arg an "$4" --arg ln "$5" --arg lv "$6" '"'"'select(.receiver==$r) | select(.alertname==$an) | select(($ln=="") or (.labels[$ln]==$lv))'"'"' >/dev/null
  ' "$LAB_KUBECONFIG" "$LAB_NAMESPACE" "$result_dir" "$receiver" "$alertname" "$label_name" "$label_value"
}
```

Create `experiments/ceph-alert-real-lab/run/deploy-monitoring.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"

require_cmd kubectl
apply_monitoring_stack
log "monitoring stack ready in namespace $LAB_NAMESPACE"
```

Create `experiments/ceph-alert-real-lab/run/cleanup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"

delete_monitoring_stack
log "deleted monitoring namespace $LAB_NAMESPACE"
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Expected: output contains `ok: monitoring manifest render` and exits 0.

- [ ] **Step 5: Make run scripts executable and commit**

Run:

```bash
chmod +x experiments/ceph-alert-real-lab/run/deploy-monitoring.sh experiments/ceph-alert-real-lab/run/cleanup.sh
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add Ceph alert lab monitoring stack"
```

Expected: tests pass and commit succeeds.

---

### Task 3: Evidence Collection Helpers

**Files:**
- Create: `experiments/ceph-alert-real-lab/lib/evidence.sh`
- Create: `experiments/ceph-alert-real-lab/run/baseline.sh`
- Modify: `experiments/ceph-alert-real-lab/tests/run-tests.sh`

**Interfaces:**
- Consumes: `run_capture`, `ssh_lab`, `kubectl_lab`, `LAB_MGR_ENDPOINT`.
- Produces: `collect_baseline`, `collect_postcheck`, `assert_ceph_health_check`.

- [ ] **Step 1: Write a failing evidence smoke test**

Append to `experiments/ceph-alert-real-lab/tests/run-tests.sh`:

```bash
[[ -f "$ROOT/lib/evidence.sh" ]] || fail "missing $ROOT/lib/evidence.sh"
```

Expected failure before implementation: `missing .../lib/evidence.sh`.

- [ ] **Step 2: Implement evidence helpers**

Create `experiments/ceph-alert-real-lab/lib/evidence.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ceph_seed_cmd() {
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph $*"
}

collect_baseline() {
  local result_dir=$1
  mkdir -p "$result_dir"
  run_capture "$result_dir/ceph-s.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph -s" || true
  run_capture "$result_dir/ceph-health-detail.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph health detail" || true
  run_capture "$result_dir/ceph-osd-tree.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd tree" || true
  run_capture "$result_dir/ceph-quorum-status.json" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph quorum_status --format json" || true
  run_capture "$result_dir/mgr-metrics-health-detail.txt" curl -fsS "$LAB_MGR_ENDPOINT/metrics" || true
  run_capture "$result_dir/rook-cephcluster.txt" kubectl_lab -n rook-ceph-external get cephcluster -o wide || true
  run_capture "$result_dir/rook-pods.txt" kubectl_lab -n rook-ceph get pods -o wide || true
}

collect_postcheck() {
  local result_dir=$1
  collect_baseline "$result_dir"
}

assert_ceph_health_check() {
  local check_name=$1 result_dir=$2
  run_capture "$result_dir/health-check-${check_name}.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph health detail"
  grep -q "$check_name" "$result_dir/health-check-${check_name}.txt"
}
```

Create `experiments/ceph-alert-real-lab/run/baseline.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/evidence.sh"

result_dir="$(new_result_dir baseline)"
collect_baseline "$result_dir"
printf 'baseline: %s\n' "$result_dir"
```

- [ ] **Step 3: Run tests and shell syntax checks**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/lib/evidence.sh experiments/ceph-alert-real-lab/run/baseline.sh
```

Expected: both commands exit 0.

- [ ] **Step 4: Commit**

Run:

```bash
chmod +x experiments/ceph-alert-real-lab/run/baseline.sh
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add Ceph alert lab evidence capture"
```

Expected: commit succeeds.

---

### Task 4: Scenario Command Generation

**Files:**
- Create: `experiments/ceph-alert-real-lab/lib/scenarios.sh`
- Create: `experiments/ceph-alert-real-lab/tests/test-scenario-commands.sh`
- Modify: `experiments/ceph-alert-real-lab/tests/run-tests.sh`

**Interfaces:**
- Consumes: `LAB_FSID`.
- Produces: command-generation helpers used by destructive scenario scripts.

- [ ] **Step 1: Write command-generation tests**

Create `experiments/ceph-alert-real-lab/tests/test-scenario-commands.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/scenarios.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

[[ "$(osd_service_name "$LAB_FSID" 7)" == "ceph-${LAB_FSID}@osd.7.service" ]] || fail "bad OSD service"
[[ "$(mon_service_name "$LAB_FSID" ceph-lab-mon-03)" == "ceph-${LAB_FSID}@mon.ceph-lab-mon-03.service" ]] || fail "bad mon service"
[[ "$(cgroup_io_max_path "$LAB_FSID" 4)" == "/sys/fs/cgroup/system.slice/ceph-${LAB_FSID}@osd.4.service/io.max" ]] || fail "bad io.max path"

throttle="$(io_throttle_command '8:16' 65536 '/sys/fs/cgroup/x/io.max')"
[[ "$throttle" == "printf '%s\n' '8:16 rbps=65536 wbps=65536 riops=max wiops=max' | sudo tee /sys/fs/cgroup/x/io.max" ]] || fail "bad throttle command: $throttle"

unthrottle="$(io_unthrottle_command '8:16' '/sys/fs/cgroup/x/io.max')"
[[ "$unthrottle" == "printf '%s\n' '8:16 rbps=max wbps=max riops=max wiops=max' | sudo tee /sys/fs/cgroup/x/io.max" ]] || fail "bad unthrottle command: $unthrottle"

pool_cmds="$(pool_create_commands alert-test)"
printf '%s\n' "$pool_cmds" | grep -q 'ceph osd pool create alert-test 1' || fail "missing pool create"
printf '%s\n' "$pool_cmds" | grep -q 'ceph osd pool set alert-test min_size 2' || fail "missing min_size"

cleanup_cmds="$(pool_cleanup_commands alert-test)"
printf '%s\n' "$cleanup_cmds" | grep -q 'ceph osd pool delete alert-test alert-test --yes-i-really-really-mean-it' || fail "missing pool delete"

ok "scenario command generation"
```

Modify `experiments/ceph-alert-real-lab/tests/run-tests.sh` to include:

```bash
[[ -f "$ROOT/lib/scenarios.sh" ]] || fail "missing $ROOT/lib/scenarios.sh"
bash "$ROOT/tests/test-scenario-commands.sh"
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Expected: FAIL with `missing .../lib/scenarios.sh`.

- [ ] **Step 3: Implement scenario command helpers**

Create `experiments/ceph-alert-real-lab/lib/scenarios.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

osd_service_name() {
  local fsid=$1 osd_id=$2
  printf 'ceph-%s@osd.%s.service\n' "$fsid" "$osd_id"
}

mon_service_name() {
  local fsid=$1 mon_name=$2
  printf 'ceph-%s@mon.%s.service\n' "$fsid" "$mon_name"
}

cgroup_io_max_path() {
  local fsid=$1 osd_id=$2
  printf '/sys/fs/cgroup/system.slice/ceph-%s@osd.%s.service/io.max\n' "$fsid" "$osd_id"
}

io_throttle_command() {
  local major_minor=$1 bytes_per_second=$2 io_max_path=$3
  printf "printf '%%s\\n' '%s rbps=%s wbps=%s riops=max wiops=max' | sudo tee %s\n" "$major_minor" "$bytes_per_second" "$bytes_per_second" "$io_max_path"
}

io_unthrottle_command() {
  local major_minor=$1 io_max_path=$2
  printf "printf '%%s\\n' '%s rbps=max wbps=max riops=max wiops=max' | sudo tee %s\n" "$major_minor" "$io_max_path"
}

pool_create_commands() {
  local pool=$1
  printf 'ceph osd pool create %s 1\n' "$pool"
  printf 'ceph osd pool set %s size 3\n' "$pool"
  printf 'ceph osd pool set %s min_size 2\n' "$pool"
  printf 'rados -p %s put sentinel /etc/hosts\n' "$pool"
}

pool_cleanup_commands() {
  local pool=$1
  printf 'rados -p %s cleanup --prefix benchmark_data || true\n' "$pool"
  printf 'ceph osd pool delete %s %s --yes-i-really-really-mean-it || true\n' "$pool" "$pool"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Expected: output contains `ok: scenario command generation` and exits 0.

- [ ] **Step 5: Commit**

Run:

```bash
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add Ceph alert scenario command helpers"
```

Expected: commit succeeds.

---

### Task 5: Implement `SLOW_OPS` Scenario

**Files:**
- Create: `experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh`
- Modify: `experiments/ceph-alert-real-lab/README.md`

**Interfaces:**
- Consumes: `collect_baseline`, `assert_ceph_health_check`, `wait_prometheus_alert`, `wait_sink_alert`, `io_throttle_command`, `io_unthrottle_command`.
- Produces: result directory containing `health-check-SLOW_OPS.txt`, `prometheus-alerts-CephClientBlocked-name.json`, and `sink.log`.

- [ ] **Step 1: Implement the destructive script with rollback trap**

Create `experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"
source "$ROOT/lib/evidence.sh"
source "$ROOT/lib/scenarios.sh"

require_destructive_ack slow-ops "$@"
require_cmd jq

POOL="${SLOW_OPS_POOL:-alert-slow-ops}"
OSD_ID="${SLOW_OPS_OSD_ID:-0}"
OSD_HOST="${SLOW_OPS_OSD_HOST:-$LAB_OSD_01_HOST}"
OSD_DEVICE="${SLOW_OPS_DEVICE:-/dev/sdb}"
THROTTLE_BPS="${SLOW_OPS_THROTTLE_BPS:-65536}"
RESULT_DIR="$(new_result_dir slow-ops)"
IO_PATH="$(cgroup_io_max_path "$LAB_FSID" "$OSD_ID")"
MAJMIN=""

cleanup() {
  log "rollback slow-ops scenario"
  if [[ -n "$MAJMIN" ]]; then
    ssh_lab "$OSD_HOST" "$(io_unthrottle_command "$MAJMIN" "$IO_PATH")" || true
  fi
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool delete $POOL $POOL --yes-i-really-really-mean-it" || true
  collect_postcheck "$RESULT_DIR/postcheck" || true
}
trap cleanup EXIT

collect_baseline "$RESULT_DIR/baseline"

ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool create $POOL 1"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL size 3"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL min_size 2"

MAJMIN="$(ssh_lab "$OSD_HOST" "lsblk -no MAJ:MIN $OSD_DEVICE | head -1")"
[[ -n "$MAJMIN" ]] || die "could not resolve major:minor for $OSD_DEVICE on $OSD_HOST"
ssh_lab "$OSD_HOST" "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs"
ssh_lab "$OSD_HOST" "$(io_throttle_command "$MAJMIN" "$THROTTLE_BPS" "$IO_PATH")"

run_capture "$RESULT_DIR/rados-bench.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- rados bench -p $POOL 180 write -b 4194304 -t 16 --no-cleanup" || true

assert_ceph_health_check SLOW_OPS "$RESULT_DIR"
wait_prometheus_alert CephClientBlocked name SLOW_OPS "$RESULT_DIR"
wait_sink_alert pager CephClientBlocked name SLOW_OPS "$RESULT_DIR"

trap - EXIT
cleanup
printf 'result: %s\n' "$RESULT_DIR"
```

- [ ] **Step 2: Run shell syntax check**

Run:

```bash
bash -n experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh
```

Expected: exits 0.

- [ ] **Step 3: Update README with exact command**

Add to `experiments/ceph-alert-real-lab/README.md`:

````markdown
## SLOW_OPS

主測用 cgroup v2 `io.max` 對 OSD backing device 限速，然後用 `rados bench` 打測試 pool。

```bash
SLOW_OPS_OSD_ID=0 \
SLOW_OPS_OSD_HOST=192.168.18.169 \
SLOW_OPS_DEVICE=/dev/sdb \
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
```
````

- [ ] **Step 4: Run local tests**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

Run:

```bash
chmod +x experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add real disk slow ops alert scenario"
```

Expected: commit succeeds.

---

### Task 6: Implement `PG_AVAILABILITY` Scenario

**Files:**
- Create: `experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh`
- Modify: `experiments/ceph-alert-real-lab/README.md`

**Interfaces:**
- Consumes: evidence and monitoring helpers, `osd_service_name`.
- Produces: result directory containing stopped OSD list, Ceph health evidence, Prometheus firing alert JSON, and sink log.

- [ ] **Step 1: Implement the destructive script**

Create `experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"
source "$ROOT/lib/evidence.sh"
source "$ROOT/lib/scenarios.sh"

require_destructive_ack pg-availability "$@"
require_cmd jq

POOL="${PG_AVAIL_POOL:-alert-pg-availability}"
OBJECT="${PG_AVAIL_OBJECT:-sentinel}"
RESULT_DIR="$(new_result_dir pg-availability)"
STOPPED_FILE="$RESULT_DIR/stopped-osds.txt"

cleanup() {
  local line host osd service
  log "rollback pg-availability scenario"
  if [[ -f "$STOPPED_FILE" ]]; then
    while IFS=' ' read -r host osd; do
      [[ -n "$host" && -n "$osd" ]] || continue
      service="$(osd_service_name "$LAB_FSID" "$osd")"
      ssh_lab "$host" "sudo systemctl start $service" || true
    done <"$STOPPED_FILE"
  fi
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool delete $POOL $POOL --yes-i-really-really-mean-it" || true
  collect_postcheck "$RESULT_DIR/postcheck" || true
}
trap cleanup EXIT

collect_baseline "$RESULT_DIR/baseline"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool create $POOL 1"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL size 3"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL min_size 2"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- rados -p $POOL put $OBJECT /etc/hosts"

map_json="$RESULT_DIR/osd-map.json"
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$map_json"
jq -r '.acting[]' "$map_json" | head -2 >"$RESULT_DIR/target-osds.txt"

while IFS= read -r osd; do
  host="$(ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $osd --format json" | jq -r '.crush_location.host')"
  case "$host" in
    ceph-lab-osd-01) ip="$LAB_OSD_01_HOST" ;;
    ceph-lab-osd-02) ip="$LAB_OSD_02_HOST" ;;
    ceph-lab-osd-03) ip="$LAB_OSD_03_HOST" ;;
    *) die "unknown OSD host for osd.$osd: $host" ;;
  esac
  service="$(osd_service_name "$LAB_FSID" "$osd")"
  printf '%s %s\n' "$ip" "$osd" >>"$STOPPED_FILE"
  ssh_lab "$ip" "sudo systemctl stop $service"
done <"$RESULT_DIR/target-osds.txt"

assert_ceph_health_check PG_AVAILABILITY "$RESULT_DIR"
wait_prometheus_alert CephClientBlocked name PG_AVAILABILITY "$RESULT_DIR"
wait_sink_alert pager CephClientBlocked name PG_AVAILABILITY "$RESULT_DIR"

trap - EXIT
cleanup
printf 'result: %s\n' "$RESULT_DIR"
```

- [ ] **Step 2: Run syntax check**

Run:

```bash
bash -n experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh
```

Expected: exits 0.

- [ ] **Step 3: Update README**

Add:

````markdown
## PG_AVAILABILITY

這個情境會建立測試 pool，找 sentinel object 的 acting set，停止兩顆 acting OSD，等 `PG_AVAILABILITY` 與 `CephClientBlocked{name="PG_AVAILABILITY"}`。

```bash
bash experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh --yes-really-inject
```
````

- [ ] **Step 4: Run local tests**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

Run:

```bash
chmod +x experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add PG availability alert scenario"
```

Expected: commit succeeds.

---

### Task 7: Implement `CephMonQuorumLost` Scenario

**Files:**
- Create: `experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh`
- Modify: `experiments/ceph-alert-real-lab/README.md`

**Interfaces:**
- Consumes: monitoring/evidence helpers, `mon_service_name`.
- Produces: result directory with stopped mon list, Prometheus alert JSON, sink log, and post-check.

- [ ] **Step 1: Implement the destructive script**

Create `experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"
source "$ROOT/lib/evidence.sh"
source "$ROOT/lib/scenarios.sh"

require_destructive_ack mon-quorum-lost "$@"

RESULT_DIR="$(new_result_dir mon-quorum-lost)"
STOPPED_FILE="$RESULT_DIR/stopped-mons.txt"

cleanup() {
  local host mon service
  log "rollback mon-quorum-lost scenario"
  if [[ -f "$STOPPED_FILE" ]]; then
    while IFS=' ' read -r host mon; do
      [[ -n "$host" && -n "$mon" ]] || continue
      service="$(mon_service_name "$LAB_FSID" "$mon")"
      ssh_lab "$host" "sudo systemctl start $service" || true
    done <"$STOPPED_FILE"
  fi
  collect_postcheck "$RESULT_DIR/postcheck" || true
}
trap cleanup EXIT

collect_baseline "$RESULT_DIR/baseline"

printf '%s %s\n' "$LAB_MON_01_HOST" "$LAB_MON_01_NAME" >>"$STOPPED_FILE"
printf '%s %s\n' "$LAB_MON_03_HOST" "$LAB_MON_03_NAME" >>"$STOPPED_FILE"

ssh_lab "$LAB_MON_01_HOST" "sudo systemctl stop $(mon_service_name "$LAB_FSID" "$LAB_MON_01_NAME")"
ssh_lab "$LAB_MON_03_HOST" "sudo systemctl stop $(mon_service_name "$LAB_FSID" "$LAB_MON_03_NAME")"

wait_prometheus_alert CephMonQuorumLost "" "" "$RESULT_DIR"
wait_sink_alert pager CephMonQuorumLost "" "" "$RESULT_DIR"

trap - EXIT
cleanup
printf 'result: %s\n' "$RESULT_DIR"
```

- [ ] **Step 2: Run syntax check**

Run:

```bash
bash -n experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh
```

Expected: exits 0.

- [ ] **Step 3: Update README**

Add:

````markdown
## CephMonQuorumLost

這個情境會保留 active mgr 所在的 `ceph-lab-mon-02`，停止 `ceph-lab-mon-01` 與 `ceph-lab-mon-03`，觀察 `CephMonQuorumLost` 是否 firing 且進 pager。

```bash
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
```
````

- [ ] **Step 4: Run local tests**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

Run:

```bash
chmod +x experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add MON quorum lost alert scenario"
```

Expected: commit succeeds.

---

### Task 8: Full Orchestrator, Cleanup, And Final Gates

**Files:**
- Create: `experiments/ceph-alert-real-lab/run/all.sh`
- Modify: `experiments/ceph-alert-real-lab/run/cleanup.sh`
- Modify: `experiments/ceph-alert-real-lab/README.md`

**Interfaces:**
- Consumes: all prior scripts.
- Produces: full run entrypoint and documented final validation.

- [ ] **Step 1: Implement full orchestrator**

Create `experiments/ceph-alert-real-lab/run/all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_destructive_ack all "$@"

bash "$ROOT/run/deploy-monitoring.sh"
bash "$ROOT/run/baseline.sh"
bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject
bash "$ROOT/run/scenario-pg-availability.sh" --yes-really-inject
bash "$ROOT/run/scenario-mon-quorum-lost.sh" --yes-really-inject
log "all real lab scenarios completed"
```

- [ ] **Step 2: Expand cleanup**

Modify `experiments/ceph-alert-real-lab/run/cleanup.sh` so it also best-effort removes test pools and clears known cgroup throttles:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/monitoring.sh"

delete_monitoring_stack
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool delete alert-slow-ops alert-slow-ops --yes-i-really-really-mean-it" || true
ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool delete alert-pg-availability alert-pg-availability --yes-i-really-really-mean-it" || true
log "cleanup completed"
```

- [ ] **Step 3: Update README with final gate commands**

Add:

````markdown
## 本機驗證 gate

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```
````

- [ ] **Step 4: Run all local gates**

Run:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

Expected:

- `tests/run-tests.sh` exits 0.
- `shellcheck` exits 0.
- `make validate` exits 0 with `All checks passed!`.

- [ ] **Step 5: Commit**

Run:

```bash
chmod +x experiments/ceph-alert-real-lab/run/all.sh
git add experiments/ceph-alert-real-lab
git commit --no-gpg-sign -m "Add Ceph alert real lab orchestrator"
```

Expected: commit succeeds.

---

### Task 9: Execute Real Lab Validation

**Files:**
- Generated only: `experiments/ceph-alert-real-lab/results/*`
- Do not commit generated result logs unless the user explicitly asks to publish them.

**Interfaces:**
- Consumes: full harness.
- Produces: actual evidence for `SLOW_OPS`, `PG_AVAILABILITY`, and `CephMonQuorumLost`.

- [ ] **Step 1: Confirm baseline health**

Run:

```bash
bash experiments/ceph-alert-real-lab/run/deploy-monitoring.sh
bash experiments/ceph-alert-real-lab/run/baseline.sh
```

Expected:

- `ceph -s` evidence shows `HEALTH_OK`.
- Rook evidence shows `Connected / HEALTH_OK`.
- Prometheus Pod and Alertmanager Pod are Running.

- [ ] **Step 2: Run `SLOW_OPS`**

Run:

```bash
SLOW_OPS_OSD_ID=0 \
SLOW_OPS_OSD_HOST=192.168.18.169 \
SLOW_OPS_DEVICE=/dev/sdb \
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
```

Expected:

- `health-check-SLOW_OPS.txt` contains `SLOW_OPS`.
- Prometheus alert evidence contains `CephClientBlocked` with `name="SLOW_OPS"` and `state="firing"`.
- `sink.log` contains JSON with `"receiver":"pager"` and `"alertname":"CephClientBlocked"` and `"name":"SLOW_OPS"`.
- Post-check evidence returns to `HEALTH_OK`.

- [ ] **Step 3: Run `PG_AVAILABILITY`**

Run:

```bash
bash experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh --yes-really-inject
```

Expected:

- `health-check-PG_AVAILABILITY.txt` contains `PG_AVAILABILITY`.
- Prometheus alert evidence contains `CephClientBlocked` with `name="PG_AVAILABILITY"` and `state="firing"`.
- `sink.log` contains JSON with `"receiver":"pager"` and `"alertname":"CephClientBlocked"` and `"name":"PG_AVAILABILITY"`.
- Post-check evidence returns to `HEALTH_OK`.

- [ ] **Step 4: Run `CephMonQuorumLost`**

Run:

```bash
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
```

Expected:

- Prometheus alert evidence contains `CephMonQuorumLost` and `state="firing"`.
- `sink.log` contains JSON with `"receiver":"pager"` and `"alertname":"CephMonQuorumLost"`.
- Post-check evidence returns to `HEALTH_OK`.

- [ ] **Step 5: Summarize evidence**

Run:

```bash
find experiments/ceph-alert-real-lab/results -maxdepth 2 -type f \
  \( -name 'health-check-*.txt' -o -name 'prometheus-alerts-*.json' -o -name 'sink.log' -o -name 'ceph-s.txt' \) \
  | sort
```

Expected: files exist for all three scenarios.

- [ ] **Step 6: Final cleanup**

Run:

```bash
bash experiments/ceph-alert-real-lab/run/cleanup.sh
```

Expected: monitoring namespace is deleted and test pools are absent.

---

## Self-Review Notes

- Spec coverage: monitoring stack, `PG_AVAILABILITY`, `SLOW_OPS`, `CephMonQuorumLost`, rollback, post-checks, and generated evidence are each covered by tasks.
- Placeholder scan: no red-flag placeholder phrases remain in task instructions.
- Type and interface consistency: function names in scenario tasks match the interface list at the top of the plan.
- Scope note: coding tasks can be implemented by subagents, but real destructive validation in Task 9 must run inline in the main session.
