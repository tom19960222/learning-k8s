#!/usr/bin/env bash
set -euo pipefail

render_monitoring_manifest() {
  local output_file=$1 root rules_dir stability_rules scoped_rules coverage_rules default_rules endpoint
  root="$(lab_root)"
  rules_dir="$root/../ceph-alert-rules/rules"
  stability_rules="$rules_dir/ceph-stability-first.yml"
  scoped_rules="$rules_dir/ceph-scoped-availability.yml"
  coverage_rules="$rules_dir/ceph-production-coverage.yml"
  default_rules="$rules_dir/_default-mixin.yml"
  [[ -f "$stability_rules" ]] || die "missing rules file: $stability_rules"
  [[ -f "$scoped_rules" ]] || die "missing rules file: $scoped_rules"
  [[ -f "$coverage_rules" ]] || die "missing rules file: $coverage_rules"
  [[ -f "$default_rules" ]] || die "missing rules file: $default_rules"

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
    sed 's/^/    /' "$stability_rules"
    cat <<YAML
  ceph-scoped-availability.yml: |
YAML
    sed 's/^/    /' "$scoped_rules"
    cat <<YAML
  ceph-production-coverage.yml: |
YAML
    sed 's/^/    /' "$coverage_rules"
    cat <<YAML
  default-mixin.yml: |
YAML
    sed 's/^/    /' "$default_rules"
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
      - /etc/prometheus/rules/ceph-scoped-availability.yml
      - /etc/prometheus/rules/ceph-production-coverage.yml
      - /etc/prometheus/rules/default-mixin.yml
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
                - alertmanager.${LAB_NAMESPACE}.svc.cluster.local:9093
    scrape_configs:
      - job_name: ceph
        static_configs:
          - targets:
YAML
    for endpoint in $LAB_MGR_ENDPOINTS; do
      printf '              - "%s"\n' "${endpoint#http://}"
    done
    cat <<YAML
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
        - receiver: watchdog-ceph
          group_wait: 0s
          matchers:
            - alertname="Watchdog"
          repeat_interval: 1m
        - receiver: pager-ceph
          group_wait: 0s
          matchers:
            - severity="critical"
            - source=~"ceph_stability|ceph_scoped|ceph_coverage"
        - receiver: pager-ceph
          group_wait: 0s
          matchers:
            - type="ceph_default"
            - alertname="CephHealthError"
        - receiver: slack-ceph
          matchers:
            - source=~"ceph_stability|ceph_scoped|ceph_coverage"
        - receiver: slack-ceph
          matchers:
            - type="ceph_default"
    inhibit_rules:
      - source_matchers:
          - alertname="CephMonQuorumLost"
        target_matchers:
          - alertname="CephMonDownScoped"
    receivers:
      - name: slack-ceph
        webhook_configs:
          - url: http://alert-sink.${LAB_NAMESPACE}.svc.cluster.local:8080/slack
      - name: pager-ceph
        webhook_configs:
          - url: http://alert-sink.${LAB_NAMESPACE}.svc.cluster.local:8080/pager
      - name: watchdog-ceph
        webhook_configs:
          - url: http://alert-sink.${LAB_NAMESPACE}.svc.cluster.local:8080/watchdog
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
  kubectl_lab apply -f "$manifest" >&2
  kubectl_lab -n "$LAB_NAMESPACE" rollout status deploy/alert-sink --timeout=180s >&2
  kubectl_lab -n "$LAB_NAMESPACE" rollout status deploy/prometheus --timeout=180s >&2
  kubectl_lab -n "$LAB_NAMESPACE" rollout status deploy/alertmanager --timeout=180s >&2
}

delete_monitoring_stack() {
  kubectl_lab delete namespace "$LAB_NAMESPACE" --ignore-not-found=true
}

url_encode() {
  local value=$1 encoded="" char hex i
  local LC_ALL=C
  i=0
  while [[ "$i" -lt "${#value}" ]]; do
    char="${value:$i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded="${encoded}${char}"
        ;;
      *)
        printf -v hex '%%%02X' "'$char"
        encoded="${encoded}${hex}"
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$encoded"
}

prometheus_query() {
  local query=$1 pod encoded_query
  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')"
  encoded_query="$(url_encode "$query")"
  kubectl_lab -n "$LAB_NAMESPACE" exec "$pod" -- wget -qO- "http://127.0.0.1:9090/api/v1/query?query=${encoded_query}"
}

wait_prometheus_alert() {
  local alertname=$1 label_name=$2 label_value=$3 result_dir=$4
  poll_until "Prometheus alert $alertname $label_name=$label_value firing" "${PROMETHEUS_WAIT_ATTEMPTS:-60}" "${PROMETHEUS_WAIT_SLEEP:-5}" prometheus_alert_is_firing "$alertname" "$label_name" "$label_value" "$result_dir"
}

# with_prometheus_wait_attempts <attempts> <cmd...> temporarily overrides
# PROMETHEUS_WAIT_ATTEMPTS for a single call (e.g. one wait_prometheus_alert
# invocation) whose `for:` window differs from this scenario's other stages,
# then restores whatever value (or absence) was in effect before. Used by
# multi-stage scenarios (e.g. capacity-ladder, pool-quota) where different
# ladder rungs correspond to alerts with different `for:` durations.
with_prometheus_wait_attempts() {
  local attempts=$1
  shift
  local saved="${PROMETHEUS_WAIT_ATTEMPTS:-60}" rc=0
  PROMETHEUS_WAIT_ATTEMPTS="$attempts"
  export PROMETHEUS_WAIT_ATTEMPTS
  "$@" || rc=$?
  PROMETHEUS_WAIT_ATTEMPTS="$saved"
  export PROMETHEUS_WAIT_ATTEMPTS
  return "$rc"
}

prometheus_alert_is_firing() {
  local alertname=$1 label_name=$2 label_value=$3 result_dir=$4 pod out
  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}')"
  out="$(kubectl_lab -n "$LAB_NAMESPACE" exec "$pod" -- wget -qO- http://127.0.0.1:9090/api/v1/alerts)"
  printf "%s\n" "$out" >"$result_dir/prometheus-alerts-${alertname}-${label_name:-none}.json"
  printf "%s\n" "$out" | jq -e --arg an "$alertname" --arg ln "$label_name" --arg lv "$label_value" '.data.alerts[] | select(.labels.alertname==$an) | select(($ln=="") or (.labels[$ln]==$lv)) | select(.state=="firing")' >/dev/null
}

wait_sink_alert() {
  local receiver=$1 alertname=$2 label_name=$3 label_value=$4 result_dir=$5 checkpoint_file="${6:-}"
  # shellcheck disable=SC2016
  # Intentional single-quoted inline script so jq variables expand in the subshell, not here.
  poll_until "sink $receiver received $alertname $label_name=$label_value" "${SINK_WAIT_ATTEMPTS:-60}" "${SINK_WAIT_SLEEP:-5}" bash -c '
    logs="$(kubectl --kubeconfig "$0" -n "$1" logs deploy/alert-sink)"
    printf "%s\n" "$logs" >"$2/sink.log"
    start=0
    if [[ -n "$7" && -f "$7" ]]; then
      start="$(cat "$7")"
    fi
    awk -v start="$start" '"'"'NR > start'"'"' "$2/sink.log" >"$2/sink-since-checkpoint.log"
    jq -r . "$2/sink-since-checkpoint.log" 2>/dev/null | jq -e --arg r "$3" --arg an "$4" --arg ln "$5" --arg lv "$6" '"'"'select(.receiver==$r) | select(.alertname==$an) | select(($ln=="") or (.labels[$ln]==$lv))'"'"' >/dev/null
  ' "$LAB_KUBECONFIG" "$LAB_NAMESPACE" "$result_dir" "$receiver" "$alertname" "$label_name" "$label_value" "$checkpoint_file"
}

record_sink_checkpoint() {
  local result_dir=$1 output_file line_file
  output_file="$result_dir/sink-checkpoint.log"
  line_file="$result_dir/sink-checkpoint-lines.txt"
  mkdir -p "$result_dir"
  if kubectl_lab -n "$LAB_NAMESPACE" logs deploy/alert-sink >"$output_file" 2>"$output_file.err"; then
    :
  else
    : >"$output_file"
  fi
  wc -l <"$output_file" | tr -d ' ' >"$line_file"
}

assert_prometheus_alert_not_firing() {
  local alertname=$1 label_name=$2 label_value=$3 result_dir=$4
  if prometheus_alert_is_firing "$alertname" "$label_name" "$label_value" "$result_dir"; then
    log "FAIL: alert $alertname unexpectedly firing"
    return 1
  fi
  log "PASS: alert $alertname not firing"
  return 0
}

alertmanager_alert_is_inhibited() {
  local alertname=$1 result_dir=$2 pod out
  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=alertmanager -o jsonpath='{.items[0].metadata.name}')"
  out="$(kubectl_lab -n "$LAB_NAMESPACE" exec "$pod" -- wget -qO- http://127.0.0.1:9093/api/v2/alerts)"
  printf '%s\n' "$out" >"$result_dir/alertmanager-alerts-${alertname}.json"
  printf '%s\n' "$out" | jq -e --arg an "$alertname" \
    '.[] | select(.labels.alertname==$an) | select((.status.inhibitedBy | length) > 0)' >/dev/null
}

wait_alertmanager_inhibited() {
  local alertname=$1 result_dir=$2
  poll_until "Alertmanager alert $alertname inhibited" "${ALERTMANAGER_WAIT_ATTEMPTS:-60}" "${ALERTMANAGER_WAIT_SLEEP:-5}" \
    alertmanager_alert_is_inhibited "$alertname" "$result_dir"
}

# assert_inhibit_via_synthetic_post <source_alertname> <target_alertname> <result_dir>
#
# Validates an Alertmanager inhibit_rules relationship deterministically,
# instead of waiting for a real fault to (maybe) produce the temporal
# overlap required for it to be observed. Some inhibit relationships can
# never be observed from their real fault -- e.g. CephMonQuorumLost's
# relationship with CephMonDownScoped: when quorum is actually lost, the mgr
# exporter's telemetry freezes, so CephMonQuorumLost only fires later via its
# `or vector(0)` empty-series fallback, by which point ceph_mon_quorum_status
# / ceph_mon_metadata have no data at all and CephMonDownScoped's expr can
# never evaluate to active. POSTing a synthetic pair of alerts straight to
# Alertmanager's /api/v2/alerts exercises the same inhibit_rules matchers
# that route in production, without depending on a faked ceph metric -- this
# validates Alertmanager's suppression config, not the ceph fault itself.
assert_inhibit_via_synthetic_post() {
  local source_alertname=$1 target_alertname=$2 result_dir=$3
  local pod now payload post_out

  pod="$(kubectl_lab -n "$LAB_NAMESPACE" get pod -l app=alertmanager -o jsonpath='{.items[0].metadata.name}')"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  payload=$(printf '[{"labels":{"alertname":"%s","severity":"critical","source":"ceph_stability"},"annotations":{"summary":"synthetic-inhibit-probe"},"startsAt":"%s"},{"labels":{"alertname":"%s","severity":"critical","source":"ceph_scoped","ceph_daemon":"mon.synthetic","hostname":"synthetic"},"annotations":{"summary":"synthetic-inhibit-probe"},"startsAt":"%s"}]' \
    "$source_alertname" "$now" "$target_alertname" "$now")

  post_out="$result_dir/synthetic-inhibit-post-${source_alertname}-${target_alertname}.json"
  kubectl_lab -n "$LAB_NAMESPACE" exec "$pod" -- wget -qO- \
    --header="Content-Type: application/json" \
    --post-data="$payload" \
    http://127.0.0.1:9093/api/v2/alerts >"$post_out"

  poll_until "Alertmanager alert $target_alertname inhibited via synthetic $source_alertname POST" \
    "${SYNTHETIC_INHIBIT_WAIT_ATTEMPTS:-12}" "${SYNTHETIC_INHIBIT_WAIT_SLEEP:-5}" \
    alertmanager_alert_is_inhibited "$target_alertname" "$result_dir"
}

assert_sink_absent() {
  local receiver=$1 alertname=$2 label_name=$3 label_value=$4 result_dir=$5 checkpoint_file="${6:-}"
  local start=0
  kubectl_lab -n "$LAB_NAMESPACE" logs deploy/alert-sink >"$result_dir/sink-absent-check.log"
  if [[ -n "$checkpoint_file" && -f "$checkpoint_file" ]]; then
    start="$(cat "$checkpoint_file")"
  fi
  awk -v start="$start" 'NR > start' "$result_dir/sink-absent-check.log" >"$result_dir/sink-absent-since-checkpoint.log"
  if jq -r . "$result_dir/sink-absent-since-checkpoint.log" 2>/dev/null \
    | jq -e --arg r "$receiver" --arg an "$alertname" --arg ln "$label_name" --arg lv "$label_value" \
      'select(.receiver==$r) | select(.alertname==$an) | select(($ln=="") or (.labels[$ln]==$lv))' >/dev/null; then
    log "FAIL: sink $receiver unexpectedly received $alertname"
    return 1
  fi
  log "PASS: sink $receiver did not receive $alertname"
  return 0
}
