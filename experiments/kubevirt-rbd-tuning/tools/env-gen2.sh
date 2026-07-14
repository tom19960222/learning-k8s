# env-gen2.sh — 連線變數（世代 2026-07-13，clean 6-OSD 環境 cyshih-kubevirt-ceph-lab redeploy）
# source 這支再用 s()/ceph_c()/kc() helper。舊 e30/e31... 腳本內的硬編 IP 一律以本檔為準。
export KEY="$HOME/.ssh/azure-lab"
export SSHUSER="azureuser"
export MON1="20.78.164.206"   # cyshih-mon-0 (active mgr, ceph-common)
export MON2="20.89.193.92"    # cyshih-mon-1
export MON3="20.210.187.83"   # cyshih-mon-2
export OSD0="20.210.153.48"   # cyshih-osd-0 (osd.0/osd.1)
export OSD1="20.78.185.18"    # cyshih-osd-1 (osd.2/osd.3)
export OSD2="104.46.229.178"  # cyshih-osd-2 (osd.4/osd.5)
export K8SCP="20.78.164.180"  # cyshih-k8s-0 (kubectl)
export K8SW1="20.210.162.220" # cyshih-k8s-1
export K8SW2="20.89.217.176"  # cyshih-k8s-2
export FSID="fbae2fb0-7eb8-11f1-b6cd-3daca6682563"
export POOL="kubevirt"
export MON1_PRIV="10.0.2.7"    # mon-0 ceph public net (for ceph.conf on clients)
export MON2_PRIV="10.0.2.4"
export MON3_PRIV="10.0.2.9"

# SSHO 字串保留給 bash 執行的 run 腳本（有 word-splitting）用；互動 zsh helper 一律 literal flag。
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
export SSHO
s(){ ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 "$@"; }
ceph_c(){ s ${SSHUSER}@${MON1} "sudo ceph $*"; }
kc(){ s ${SSHUSER}@${K8SCP} "kubectl $*"; }
# guest: VMI 起來後設 GUEST_IP，經 CP 跳板（ProxyCommand，ProxyJump 段吃不到 key）
vmx(){ ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ProxyCommand="ssh -i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ${SSHUSER}@${K8SCP}" ubuntu@"$GUEST_IP" "$@"; }
# scp helper（literal flag，zsh 不 word-split 變數字串，切勿用 $SSHO）
scpf(){ scp -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }
