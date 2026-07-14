#!/bin/bash
echo "PREFILL-START $(date -u +%s)" > /home/azureuser/e02/status
sudo fio --name=prefill --filename=/dev/rbd0 --rw=write --bs=1M --iodepth=8 --direct=1 --size=100% --output=/home/azureuser/e02/prefill.txt >/dev/null 2>&1
echo "PREFILL-DONE $(date -u +%s)" >> /home/azureuser/e02/status
for N in 1 2 3; do
  echo "ROUND-$N-START $(date -u +%s)" >> /home/azureuser/e02/status
  bash /home/azureuser/host_matrix.sh /home/azureuser/e02/round-$N
  echo "ROUND-$N-DONE $(date -u +%s)" >> /home/azureuser/e02/status
done
echo "ALL-DONE $(date -u +%s)" >> /home/azureuser/e02/status
