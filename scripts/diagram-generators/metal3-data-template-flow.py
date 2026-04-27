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

fig, ax = plt.subplots(figsize=(14, 7))
fig.patch.set_facecolor(BG_COLOR)
ax.set_facecolor(BG_COLOR)
ax.set_xlim(0, 14)
ax.set_ylim(0, 7)
ax.axis('off')

ax.text(7, 6.6, 'Metal3 DataTemplate Rendering Flow', color=TEXT, fontsize=16, fontweight='bold', ha='center')

def draw_box(ax, x, y, w, h, title, subtitle, color):
    rect = FancyBboxPatch((x - w/2, y - h/2), w, h,
                          boxstyle="round,pad=0.1", linewidth=1.5,
                          edgecolor=color, facecolor=SURFACE2, zorder=3)
    ax.add_patch(rect)
    ax.text(x, y + 0.18, title, color=TEXT, fontsize=8.5, ha='center', va='center',
            fontweight='bold', zorder=4)
    ax.text(x, y - 0.2, subtitle, color=MUTED, fontsize=7.5, ha='center', va='center', zorder=4)

steps = [
    (1.2, 3.5, 1.8, 1.2, 'Metal3\nDataClaim', 'Request\nfor data', ACCENT),
    (3.4, 3.5, 2.0, 1.2, 'DataTemplate\nReconciler', 'Watch claim\n& trigger', PURPLE),
    (5.8, 3.5, 2.2, 1.2, 'Read Metal3\nDataTemplate', 'Fetch template\nfrom K8s', YELLOW),
    (8.2, 3.5, 2.0, 1.2, 'Render\nJinja2 Tmpl', 'Fill IP/MAC/\nhostname', YELLOW),
    (10.5, 3.5, 2.0, 1.2, 'Write K8s\nSecrets', 'metaData +\nnetworkData', GREEN),
    (12.8, 3.5, 1.8, 1.2, 'Metal3Data\nReady', 'status.ready\n= true', GREEN),
]

for (x, y, w, h, title, subtitle, color) in steps:
    draw_box(ax, x, y, w, h, title, subtitle, color)

for i in range(len(steps)-1):
    x1 = steps[i][0] + steps[i][2]/2 + 0.05
    x2 = steps[i+1][0] - steps[i+1][2]/2 - 0.05
    y = steps[i][1]
    ax.annotate('', xy=(x2, y), xytext=(x1, y),
                arrowprops=dict(arrowstyle='->', color=ACCENT, lw=1.5))

# Output secrets detail
ax.text(10.5, 2.2, 'Secret: metaData', color=GREEN, fontsize=7.5, ha='center',
        bbox=dict(boxstyle='round,pad=0.2', facecolor=SURFACE, edgecolor=GREEN))
ax.text(10.5, 1.6, 'Secret: networkData', color=GREEN, fontsize=7.5, ha='center',
        bbox=dict(boxstyle='round,pad=0.2', facecolor=SURFACE, edgecolor=GREEN))
ax.annotate('', xy=(10.5, 2.5), xytext=(10.5, 2.9),
            arrowprops=dict(arrowstyle='->', color=GREEN, lw=1.2))

# Template inputs
ax.text(8.2, 2.0, 'Inputs: IP, MAC, hostname\nfrom Metal3DataTemplate spec',
        color=MUTED, fontsize=7.5, ha='center',
        bbox=dict(boxstyle='round,pad=0.2', facecolor=SURFACE, edgecolor=BORDER))
ax.annotate('', xy=(8.2, 2.9), xytext=(8.2, 2.5),
            arrowprops=dict(arrowstyle='->', color=YELLOW, lw=1.2))

plt.tight_layout()
plt.savefig('/Users/hwchiu/hwchiu/code/molearn/next-site/public/diagrams/metal3/data-template-flow.png',
            dpi=100, bbox_inches='tight', facecolor=BG_COLOR)
print("Saved data-template-flow.png")
