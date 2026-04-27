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
TEAL = '#39c5cf'

fig, ax = plt.subplots(figsize=(16, 10))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 16)
ax.set_ylim(0, 10)
ax.axis('off')

ax.text(8, 9.6, 'KubeVirt Architecture', color=TEXT, fontsize=17, fontweight='bold', ha='center')
ax.text(8, 9.2, 'VM-as-a-Pod: Running QEMU/KVM inside Kubernetes', color=MUTED, fontsize=11, ha='center')


def draw_box(ax, x, y, w, h, title, subtitle, color, zorder=3):
    rect = FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                          boxstyle="round,pad=0.12", linewidth=2,
                          edgecolor=color, facecolor=SURFACE2, zorder=zorder)
    ax.add_patch(rect)
    ax.text(x, y + h / 4, title, color=color, fontsize=9, fontweight='bold',
            ha='center', va='center', zorder=zorder + 1)
    if subtitle:
        ax.text(x, y - h / 4, subtitle, color=MUTED, fontsize=7.5,
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


# === Layer 1: User / kubectl ===
draw_layer(ax, 0.3, 8.0, 15.4, 1.6, 'User / Kubernetes API Server', ACCENT)
draw_box(ax, 3.2, 8.8, 2.8, 0.9, 'kubectl / virtctl', 'VM / VMI operations', ACCENT)
draw_box(ax, 7.5, 8.8, 3.2, 0.9, 'VirtualMachine CRD\nVirtualMachineInstance CRD', 'Persisted in etcd', ACCENT)
draw_box(ax, 12.0, 8.8, 3.0, 0.9, 'virt-api', 'Webhook + Subresource\n/vnc /console /migrate', ROSE)

# === Layer 2: virt-controller ===
draw_layer(ax, 0.3, 5.7, 15.4, 1.9, 'virt-controller (Deployment — runs on control-plane)', ROSE)
draw_box(ax, 3.5, 6.65, 3.2, 1.1, 'VM Controller', 'RunStrategy → create/delete VMI', ROSE)
draw_box(ax, 8.0, 6.65, 3.2, 1.1, 'VMI Controller', 'Create virt-launcher Pod\nTrack Pod → VMI phase', PURPLE)
draw_box(ax, 12.5, 6.65, 2.8, 1.1, 'Migration Controller', 'Source + target Pod\ncoordination', YELLOW)

# === Layer 3: virt-handler (per node) ===
draw_layer(ax, 0.3, 3.2, 15.4, 2.1, 'virt-handler (DaemonSet — runs on every Node)', GREEN)
draw_box(ax, 3.5, 4.25, 3.2, 1.1, 'VMI Watcher', 'Watches VMI on this node\nCalls virt-launcher via gRPC', GREEN)
draw_box(ax, 8.0, 4.25, 3.2, 1.1, 'Network Config', 'CNI plugin call\nMultus / bridge / SR-IOV', GREEN)
draw_box(ax, 12.5, 4.25, 2.8, 1.1, 'Live Migration\nSource Proxy', 'Memory migration\ntransfer channel', YELLOW)

# === Layer 4: virt-launcher Pod (one per VM) ===
draw_layer(ax, 0.3, 0.4, 15.4, 2.5, 'virt-launcher Pod (one per VirtualMachineInstance)', TEAL)
draw_box(ax, 3.5, 1.65, 3.0, 1.4, 'virt-launcher\nmain process', 'gRPC server: SyncVMI\nKillVMI / MigrateVMI', TEAL)
draw_box(ax, 8.0, 1.65, 3.0, 1.4, 'libvirt (libvirtd)\n+ QEMU/KVM', 'Domain XML → QEMU args\nHardware virtualization', TEAL)
draw_box(ax, 12.5, 1.65, 2.8, 1.4, 'Storage\nPVC / DataVolume', 'Boot disk via CSI\nHotplug volumes', GREEN)

# Arrows
arr(ax, 7.5, 8.35, 7.5, 7.6, ACCENT, 'Watch/Update', bidirectional=True)
arr(ax, 3.5, 6.1, 3.5, 5.3, ROSE, '', bidirectional=True)
arr(ax, 8.0, 6.1, 8.0, 5.3, PURPLE, '', bidirectional=True)
arr(ax, 12.5, 6.1, 12.5, 5.3, YELLOW, '', bidirectional=True)
arr(ax, 3.5, 3.8, 3.5, 2.95, GREEN, 'gRPC', bidirectional=True)
arr(ax, 8.0, 3.8, 8.0, 2.95, GREEN, '', bidirectional=True)

plt.tight_layout()
plt.savefig('/home/runner/work/molearn/molearn/next-site/public/diagrams/kubevirt/architecture.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved kubevirt/architecture.png")
