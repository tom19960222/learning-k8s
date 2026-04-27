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
ROSE = '#f47067'
ORANGE = '#e3854b'
TEAL = '#39c5cf'

fig, ax = plt.subplots(figsize=(16, 10))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 16)
ax.set_ylim(0, 10)
ax.axis('off')

ax.text(8, 9.6, 'KubeVirt Feature Map', color=TEXT, fontsize=18, fontweight='bold', ha='center')
ax.text(8, 9.2, 'Run Virtual Machines on Kubernetes', color=MUTED, fontsize=11, ha='center')


def draw_group(ax, gx, gy, gw, gh, title, color, items):
    rect = FancyBboxPatch((gx, gy), gw, gh,
                          boxstyle="round,pad=0.15", linewidth=2,
                          edgecolor=color, facecolor=SURFACE, zorder=1)
    ax.add_patch(rect)
    ax.text(gx + gw / 2, gy + gh - 0.25, title,
            color=color, fontsize=10, fontweight='bold', ha='center', va='top', zorder=2)
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
    ax.text(cx, cy + 0.3, title, color=color, fontsize=12, fontweight='bold',
            ha='center', va='center', zorder=6)
    ax.text(cx, cy - 0.3, subtitle, color=MUTED, fontsize=8.5,
            ha='center', va='center', zorder=6)


# Central box
draw_center(ax, 8, 5.0, 3.4, 1.8,
            'virt-controller', 'Deployment: Leader election\nVM/VMI/Migration lifecycle', ROSE)

# --- Left: API & Entry ---
draw_group(ax, 0.3, 2.5, 3.4, 5.5, '🔌  API & 入口', ACCENT, [
    ('virt-api', ACCENT),
    ('VirtualMachine CRD', ACCENT),
    ('VirtualMachineInstance CRD', ACCENT),
    ('Validating / Mutating Webhook', ACCENT),
])

# --- Center-Left: VM Lifecycle ---
draw_group(ax, 4.0, 2.5, 3.4, 5.5, '🖥  VM 生命週期', PURPLE, [
    ('VM Controller (RunStrategy)', PURPLE),
    ('VMI Controller (Pod 建立)', PURPLE),
    ('VMI Phase 狀態機', PURPLE),
    ('virt-handler (DaemonSet)', PURPLE),
])

# --- Center-Right: Storage & Network ---
draw_group(ax, 8.6, 2.5, 3.4, 5.5, '💾🌐  儲存 & 網路', GREEN, [
    ('DataVolume / CDI', GREEN),
    ('PVC Boot Disk', GREEN),
    ('Multus 多網卡', GREEN),
    ('Bridge / SR-IOV / Masquerade', GREEN),
])

# --- Right: Runtime & Migration ---
draw_group(ax, 12.3, 2.5, 3.4, 5.5, '⚙  Runtime & 遷移', YELLOW, [
    ('virt-launcher Pod (per VM)', YELLOW),
    ('QEMU / KVM 行程', YELLOW),
    ('libvirt Domain Manager', YELLOW),
    ('Live Migration (VMIMigration)', YELLOW),
])

# Arrows
def arrow(ax, x1, y1, x2, y2, color, label=''):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle='<->', color=color, lw=1.6,
                                connectionstyle='arc3,rad=0.0'))
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        ax.text(mx, my + 0.12, label, color=color, fontsize=7.5, ha='center',
                bbox=dict(boxstyle='round,pad=0.1', facecolor=BG_COLOR, edgecolor='none'))


arrow(ax, 6.4, 5.2, 3.7, 5.2, ACCENT, 'admits/watches')
arrow(ax, 6.4, 4.8, 7.4, 4.8, PURPLE, 'is')
arrow(ax, 9.6, 5.2, 8.6, 5.2, GREEN, 'attaches')
arrow(ax, 9.6, 4.8, 12.3, 4.8, YELLOW, 'spawns')

# Bottom legend
legend_items = [
    (ACCENT, 'API & 入口'),
    (PURPLE, 'VM 生命週期'),
    (GREEN, '儲存 & 網路'),
    (YELLOW, 'Runtime & 遷移'),
    (ROSE, 'virt-controller (核心)'),
]
lx = 1.2
for color, label in legend_items:
    ax.add_patch(FancyBboxPatch((lx - 0.15, 1.1), 0.3, 0.3,
                                boxstyle="round,pad=0.05", linewidth=0,
                                edgecolor='none', facecolor=color))
    ax.text(lx + 0.25, 1.25, label, color=TEXT, fontsize=8, va='center')
    lx += 2.8

plt.tight_layout()
plt.savefig('/home/runner/work/molearn/molearn/next-site/public/diagrams/kubevirt/feature-map.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved kubevirt/feature-map.png")
