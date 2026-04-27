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

fig, ax = plt.subplots(figsize=(14, 8))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 14)
ax.set_ylim(0, 8)
ax.axis('off')

ax.text(7, 7.6, 'MAAS Provider Interaction Architecture', color=TEXT, fontsize=16, fontweight='bold', ha='center')

# Layer definitions: (y_bottom, height, label, color, items)
layers = [
    (5.2, 1.7, 'Kubernetes (CAPI) Layer', ACCENT,
     ['Cluster', 'Machine', 'MachineDeployment', 'MachineSet']),
    (2.8, 1.9, 'MAAS Provider Layer', PURPLE,
     ['MaasCluster Controller', 'MaasMachine Controller', 'MaasCluster CR', 'MaasMachine CR']),
    (0.4, 1.9, 'MAAS Platform Layer', GREEN,
     ['MAAS API Server', 'DNS Service', 'Physical Machine 1', 'Physical Machine 2']),
]

for (y_bot, h, label, color, items) in layers:
    rect = FancyBboxPatch((0.3, y_bot), 13.4, h,
                          boxstyle="round,pad=0.1", linewidth=2,
                          edgecolor=color, facecolor=SURFACE,
                          zorder=1)
    ax.add_patch(rect)
    ax.text(0.7, y_bot + h - 0.25, label, color=color, fontsize=10, fontweight='bold', va='top', zorder=2)

    # Items inside layer
    n = len(items)
    xs = [1.5 + i * (12.0 / (n)) + 6.0/n - 0.5 for i in range(n)]
    for xi, item in zip(xs, items):
        box = FancyBboxPatch((xi - 1.1, y_bot + 0.2), 2.2, 0.8,
                             boxstyle="round,pad=0.08", linewidth=1.2,
                             edgecolor=color, facecolor=SURFACE2, zorder=3)
        ax.add_patch(box)
        ax.text(xi, y_bot + 0.6, item, color=TEXT, fontsize=8.5, ha='center', va='center',
                fontweight='bold', zorder=4)

# Arrows between layers
arrow_props = dict(arrowstyle='<->', color=MUTED, lw=1.8, connectionstyle='arc3,rad=0')

# CAPI <-> Provider
for xi in [3.5, 7.0, 10.5]:
    ax.annotate('', xy=(xi, 5.2), xytext=(xi, 4.7),
                arrowprops=dict(arrowstyle='<->', color=ACCENT, lw=1.5))

# Provider <-> MAAS
for xi in [3.5, 7.0, 10.5]:
    ax.annotate('', xy=(xi, 2.8), xytext=(xi, 2.3),
                arrowprops=dict(arrowstyle='<->', color=PURPLE, lw=1.5))

# Arrow labels
ax.text(11.5, 4.95, 'Watch/Reconcile CR', color=ACCENT, fontsize=7.5, ha='center')
ax.text(11.5, 2.55, 'MAAS REST API', color=PURPLE, fontsize=7.5, ha='center')

plt.tight_layout()
plt.savefig('/Users/hwchiu/hwchiu/code/molearn/next-site/public/diagrams/maas/interaction-architecture.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved interaction-architecture.png")
