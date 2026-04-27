import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
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

fig, ax = plt.subplots(figsize=(10, 12))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 10)
ax.set_ylim(0, 12)
ax.axis('off')

ax.text(5, 11.6, 'Metal3 chooseHost Decision Flow', color=TEXT, fontsize=15, fontweight='bold', ha='center')

def draw_diamond(ax, x, y, w, h, label, color=YELLOW):
    dx, dy = w/2, h/2
    xs = [x, x+dx, x, x-dx, x]
    ys = [y+dy, y, y-dy, y, y+dy]
    ax.fill(xs, ys, facecolor=SURFACE2, edgecolor=color, linewidth=2, zorder=3)
    ax.text(x, y, label, color=TEXT, fontsize=8, ha='center', va='center',
            fontweight='bold', zorder=4, multialignment='center')

def draw_box(ax, x, y, w, h, label, color=ACCENT):
    rect = FancyBboxPatch((x - w/2, y - h/2), w, h,
                          boxstyle="round,pad=0.08", linewidth=1.5,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y, label, color=TEXT, fontsize=8.5, ha='center', va='center',
            fontweight='bold', zorder=4, multialignment='center')

def arrow(ax, x1, y1, x2, y2, label='', color=MUTED):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle='->', color=color, lw=1.5))
    if label:
        mx, my = (x1+x2)/2, (y1+y2)/2
        ax.text(mx + 0.12, my, label, color=GREEN, fontsize=7.5, ha='left', va='center')

# Start
draw_box(ax, 5, 11.0, 2.8, 0.5, 'chooseHost( host list )', ACCENT)
arrow(ax, 5, 10.75, 5, 10.35)

# Step 1: node-reuse label?
draw_diamond(ax, 5, 9.9, 3.4, 0.8, 'Has node-reuse\nlabel match?')
arrow(ax, 5, 9.5, 5, 9.1)

# Yes -> select that host
ax.annotate('', xy=(8.2, 9.9), xytext=(6.7, 9.9),
            arrowprops=dict(arrowstyle='->', color=GREEN, lw=1.5))
ax.text(7.45, 10.0, 'Yes', color=GREEN, fontsize=7.5, ha='center')
draw_box(ax, 8.8, 9.9, 1.6, 0.5, 'Select\nthat host', GREEN)

# No -> step 2
ax.text(4.5, 9.3, 'No', color=RED, fontsize=7.5, ha='center')
draw_diamond(ax, 5, 8.65, 3.4, 0.8, 'Name-based\npreallocation?')
arrow(ax, 5, 8.25, 5, 7.85)

# Yes -> select
ax.annotate('', xy=(8.2, 8.65), xytext=(6.7, 8.65),
            arrowprops=dict(arrowstyle='->', color=GREEN, lw=1.5))
ax.text(7.45, 8.75, 'Yes', color=GREEN, fontsize=7.5, ha='center')
draw_box(ax, 8.8, 8.65, 1.6, 0.5, 'Select\nthat host', GREEN)

# No -> step 3
ax.text(4.5, 8.05, 'No', color=RED, fontsize=7.5, ha='center')
draw_diamond(ax, 5, 7.45, 3.4, 0.8, 'Any BMH in\nReady state?')
arrow(ax, 5, 7.05, 5, 6.65)

# Yes -> select
ax.annotate('', xy=(8.2, 7.45), xytext=(6.7, 7.45),
            arrowprops=dict(arrowstyle='->', color=GREEN, lw=1.5))
ax.text(7.45, 7.55, 'Yes', color=GREEN, fontsize=7.5, ha='center')
draw_box(ax, 8.8, 7.45, 1.6, 0.5, 'Select ready\nBMH', GREEN)

# No -> step 4
ax.text(4.5, 6.85, 'No', color=RED, fontsize=7.5, ha='center')
draw_diamond(ax, 5, 6.25, 3.4, 0.8, 'Any BMH in\nAvailable state?')
arrow(ax, 5, 5.85, 5, 5.45)

# Yes -> select
ax.annotate('', xy=(8.2, 6.25), xytext=(6.7, 6.25),
            arrowprops=dict(arrowstyle='->', color=GREEN, lw=1.5))
ax.text(7.45, 6.35, 'Yes', color=GREEN, fontsize=7.5, ha='center')
draw_box(ax, 8.8, 6.25, 1.6, 0.5, 'Select available\nBMH', GREEN)

# No -> wait
ax.text(4.5, 5.65, 'No', color=RED, fontsize=7.5, ha='center')
draw_box(ax, 5, 5.15, 2.8, 0.5, 'Return nil\n(wait & retry)', RED)

# Legend
ax.text(0.5, 1.8, 'Legend:', color=MUTED, fontsize=8, fontweight='bold')
draw_diamond(ax, 1.3, 1.2, 1.2, 0.5, 'Decision', YELLOW)
rect = FancyBboxPatch((2.5, 0.95), 1.2, 0.5,
                      boxstyle="round,pad=0.08", linewidth=1.5,
                      edgecolor=ACCENT, facecolor=SURFACE2, zorder=3)
ax.add_patch(rect)
ax.text(3.1, 1.2, 'Action', color=TEXT, fontsize=8, ha='center', va='center', zorder=4)

plt.tight_layout()
plt.savefig('/Users/hwchiu/hwchiu/code/molearn/next-site/public/diagrams/metal3/choosehost-flow.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved choosehost-flow.png")
