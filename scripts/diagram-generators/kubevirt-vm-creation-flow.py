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
ROSE = '#f47067'
TEAL = '#39c5cf'

fig, ax = plt.subplots(figsize=(15, 8))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 15)
ax.set_ylim(0, 8)
ax.axis('off')

ax.text(7.5, 7.65, 'KubeVirt: VM Lifecycle — from kubectl to QEMU', color=TEXT,
        fontsize=15, fontweight='bold', ha='center')
ax.text(7.5, 7.25, 'Component call chain when creating a VirtualMachineInstance', color=MUTED,
        fontsize=10, ha='center')

# Top row: creation chain
chain = [
    (1.2, 5.5, 'User\nkubectl apply\nVM CRD', ACCENT),
    (3.8, 5.5, 'virt-api\nWebhook\nValidation', ROSE),
    (6.5, 5.5, 'virt-controller\nVM → VMI\nCreate', ROSE),
    (9.2, 5.5, 'virt-controller\nVMI → Pod\n(virt-launcher)', ROSE),
    (12.0, 5.5, 'Kubernetes\nScheduler\nNode select', ACCENT),
]

node_w, node_h = 2.0, 1.3
for (x, y, label, color) in chain:
    rect = FancyBboxPatch((x - node_w / 2, y - node_h / 2), node_w, node_h,
                          boxstyle="round,pad=0.1", linewidth=2,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y, label, color=color, fontsize=8.5, fontweight='bold',
            ha='center', va='center', zorder=4)

for i in range(len(chain) - 1):
    x1 = chain[i][0] + node_w / 2
    x2 = chain[i + 1][0] - node_w / 2
    ax.annotate('', xy=(x2, 5.5), xytext=(x1, 5.5),
                arrowprops=dict(arrowstyle='->', color=MUTED, lw=1.5))

# Step numbers
labels_top = ['①', '②', '③', '④', '⑤']
for idx, (x, y, _, _) in enumerate(chain):
    ax.text(x, y + node_h / 2 + 0.15, labels_top[idx], color=MUTED, fontsize=9, ha='center')

# Bottom row: node-level execution
node_chain = [
    (1.5, 2.5, 'virt-handler\nWatches VMI\non this Node', GREEN),
    (4.5, 2.5, 'virt-handler\nCalls gRPC\nSyncVMI', GREEN),
    (7.5, 2.5, 'virt-launcher\nConverts VMI\nto Domain XML', TEAL),
    (10.5, 2.5, 'libvirt\nStarts QEMU\nprocess', TEAL),
    (13.5, 2.5, 'QEMU/KVM\nVM is running\nHardware-accelerated', GREEN),
]

for (x, y, label, color) in node_chain:
    rect = FancyBboxPatch((x - node_w / 2, y - node_h / 2), node_w, node_h,
                          boxstyle="round,pad=0.1", linewidth=2,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y, label, color=color, fontsize=8.5, fontweight='bold',
            ha='center', va='center', zorder=4)

for i in range(len(node_chain) - 1):
    x1 = node_chain[i][0] + node_w / 2
    x2 = node_chain[i + 1][0] - node_w / 2
    ax.annotate('', xy=(x2, 2.5), xytext=(x1, 2.5),
                arrowprops=dict(arrowstyle='->', color=MUTED, lw=1.5))

labels_bot = ['⑥', '⑦', '⑧', '⑨', '⑩']
for idx, (x, y, _, _) in enumerate(node_chain):
    ax.text(x, y + node_h / 2 + 0.15, labels_bot[idx], color=MUTED, fontsize=9, ha='center')

# Vertical arrow: scheduler → node
ax.annotate('', xy=(12.0, 4.2), xytext=(12.0, 5.5 - node_h / 2),
            arrowprops=dict(arrowstyle='->', color=YELLOW, lw=1.5))
ax.annotate('', xy=(1.5, 3.15), xytext=(12.0, 4.2),
            arrowprops=dict(arrowstyle='->', color=YELLOW, lw=1.5, connectionstyle='arc3,rad=-0.2'))
ax.text(7.5, 3.9, 'VMI scheduled → Node: DaemonSet virt-handler triggers', color=YELLOW, fontsize=8.5, ha='center')

ax.text(7.5, 6.75, '── Control Plane (API + Controller) ──', color=ROSE, fontsize=8.5, ha='center')
ax.text(7.5, 1.35, '── Data Plane (Node-level: virt-handler + virt-launcher + QEMU) ──', color=GREEN, fontsize=8.5, ha='center')

plt.tight_layout()
plt.savefig('/home/runner/work/molearn/molearn/next-site/public/diagrams/kubevirt/vm-creation-flow.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved kubevirt/vm-creation-flow.png")
