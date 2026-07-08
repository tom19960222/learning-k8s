#!/usr/bin/env bash
# SCENARIO: stop 2-of-3 mons (quorum lost); measure Thread A (detection sources)
# and Thread B (pre-connected vs new client IO) during the window.
# Contract: inject -> observe -> collect -> rollback -> assert.
# ROLLBACK IS TRAP-GUARANTEED: mon-02+mon-03 restart + HEALTH_OK assert on ANY exit.
#
# Runs on the Mac (orchestrator). IPs = 2026-07-08 shifted set (see memory).
set -uo pipefail

REPO=/Users/ikaros/Documents/code/learning-k8s
KEY="$REPO/.ssh/id_ed25519"
MON1_IP=192.168.18.153   # keep UP (runs active mgr — observe stale telemetry here)
MON2_IP=192.168.18.152   # stop
MON3_IP=192.168.18.156   # stop
K8S_IP=192.168.18.155
FSID=0c9bf37e-514a-11f1-b72a-bc24113f1375
UNIT2="ceph-$FSID@mon.ceph-lab-mon-02.service"
UNIT3="ceph-$FSID@mon.ceph-lab-mon-03.service"
PROM="http://192.168.18.155:30090"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BUNDLE="$REPO/experiments/ceph-mon-quorum-blind-spot/results/mon-quorum-2down-$TS"
mkdir -p "$BUNDLE"

hssh() { ip="$1"; shift; ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "ikaros@$ip" "$@"; }
pqs() { curl -s --max-time 8 "$PROM/api/v1/query" --data-urlencode "query=$1" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else 'EMPTY')"; }
palerts() { curl -s --max-time 8 "$PROM/api/v1/alerts" \
  | python3 -c "import sys,json;print([(a['labels']['alertname'],a['labels'].get('cand',''),a['state']) for a in json.load(sys.stdin)['data']['alerts']])"; }

psnap() {
  label="$1"; f="$BUNDLE/prom-$label.txt"
  {
    echo "# $label  $(date -u +%FT%TZ)"
    echo "A1 mgr count(ceph_mon_quorum_status==1) = $(pqs 'count(ceph_mon_quorum_status==1)')  [expect stale=3 => BLIND]"
    echo "   sum(ceph_mon_quorum_status)         = $(pqs 'sum(ceph_mon_quorum_status)')"
    echo "A3 blackbox count(probe_success==1)     = $(pqs 'count(probe_success{job="mon-tcp"}==1)')  [expect 1 => DETECTS]"
    echo "A4 up{job=ceph} (mgr scrape)            = $(pqs 'up{job="ceph"}')  [expect 1 => BLIND]"
    echo "   sum(up{job=mon-tcp}) blackbox scrape = $(pqs 'sum(up{job="mon-tcp"})')"
    echo "alerts = $(palerts)"
  } > "$f"
  echo "---- snap $label ----"; cat "$f"
}

rolled_back=0
rollback() {
  [ "$rolled_back" = 1 ] && return; rolled_back=1
  echo ">>> ROLLBACK: start mon-02, mon-03  $(date -u +%FT%TZ)"
  hssh "$MON2_IP" "sudo systemctl reset-failed $UNIT2 2>/dev/null; sudo systemctl start $UNIT2" || true
  hssh "$MON3_IP" "sudo systemctl reset-failed $UNIT3 2>/dev/null; sudo systemctl start $UNIT3" || true
  for i in $(seq 1 40); do
    c="$(pqs 'count(probe_success{job="mon-tcp"}==1)')"
    echo "   waiting quorum: blackbox_probe_count=$c"
    [ "$c" = "3" ] && break; sleep 3
  done
  echo ">>> ASSERT quorum restored (3 mons in quorum, not HEALTH_ERR)"
  hssh "$MON1_IP" 'sudo timeout 30 ceph -s 2>&1' | tee "$BUNDLE/postcheck-ceph-s.txt" | head -8
  if grep -q "mon: 3 daemons, quorum" "$BUNDLE/postcheck-ceph-s.txt" && ! grep -q HEALTH_ERR "$BUNDLE/postcheck-ceph-s.txt"; then
    echo "ASSERT: 3-mon quorum restored OK ($(grep -o 'health: HEALTH_[A-Z]*' "$BUNDLE/postcheck-ceph-s.txt"))"
  else echo "ASSERT: quorum NOT restored — CHECK MANUALLY"; fi
  echo ">>> cleanup new-client test resources"
  hssh "$K8S_IP" 'sudo kubectl delete pod fio-newclient --grace-period=1 2>/dev/null; sudo kubectl delete pvc qio-newclient 2>/dev/null' || true
}
trap rollback EXIT INT TERM

echo "===== PRE-CHECK ====="
pre_q="$(pqs 'count(ceph_mon_quorum_status==1)')"; pre_p="$(pqs 'count(probe_success{job="mon-tcp"}==1)')"
echo "pre: mgr_quorum_count=$pre_q blackbox_count=$pre_p"
if [ "$pre_q" != "3" ] || [ "$pre_p" != "3" ]; then echo "PRECHECK FAIL (need 3/3) — aborting, no injection"; exit 1; fi
hssh "$MON1_IP" 'sudo timeout 20 ceph -s 2>&1' | tee "$BUNDLE/precheck-ceph-s.txt" | head -8
if grep -q "mon: 3 daemons, quorum" "$BUNDLE/precheck-ceph-s.txt" && ! grep -q HEALTH_ERR "$BUNDLE/precheck-ceph-s.txt"; then
  echo "PRECHECK OK ($(grep -o 'health: HEALTH_[A-Z]*' "$BUNDLE/precheck-ceph-s.txt"); cephadm-check + slow-op WARN are known-benign)"
else echo "PRECHECK FAIL (need 3-mon quorum, not HEALTH_ERR) — aborting, no injection"; exit 1; fi
psnap baseline

echo "===== INJECT: stop mon-02 + mon-03 ====="
date -u +%FT%TZ | tee "$BUNDLE/inject-time.txt"
hssh "$MON2_IP" "sudo systemctl stop $UNIT2"
hssh "$MON3_IP" "sudo systemctl stop $UNIT3"
echo "stopped. is-active:"
{ echo -n "mon-02: "; hssh "$MON2_IP" "systemctl is-active $UNIT2"; echo -n "mon-03: "; hssh "$MON3_IP" "systemctl is-active $UNIT3"; } | tee "$BUNDLE/mon-isactive.txt"

echo "===== OBSERVE ====="
sleep 3;  psnap "t+03s"
sleep 7;  psnap "t+10s"
echo "--- ground truth: client view (expect hunting/timeout = no quorum) ---"
hssh "$MON1_IP" 'sudo timeout 10 ceph -s 2>&1 | head -4' | tee "$BUNDLE/window-ceph-s-groundtruth.txt" || true
sleep 20; psnap "t+30s"

echo "===== Thread B: new client applied DURING window ====="
hssh "$K8S_IP" 'sudo kubectl apply -f /tmp/qio-newclient.yaml' | tee "$BUNDLE/newclient-apply.txt"

echo "===== Thread B: pre-connected window matrix (timeout 40s/cell) ====="
hssh "$K8S_IP" 'sh /tmp/fio-matrix.sh window fio-preconn 40' | tee "$BUNDLE/fio-window.txt"

psnap "t+afterfio"
echo "--- new client status after ~window ---"
hssh "$K8S_IP" 'echo "== pvc =="; sudo kubectl get pvc qio-newclient; echo "== pod =="; sudo kubectl get pod fio-newclient -o wide; echo "== events =="; sudo kubectl describe pod fio-newclient 2>/dev/null | grep -A20 Events' | tee "$BUNDLE/newclient-status.txt"
psnap "window-final"

echo "===== end of window — trap will rollback+assert ====="
echo "BUNDLE=$BUNDLE"
