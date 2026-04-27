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

ax.text(8, 9.6, 'Rook Feature Map', color=TEXT, fontsize=18, fontweight='bold', ha='center')
ax.text(8, 9.2, 'Kubernetes-Native Storage Orchestrator (CNCF Graduated)', color=MUTED, fontsize=11, ha='center')


def draw_group(ax, gx, gy, gw, gh, title, color, items):
    """Draw a feature group box with items inside."""
    rect = FancyBboxPatch((gx, gy), gw, gh,
                          boxstyle="round,pad=0.15", linewidth=2,
                          edgecolor=color, facecolor=SURFACE, zorder=1)
    ax.add_patch(rect)
    ax.text(gx + gw / 2, gy + gh - 0.25, title,
            color=color, fontsize=10, fontweight='bold', ha='center', va='top', zorder=2)
    # Draw item cards
    item_h = 0.42
    item_w = gw - 0.4
    start_y = gy + gh - 0.6
    for i, (item_label, item_color) in enumerate(items):
        iy = start_y - i * (item_h + 0.1)
        item_rect = FancyBboxPatch((gx + 0.2, iy - item_h), item_w, item_h,
                                   boxstyle="round,pad=0.06", linewidth=1,
                                   edgecolor=item_color, facecolor=SURFACE2, zorder=3)
        ax.add_patch(item_rect)
        ax.text(gx + 0.2 + item_w / 2, iy - item_h / 2, item_label,
                color=TEXT, fontsize=8.2, ha='center', va='center', zorder=4)


def draw_center(ax, cx, cy, w, h, title, subtitle, color):
    rect = FancyBboxPatch((cx - w / 2, cy - h / 2), w, h,
                          boxstyle="round,pad=0.15", linewidth=2.5,
                          edgecolor=color, facecolor=SURFACE2, zorder=5)
    ax.add_patch(rect)
    ax.text(cx, cy + 0.22, title, color=color, fontsize=13, fontweight='bold',
            ha='center', va='center', zorder=6)
    ax.text(cx, cy - 0.25, subtitle, color=MUTED, fontsize=9,
            ha='center', va='center', zorder=6)


# Central: Rook Operator
draw_center(ax, 8, 5.0, 3.2, 1.6,
            'Rook Operator', 'Kubernetes Controller Manager\nReconciles all CephCRD resources', TEAL)

# --- Left: Ceph Core ---
draw_group(ax, 0.3, 2.5, 3.4, 5.5, '🗄  Ceph 核心元件', ACCENT, [
    ('Monitor (mon)', ACCENT),
    ('Manager (mgr)', ACCENT),
    ('OSD Daemon', ACCENT),
    ('MDS (CephFS)', ACCENT),
])

# --- Center-Left: Operator Controllers ---
draw_group(ax, 4.0, 2.5, 3.4, 5.5, '🔄  Operator Controllers', PURPLE, [
    ('CephCluster Controller', PURPLE),
    ('CephBlockPool Controller', PURPLE),
    ('CephFilesystem Controller', PURPLE),
    ('CephObjectStore Controller', PURPLE),
])

# --- Center-Right: Storage Services ---
draw_group(ax, 8.6, 2.5, 3.4, 5.5, '💾  儲存服務', GREEN, [
    ('Block Storage (RBD)', GREEN),
    ('Shared Filesystem (CephFS)', GREEN),
    ('Object Storage (RGW/S3)', GREEN),
    ('StorageClass + PVC', GREEN),
])

# --- Right: Data Path ---
draw_group(ax, 12.3, 2.5, 3.4, 5.5, '📡  資料路徑', YELLOW, [
    ('CSI Driver (rbd / cephfs)', YELLOW),
    ('Dynamic Provisioning', YELLOW),
    ('Volume Attach / Mount', YELLOW),
    ('OBC (ObjectBucketClaim)', YELLOW),
])

# Draw arrows from center to groups
def arrow(ax, x1, y1, x2, y2, color):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle='<->', color=color, lw=1.6,
                                connectionstyle='arc3,rad=0.0'))

# Center ↔ Ceph Core
arrow(ax, 6.4, 5.0, 3.7, 5.0, ACCENT)
ax.text(5.05, 5.15, 'manages', color=ACCENT, fontsize=7.5, ha='center')

# Center ↔ Operator Controllers
arrow(ax, 6.4, 5.2, 7.4, 5.2, PURPLE)
ax.text(6.9, 5.35, 'is', color=PURPLE, fontsize=7.5, ha='center')

# Center ↔ Storage Services
arrow(ax, 9.6, 5.0, 8.6, 5.0, GREEN)
ax.text(9.1, 5.15, 'exposes', color=GREEN, fontsize=7.5, ha='center')

# Center ↔ Data Path
arrow(ax, 9.6, 4.8, 12.3, 4.8, YELLOW)
ax.text(10.95, 4.95, 'delivers via', color=YELLOW, fontsize=7.5, ha='center')

# Bottom legend
legend_items = [
    (ACCENT, 'Ceph Core'),
    (PURPLE, 'Operator Controllers'),
    (GREEN, 'Storage Services'),
    (YELLOW, 'Data Path (CSI)'),
    (TEAL, 'Rook Operator (Central)'),
]
lx = 1.2
for color, label in legend_items:
    patch = mpatches.Patch(color=color, label=label)
    ax.add_patch(FancyBboxPatch((lx - 0.15, 1.1), 0.3, 0.3,
                                boxstyle="round,pad=0.05", linewidth=0,
                                edgecolor='none', facecolor=color))
    ax.text(lx + 0.25, 1.25, label, color=TEXT, fontsize=8, va='center')
    lx += 2.8

plt.tight_layout()
plt.savefig('/home/runner/work/molearn/molearn/next-site/public/diagrams/rook/feature-map.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved rook/feature-map.png")
