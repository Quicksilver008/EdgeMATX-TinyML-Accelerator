import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
import os

out_dir = os.path.dirname(os.path.abspath(__file__))

# ── Chart 1: Cycle Count Bar Chart (log scale) ──────────────────────────────
labels  = ['Hardware\nAccelerator\n(TACR)', 'Software\nBaseline\n(rv32im, MUL)', 'Software\nBaseline\n(rv32i, no MUL)']
cycles  = [673, 7975, 26130]
colors  = ['#2196F3', '#FF9800', '#F44336']
speedup = ['1×\n(baseline)', '11.85× slower', '38.83× slower']

fig, ax = plt.subplots(figsize=(8, 5))
bars = ax.bar(labels, cycles, color=colors, width=0.45, zorder=3)

ax.set_yscale('log')
ax.set_ylim(100, 100000)
ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f'{int(x):,}'))
ax.set_ylabel('Cycle Count (log scale)', fontsize=11)
ax.set_title('Simulation Cycle Counts — identity_x_sequence Benchmark', fontsize=12, fontweight='bold')
ax.grid(axis='y', which='both', linestyle='--', linewidth=0.5, alpha=0.7, zorder=0)
ax.set_axisbelow(True)

for bar, cyc, sp in zip(bars, cycles, speedup):
    ax.text(bar.get_x() + bar.get_width() / 2,
            bar.get_height() * 1.35,
            f'{cyc:,} cycles\n{sp}',
            ha='center', va='bottom', fontsize=9, fontweight='bold')

plt.tight_layout()
out1 = os.path.join(out_dir, 'cycle_count_bar.png')
plt.savefig(out1, dpi=150, bbox_inches='tight')
plt.close()
print(f'Saved: {out1}')

# ── Chart 2: Speedup Grouped Bar Chart ───────────────────────────────────────
cases      = ['identity_x_sequence', 'live_real_input\n(dense)']
speedup_nomul = [38.83, 53.86]
speedup_mul   = [11.85, 11.85]

x     = np.arange(len(cases))
width = 0.30

fig, ax = plt.subplots(figsize=(8, 5))
b1 = ax.bar(x - width / 2, speedup_nomul, width, label='vs. rv32i no-MUL', color='#F44336', zorder=3)
b2 = ax.bar(x + width / 2, speedup_mul,   width, label='vs. rv32im MUL',   color='#FF9800', zorder=3)

ax.set_ylabel('Speedup (×)', fontsize=11)
ax.set_title('TACR Speedup over Software Baselines', fontsize=12, fontweight='bold')
ax.set_xticks(x)
ax.set_xticklabels(cases, fontsize=10)
ax.set_ylim(0, 65)
ax.legend(fontsize=10)
ax.grid(axis='y', linestyle='--', linewidth=0.5, alpha=0.7, zorder=0)
ax.set_axisbelow(True)

for bar in b1:
    ax.text(bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.8,
            f'{bar.get_height():.2f}×',
            ha='center', va='bottom', fontsize=9, fontweight='bold')
for bar in b2:
    ax.text(bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.8,
            f'{bar.get_height():.2f}×',
            ha='center', va='bottom', fontsize=9, fontweight='bold')

plt.tight_layout()
out2 = os.path.join(out_dir, 'speedup_comparison.png')
plt.savefig(out2, dpi=150, bbox_inches='tight')
plt.close()
print(f'Saved: {out2}')
