import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

BG_COLOR = '#0d1117'
SURFACE = '#161b22'
SURFACE2 = '#21262d'
ACCENT = '#2f81f7'
TEXT = '#e6edf3'
MUTED = '#8b949e'
GREEN = '#3fb950'
YELLOW = '#d29922'
PURPLE = '#6e40c9'
TEAL = '#39c5cf'
RED = '#f85149'

fig, ax = plt.subplots(figsize=(15, 8))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 15)
ax.set_ylim(0, 8)
ax.axis('off')

ax.text(7.5, 7.65, 'Rook Storage Request Flow: PVC → Ceph RBD', color=TEXT,
        fontsize=15, fontweight='bold', ha='center')
ax.text(7.5, 7.25, 'How a PersistentVolumeClaim translates into a Ceph block device', color=MUTED,
        fontsize=10, ha='center')

steps = [
    (1.2, 4.5, 'App Pod', 'kubectl apply\nPVC', ACCENT),
    (3.6, 4.5, 'PVC\n(StorageClass: rook-ceph-block)', 'Kubernetes\nStorage Object', ACCENT),
    (6.2, 4.5, 'CSI Provisioner\n(rook-ceph-csi-rbdplugin)', 'Handles\nCreateVolume gRPC', YELLOW),
    (9.0, 4.5, 'Ceph RBD API\n(via librbd)', 'Creates RBD\nimage in pool', GREEN),
    (12.0, 4.5, 'OSD Cluster\n(data replicated)', 'Writes to\nNVMe/SSD', GREEN),
]

node_w, node_h = 2.2, 1.2
for (x, y, title, subtitle, color) in steps:
    rect = FancyBboxPatch((x - node_w / 2, y - node_h / 2), node_w, node_h,
                          boxstyle="round,pad=0.1", linewidth=2,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y + 0.2, title, color=color, fontsize=9, fontweight='bold',
            ha='center', va='center', zorder=4)
    ax.text(x, y - 0.25, subtitle, color=MUTED, fontsize=8,
            ha='center', va='center', zorder=4)

# Arrows
arrow_labels = ['申請 PVC', 'notify\nprovisioner', 'CreateVolume\n(gRPC)', 'rbd create\nimage']
for i in range(len(steps) - 1):
    x1 = steps[i][0] + node_w / 2
    x2 = steps[i + 1][0] - node_w / 2
    y_mid = 4.5
    ax.annotate('', xy=(x2, y_mid), xytext=(x1, y_mid),
                arrowprops=dict(arrowstyle='->', color=MUTED, lw=1.5))
    lx = (x1 + x2) / 2
    ax.text(lx, y_mid + 0.5, arrow_labels[i], color=MUTED, fontsize=7.5, ha='center')

# Step numbers
for idx, (x, y, _, _, _) in enumerate(steps, 1):
    circle = plt.Circle((x - node_w / 2 + 0.25, y + node_h / 2 - 0.25), 0.2, color=ACCENT, zorder=5)
    ax.add_patch(circle)
    ax.text(x - node_w / 2 + 0.25, y + node_h / 2 - 0.25, str(idx),
            color=TEXT, fontsize=8, fontweight='bold', ha='center', va='center', zorder=6)

# Reverse path (mount)
mount_steps = [
    (1.2, 2.5, 'Pod 啟動\n掛載 Volume', ACCENT),
    (4.2, 2.5, 'kubelet 呼叫\nCSI NodeStageVolume', YELLOW),
    (7.5, 2.5, 'rbd map → /dev/rbd0\n(kernel module)', GREEN),
    (11.5, 2.5, 'mount /dev/rbd0\nto Pod mount path', GREEN),
]
for (x, y, label, color) in mount_steps:
    rect = FancyBboxPatch((x - 1.5, y - 0.5), 3.0, 1.0,
                          boxstyle="round,pad=0.08", linewidth=1.5,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y, label, color=color, fontsize=8.5, ha='center', va='center',
            fontweight='bold', zorder=4)

for i in range(len(mount_steps) - 1):
    x1 = mount_steps[i][0] + 1.5
    x2 = mount_steps[i + 1][0] - 1.5
    ax.annotate('', xy=(x2, 2.5), xytext=(x1, 2.5),
                arrowprops=dict(arrowstyle='->', color=MUTED, lw=1.5))

ax.text(7.5, 1.4, 'Volume Mount Path', color=MUTED, fontsize=9, ha='center')
ax.text(7.5, 3.6, '── Provision Flow (PVC 建立) ──', color=ACCENT, fontsize=9, ha='center')
ax.text(7.5, 1.85, '── Mount Flow (Pod 啟動掛載) ──', color=GREEN, fontsize=9, ha='center')

plt.tight_layout()
plt.savefig('/home/runner/work/molearn/molearn/next-site/public/diagrams/rook/storage-request-flow.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved rook/storage-request-flow.png")
