import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import numpy as np

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
PURPLE = '#6e40c9'

fig, ax = plt.subplots(figsize=(13, 7.5))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 13)
ax.set_ylim(0, 7.5)
ax.axis('off')

ax.text(6.5, 7.1, 'CAPI Reconcile Loop Concept', color=TEXT, fontsize=16, fontweight='bold', ha='center')

def draw_box(ax, x, y, w, h, title, subtitle, color, fc=SURFACE2):
    rect = FancyBboxPatch((x - w/2, y - h/2), w, h,
                          boxstyle="round,pad=0.12", linewidth=2,
                          edgecolor=color, facecolor=fc, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y + 0.2, title, color=color, fontsize=10, ha='center', va='center',
            fontweight='bold', zorder=4)
    ax.text(x, y - 0.2, subtitle, color=MUTED, fontsize=8.5, ha='center', va='center', zorder=4)

# Desired state (left)
draw_box(ax, 2.3, 5.0, 3.8, 1.8, 'Desired State', 'YAML / kubectl / API', ACCENT)
ax.text(2.3, 4.4, 'Cluster: nginx-cluster\nreplicas: 3', color=MUTED, fontsize=8,
        ha='center', va='top', family='monospace')

# Actual state (right)
draw_box(ax, 10.7, 5.0, 3.8, 1.8, 'Actual State', 'Real Infrastructure', GREEN)
ax.text(10.7, 4.4, 'Running nodes: 2\nNode3: not found', color=MUTED, fontsize=8,
        ha='center', va='top', family='monospace')

# Controller box (center)
ctrl_rect = FancyBboxPatch((4.8, 4.2), 3.4, 1.6,
                           boxstyle="round,pad=0.12", linewidth=2.5,
                           edgecolor=YELLOW, facecolor=SURFACE, zorder=3)
ax.add_patch(ctrl_rect)
ax.text(6.5, 5.2, 'Controller / Reconciler', color=YELLOW, fontsize=10, fontweight='bold',
        ha='center', va='center', zorder=4)
ax.text(6.5, 4.75, 'Observe  →  Compare  →  Act', color=TEXT, fontsize=8.5,
        ha='center', va='center', zorder=4)

# Arrows desired -> controller
ax.annotate('', xy=(4.8, 5.0), xytext=(4.2, 5.0),
            arrowprops=dict(arrowstyle='->', color=ACCENT, lw=2))
# controller -> actual
ax.annotate('', xy=(10.0, 5.0), xytext=(8.2, 5.0),
            arrowprops=dict(arrowstyle='->', color=GREEN, lw=2))

# Gap / diff annotation
ax.annotate('', xy=(10.0, 3.3), xytext=(4.2, 3.3),
            arrowprops=dict(arrowstyle='<->', color=RED, lw=2))
ax.text(6.5, 3.0, 'Gap Detected: need 1 more node', color=RED, fontsize=9,
        ha='center', va='center', fontweight='bold')

# Action box
draw_box(ax, 6.5, 2.0, 4.0, 0.9, 'Action: Create Node 3', 'kubectl apply / cloud API call', GREEN)

# Arrow controller -> action
ax.annotate('', xy=(6.5, 2.45), xytext=(6.5, 4.2),
            arrowprops=dict(arrowstyle='->', color=YELLOW, lw=2))

# Continuous loop arrow (curved)
theta = np.linspace(np.pi*1.1, np.pi*1.9, 50)
cx, cy, r = 6.5, 1.0, 2.2
loop_x = cx + r * np.cos(theta)
loop_y = cy + r * np.sin(theta)
ax.plot(loop_x, loop_y, color=MUTED, lw=2, linestyle='--', zorder=2)
ax.annotate('', xy=(loop_x[-1], loop_y[-1]), xytext=(loop_x[-2], loop_y[-2]),
            arrowprops=dict(arrowstyle='->', color=MUTED, lw=2))
ax.text(6.5, 0.3, 'Continuous Reconcile Loop', color=MUTED, fontsize=8.5, ha='center', style='italic')

plt.tight_layout()
plt.savefig('/Users/hwchiu/hwchiu/code/molearn/next-site/public/diagrams/capi/reconcile-loop.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved reconcile-loop.png")
