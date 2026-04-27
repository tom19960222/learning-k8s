import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
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
RED = '#f85149'

fig, ax = plt.subplots(figsize=(13, 9))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 13)
ax.set_ylim(0, 9)
ax.axis('off')

ax.text(6.5, 8.6, 'CAPI Provider Ecosystem Interaction', color=TEXT, fontsize=16, fontweight='bold', ha='center')

def draw_box(ax, x, y, w, h, title, subtitle, color):
    rect = FancyBboxPatch((x - w/2, y - h/2), w, h,
                          boxstyle="round,pad=0.12", linewidth=2,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y + 0.22, title, color=color, fontsize=10, fontweight='bold',
            ha='center', va='center', zorder=4)
    ax.text(x, y - 0.22, subtitle, color=MUTED, fontsize=8,
            ha='center', va='center', zorder=4)

# Core CAPI (center)
core_x, core_y = 6.5, 4.5
draw_box(ax, core_x, core_y, 3.6, 2.0, 'Core CAPI', 'Cluster / Machine / MachineSet\nMachineDeployment', ACCENT)

# Infrastructure Provider (right-top)
infra_x, infra_y = 11.0, 6.8
draw_box(ax, infra_x, infra_y, 3.4, 1.8, 'Infrastructure Provider', 'MAAS / Metal3 / AWS\nBuilds VM / Bare Metal', GREEN)

# Bootstrap Provider (right-bottom)
boot_x, boot_y = 11.0, 2.2
draw_box(ax, boot_x, boot_y, 3.4, 1.8, 'Bootstrap Provider', 'Kubeadm Bootstrap\nGenerates cloud-init', YELLOW)

# Control Plane Provider (left)
cp_x, cp_y = 2.0, 4.5
draw_box(ax, cp_x, cp_y, 3.4, 1.8, 'Control Plane\nProvider', 'KubeadmControlPlane\nManages CP lifecycle', PURPLE)

def arrow(ax, x1, y1, x2, y2, label, color, dx=0, dy=0):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle='<->', color=color, lw=1.8,
                                connectionstyle='arc3,rad=0.0'))
    mx, my = (x1+x2)/2 + dx, (y1+y2)/2 + dy
    ax.text(mx, my, label, color=color, fontsize=7.5, ha='center', va='center',
            bbox=dict(boxstyle='round,pad=0.15', facecolor=BG_COLOR, edgecolor='none'))

# Core <-> Infra
arrow(ax, core_x + 1.8, core_y + 0.5, infra_x - 1.7, infra_y - 0.3,
      'owns InfraCluster\n/ InfraMachine', GREEN, dx=0.1, dy=0)

# Core <-> Bootstrap
arrow(ax, core_x + 1.8, core_y - 0.5, boot_x - 1.7, boot_y + 0.3,
      'owns BootstrapConfig\nrequest secret', YELLOW, dx=0.1, dy=0)

# Core <-> CP
arrow(ax, core_x - 1.8, core_y, cp_x + 1.7, cp_y,
      'owns KCP\ndelegates init', PURPLE, dx=0, dy=0.25)

# CP -> Bootstrap (CP also uses bootstrap)
ax.annotate('', xy=(boot_x - 1.7, boot_y + 0.5), xytext=(cp_x + 1.2, cp_y - 0.6),
            arrowprops=dict(arrowstyle='->', color=MUTED, lw=1.4,
                            connectionstyle='arc3,rad=-0.3'))
ax.text(6.5, 1.2, 'KCP uses Bootstrap to generate init data for Control Plane nodes',
        color=MUTED, fontsize=8, ha='center')

# Responsibility labels
for (x, y, label, color) in [
    (infra_x, infra_y - 1.4, 'Responsibility: Provision real infra\n(allocate, deploy, configure)', GREEN),
    (boot_x, boot_y - 1.4, 'Responsibility: Produce cloud-init\nsecret for node bootstrap', YELLOW),
    (cp_x, cp_y - 1.4, 'Responsibility: Manage etcd,\nkubeadm init, upgrade', PURPLE),
]:
    ax.text(x, y, label, color=color, fontsize=7.5, ha='center', va='center',
            style='italic')

plt.tight_layout()
plt.savefig('/Users/hwchiu/hwchiu/code/molearn/next-site/public/diagrams/capi/provider-interaction.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved provider-interaction.png")
