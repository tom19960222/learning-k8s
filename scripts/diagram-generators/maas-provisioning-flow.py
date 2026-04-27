import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import matplotlib.font_manager as fm

BG_COLOR = '#0d1117'
SURFACE = '#161b22'
SURFACE2 = '#21262d'
BORDER = '#30363d'
ACCENT = '#2f81f7'
TEXT = '#e6edf3'
MUTED = '#8b949e'
GREEN = '#3fb950'
YELLOW = '#d29922'
RED = '#f85149'

fig, ax = plt.subplots(figsize=(14, 7))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 14)
ax.set_ylim(0, 7)
ax.axis('off')

# Title
ax.text(7, 6.5, 'MAAS Machine Provisioning Flow', color=TEXT, fontsize=16, fontweight='bold',
        ha='center', va='center')

steps = [
    ('CAPI\nMachine', 'Create\nMachine CR', 0.9, ACCENT),
    ('MaasMachine\nReconciler', 'Watch &\nReconcile', 2.5, '#6e40c9'),
    ('MAAS API\nAllocate', 'machines/\nallocate', 4.1, GREEN),
    ('MAAS API\nDeploy', 'machines/\ndeploy', 5.7, GREEN),
    ('Poll\nStatus', 'GET machine\nstatus', 7.3, YELLOW),
    ('DNS\nSetup', 'Set A/PTR\nrecords', 8.9, YELLOW),
    ('ProviderID\nSet', 'maas://\nMAAS_ID', 10.5, GREEN),
    ('Node\nReady', 'Machine\nProvisioned', 12.1, '#3fb950'),
]

box_w = 1.2
box_h = 1.4
y_center = 3.5

for i, (title, subtitle, x, color) in enumerate(steps):
    rect = FancyBboxPatch((x - box_w/2, y_center - box_h/2), box_w, box_h,
                          boxstyle="round,pad=0.05", linewidth=1.5,
                          edgecolor=color, facecolor=SURFACE2)
    ax.add_patch(rect)
    ax.text(x, y_center + 0.25, title, color=TEXT, fontsize=7.5, fontweight='bold',
            ha='center', va='center', linespacing=1.3)
    ax.text(x, y_center - 0.3, subtitle, color=MUTED, fontsize=6.5,
            ha='center', va='center', linespacing=1.3)

    if i < len(steps) - 1:
        next_x = steps[i+1][2]
        ax.annotate('', xy=(next_x - box_w/2 - 0.02, y_center),
                    xytext=(x + box_w/2 + 0.02, y_center),
                    arrowprops=dict(arrowstyle='->', color=ACCENT, lw=1.5))

# Step numbers
for i, (_, _, x, _) in enumerate(steps):
    ax.text(x, y_center - box_h/2 - 0.25, f'Step {i+1}', color=MUTED, fontsize=6,
            ha='center', va='center')

# Bottom note
ax.text(7, 0.4, 'CAPI Machine object triggers MaasMachine reconciliation → MAAS allocates & deploys physical machine → ProviderID links Kubernetes Node',
        color=MUTED, fontsize=7.5, ha='center', va='center',
        bbox=dict(boxstyle='round,pad=0.3', facecolor=SURFACE, edgecolor=BORDER))

plt.tight_layout()
plt.savefig('/Users/hwchiu/hwchiu/code/molearn/next-site/public/diagrams/maas/provisioning-flow.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved provisioning-flow.png")
