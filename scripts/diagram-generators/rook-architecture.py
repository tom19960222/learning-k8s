import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch

BG_COLOR = '#0d1117'
SURFACE = '#161b22'
SURFACE2 = '#21262d'
BORDER = '#30363d'
ACCENT = '#2f81f7'
TEXT = '#e6edf3'
MUTED = '#8b949e'
GREEN = '#3fb950'
YELLOW = '#d29922'
PURPLE = '#6e40c9'
TEAL = '#39c5cf'
RED = '#f85149'
ORANGE = '#e3854b'

fig, ax = plt.subplots(figsize=(16, 10))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 16)
ax.set_ylim(0, 10)
ax.axis('off')

ax.text(8, 9.6, 'Rook Architecture: Kubernetes Storage Operator', color=TEXT, fontsize=17, fontweight='bold', ha='center')


def draw_box(ax, x, y, w, h, title, subtitle, color, zorder=3):
    rect = FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                          boxstyle="round,pad=0.12", linewidth=2,
                          edgecolor=color, facecolor=SURFACE2, zorder=zorder)
    ax.add_patch(rect)
    ax.text(x, y + h / 4, title, color=color, fontsize=9.5, fontweight='bold',
            ha='center', va='center', zorder=zorder + 1)
    if subtitle:
        ax.text(x, y - h / 4, subtitle, color=MUTED, fontsize=7.8,
                ha='center', va='center', zorder=zorder + 1)


def draw_layer(ax, lx, ly, lw, lh, label, color):
    rect = FancyBboxPatch((lx, ly), lw, lh,
                          boxstyle="round,pad=0.1", linewidth=1.8,
                          edgecolor=color, facecolor=SURFACE, zorder=1)
    ax.add_patch(rect)
    ax.text(lx + 0.25, ly + lh - 0.2, label,
            color=color, fontsize=9, fontweight='bold', va='top', zorder=2)


def arr(ax, x1, y1, x2, y2, color, label='', bidirectional=True, rad=0.0):
    style = '<->' if bidirectional else '->'
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle=style, color=color, lw=1.5,
                                connectionstyle=f'arc3,rad={rad}'))
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        ax.text(mx, my + 0.12, label, color=color, fontsize=7.5, ha='center',
                bbox=dict(boxstyle='round,pad=0.1', facecolor=BG_COLOR, edgecolor='none'))


# === Layer 1: User / Kubernetes API ===
draw_layer(ax, 0.3, 8.0, 15.4, 1.5, 'Kubernetes Control Plane', ACCENT)
draw_box(ax, 3.2, 8.75, 2.8, 0.9, 'kubectl / Helm', 'User applies CRDs', ACCENT)
draw_box(ax, 7.2, 8.75, 3.0, 0.9, 'CephCluster CRD', 'CephBlockPool / CephFS\nCephObjectStore', ACCENT)
draw_box(ax, 11.8, 8.75, 3.0, 0.9, 'StorageClass + PVC', 'Kubernetes storage\nrequests', ACCENT)

# === Layer 2: Rook Operator ===
draw_layer(ax, 0.3, 5.6, 15.4, 2.0, 'Rook Operator (rook-ceph namespace)', TEAL)
draw_box(ax, 3.0, 6.6, 3.0, 1.1, 'Cluster Controller', 'Reconciles CephCluster\nStarts mon/mgr/osd', TEAL)
draw_box(ax, 7.2, 6.6, 3.0, 1.1, 'Pool / FS / ObjStore\nControllers', 'Reconcile storage pools,\nFilesystems, Object stores', PURPLE)
draw_box(ax, 11.8, 6.6, 3.0, 1.1, 'CSI Provisioner\n(side-car)', 'Handles CreateVolume\nDeleteVolume via gRPC', YELLOW)

# === Layer 3: Ceph Daemons ===
draw_layer(ax, 0.3, 2.8, 15.4, 2.4, 'Ceph Storage Plane (rook-ceph pods)', GREEN)
draw_box(ax, 2.5, 4.0, 2.8, 1.1, 'Monitor (mon×3)', 'Cluster Map quorum\n& membership', GREEN)
draw_box(ax, 5.8, 4.0, 2.4, 1.1, 'Manager (mgr)', 'Dashboard, Prometheus\nmetrics & modules', GREEN)
draw_box(ax, 9.0, 4.0, 2.8, 1.1, 'OSD (per disk)', 'BlueStore data write\n& replication', GREEN)
draw_box(ax, 13.0, 4.0, 2.8, 1.1, 'RGW / MDS', 'S3 Object Store\n& CephFS metadata', GREEN)

# === Layer 4: Physical ===
draw_layer(ax, 0.3, 0.4, 15.4, 2.0, 'Physical / Cloud Infrastructure', MUTED)
draw_box(ax, 3.2, 1.4, 2.8, 0.9, 'Node Disks (NVMe/SSD)', 'Raw block devices', MUTED)
draw_box(ax, 7.2, 1.4, 2.8, 0.9, 'Network (Ceph traffic)', '10GbE+ recommended', MUTED)
draw_box(ax, 11.8, 1.4, 2.8, 0.9, 'Node × N (≥3)', 'K8s worker nodes', MUTED)

# Arrows layer1 -> layer2
arr(ax, 7.2, 8.3, 7.2, 7.65, ACCENT, 'watch/reconcile', bidirectional=True)

# Arrows layer2 -> layer3
arr(ax, 3.0, 6.05, 2.5, 5.15, TEAL, '', bidirectional=True)
arr(ax, 7.2, 6.05, 5.8, 5.15, PURPLE, '', bidirectional=True)
arr(ax, 9.0, 6.05, 9.0, 5.15, GREEN, '', bidirectional=True)
arr(ax, 11.8, 6.05, 13.0, 5.15, YELLOW, '', bidirectional=True)

# Arrows layer3 -> layer4
arr(ax, 9.0, 3.45, 9.0, 2.4, GREEN, '', bidirectional=False)
arr(ax, 3.2, 3.45, 3.2, 2.4, GREEN, '', bidirectional=False)

plt.tight_layout()
plt.savefig('/home/runner/work/molearn/molearn/next-site/public/diagrams/rook/architecture.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved rook/architecture.png")
