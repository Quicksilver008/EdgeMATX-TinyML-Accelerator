#!/usr/bin/env python3
"""Estimate cycle scaling for software vs 4x4 accelerator path.

Model anchors (from measured 4x4 run):
- software cycles at N=4: 26130
- accelerator cycles at N=4: 869

Two models are reported:
1) ideal: pure O(N^3) scaling from the 4x4 anchors
2) overhead-aware: adds non-ideal penalties that grow with tiling
   (launch overhead, partial-sum movement, contention, optional SW cache penalty)
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_sizes(text: str) -> list[int]:
    vals = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        vals.append(int(part))
    if not vals:
        raise ValueError("No sizes provided.")
    return vals


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sizes", default="4,8,16,32", help="Comma-separated N values.")
    parser.add_argument("--sw4", type=float, default=26130.0, help="Measured software cycles at N=4.")
    parser.add_argument("--acc4", type=float, default=869.0, help="Measured accelerator cycles at N=4.")
    parser.add_argument("--acc-launch-overhead", type=float, default=40.0, help="Extra cycles per tile call beyond N=4.")
    parser.add_argument(
        "--acc-partial-overhead",
        type=float,
        default=24.0,
        help="Extra cycles per output-tile accumulation step (k>0).",
    )
    parser.add_argument(
        "--acc-contention-overhead",
        type=float,
        default=120.0,
        help="Contention term coefficient scaled by ((N/4)^4 - 1).",
    )
    parser.add_argument(
        "--sw-cache-overhead",
        type=float,
        default=60.0,
        help="Software memory/cache penalty coefficient scaled by ((N/4)^4 - 1).",
    )
    parser.add_argument(
        "--out-json",
        default="integration/pcpi_demo/results/pcpi_cycle_scaling_estimate.json",
        help="Output JSON path.",
    )
    args = parser.parse_args()

    sizes = parse_sizes(args.sizes)
    sw_per_n3 = args.sw4 / (4.0 ** 3)
    rows = []

    for n in sizes:
        if n <= 0:
            raise ValueError(f"Invalid size N={n}.")
        t = n / 4.0
        sw_cycles_ideal = sw_per_n3 * (n ** 3)
        sw_cycles_over = sw_cycles_ideal + args.sw_cache_overhead * ((t ** 4) - 1.0)
        if n % 4 != 0:
            acc_cycles_ideal = None
            acc_cycles_over = None
            speedup_ideal = None
            speedup_over = None
            tile_calls = None
            partial_steps = None
        else:
            tile_calls = (n // 4) ** 3
            t_int = n // 4
            partial_steps = (t_int * t_int * (t_int - 1))
            acc_cycles_ideal = args.acc4 * tile_calls
            acc_cycles_over = (
                (args.acc4 * tile_calls)
                + (args.acc_launch_overhead * (tile_calls - 1))
                + (args.acc_partial_overhead * partial_steps)
                + (args.acc_contention_overhead * ((t_int ** 4) - 1))
            )
            speedup_ideal = sw_cycles_ideal / acc_cycles_ideal if acc_cycles_ideal > 0 else None
            speedup_over = sw_cycles_over / acc_cycles_over if acc_cycles_over > 0 else None
        rows.append(
            {
                "n": n,
                "software_cycles_ideal_est": round(sw_cycles_ideal, 3),
                "software_cycles_overhead_est": round(sw_cycles_over, 3),
                "accel_cycles_ideal_est": None if acc_cycles_ideal is None else round(acc_cycles_ideal, 3),
                "accel_cycles_overhead_est": None if acc_cycles_over is None else round(acc_cycles_over, 3),
                "tile_calls": tile_calls,
                "partial_steps": partial_steps,
                "speedup_ideal_sw_over_accel_est": None if speedup_ideal is None else round(speedup_ideal, 4),
                "speedup_overhead_sw_over_accel_est": None if speedup_over is None else round(speedup_over, 4),
            }
        )

    out = {
        "assumptions": {
            "software_scaling_ideal": "O(N^3), anchored at sw4",
            "accelerator_scaling_ideal": "4x4 tiling; calls=(N/4)^3; cost per call=acc4",
            "software_overhead_model": "ideal + sw_cache_overhead*((N/4)^4 - 1)",
            "accelerator_overhead_model": "ideal + launch*(calls-1) + partial*(t^2*(t-1)) + contention*((N/4)^4 - 1)",
            "sw4": args.sw4,
            "acc4": args.acc4,
            "acc_launch_overhead": args.acc_launch_overhead,
            "acc_partial_overhead": args.acc_partial_overhead,
            "acc_contention_overhead": args.acc_contention_overhead,
            "sw_cache_overhead": args.sw_cache_overhead,
        },
        "rows": rows,
    }

    out_path = Path(args.out_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2), encoding="utf-8")

    print("N  SW_ideal  SW_over  ACC_ideal  ACC_over  tile_calls  speedup_ideal  speedup_over")
    for row in rows:
        n = row["n"]
        sw_i = row["software_cycles_ideal_est"]
        sw_o = row["software_cycles_overhead_est"]
        acc_i = row["accel_cycles_ideal_est"]
        acc_o = row["accel_cycles_overhead_est"]
        calls = row["tile_calls"]
        spd_i = row["speedup_ideal_sw_over_accel_est"]
        spd_o = row["speedup_overhead_sw_over_accel_est"]
        print(
            f"{n:<2} {str(sw_i):>8} {str(sw_o):>8} {str(acc_i):>10} {str(acc_o):>9} {str(calls):>11} {str(spd_i):>14} {str(spd_o):>13}"
        )
    print(f"Wrote: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
