import argparse
import re
from pathlib import Path


RESULT_RE = re.compile(
    r"RESULT\s+test=(?P<test>[A-Za-z0-9_]+)\s+pass=(?P<pass>[01])\s+accel_cycles=(?P<cycles>\d+)"
)
SUMMARY_RE = re.compile(r"SUMMARY\s+pass=(?P<pass>\d+)\s+total=(?P<total>\d+)")


def parse_log(log_text: str):
    cases = []
    summary = None
    for line in log_text.splitlines():
        match = RESULT_RE.search(line)
        if match:
            cases.append(
                {
                    "test": match.group("test"),
                    "pass": int(match.group("pass")),
                    "accel_cycles": int(match.group("cycles")),
                }
            )
            continue

        match = SUMMARY_RE.search(line)
        if match:
            summary = {
                "pass": int(match.group("pass")),
                "total": int(match.group("total")),
            }
    return cases, summary


def scalar_sw_cycle_model(n: int) -> int:
    mac_cycles = 5
    overhead_cycles = 2
    return (n * n * n * mac_cycles) + (n * n * overhead_cycles)


def render_markdown(cases, summary):
    lines = []
    lines.append("# Midsem Simulation Results")
    lines.append("")
    lines.append("## Accelerator Verification")
    lines.append("")
    lines.append("| Test | Pass | Accelerator Cycles |")
    lines.append("|---|---:|---:|")
    for case in cases:
        lines.append(
            f"| `{case['test']}` | {case['pass']} | {case['accel_cycles']} |"
        )
    lines.append("")

    if summary is not None:
        lines.append(
            f"Overall pass rate: **{summary['pass']} / {summary['total']}**"
        )
        lines.append("")

    positive_cycles = [c["accel_cycles"] for c in cases if c["accel_cycles"] > 0]
    accel_cycles = min(positive_cycles, default=None)
    if accel_cycles is not None:
        n = 4
        sw_cycles = scalar_sw_cycle_model(n)
        end_to_end_cycles = accel_cycles + 8
        speedup_core = sw_cycles / accel_cycles
        speedup_end_to_end = sw_cycles / end_to_end_cycles

        lines.append("## Analytic Comparison (Cycle Model)")
        lines.append("")
        lines.append(
            "Assumptions: scalar software MM model uses 5 cycles/MAC plus loop overhead; "
            "accelerator setup overhead is modeled as 8 cycles."
        )
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|---|---:|")
        lines.append(f"| Matrix Size | {n}x{n} |")
        lines.append(f"| Software Cycle Model | {sw_cycles} |")
        lines.append(f"| Accelerator Compute Cycles (simulated) | {accel_cycles} |")
        lines.append(f"| Accelerator End-to-End Cycles (modeled) | {end_to_end_cycles} |")
        lines.append(f"| Speedup (compute-only) | {speedup_core:.2f}x |")
        lines.append(f"| Speedup (end-to-end) | {speedup_end_to_end:.2f}x |")
        lines.append("")
        lines.append(
            "These speedups are pre-silicon estimates for presentation, not final board measurements."
        )

    lines.append("")
    lines.append("## Next Step")
    lines.append("")
    lines.append(
        "Use this same test content after core integration, then replace analytic software cycles "
        "with measured `mcycle` or ARM `clock_gettime` data."
    )

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    raw = args.log.read_bytes()
    log_text = None
    for encoding in ("utf-8", "utf-16", "utf-16-le", "latin-1"):
        try:
            log_text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    if log_text is None:
        raise RuntimeError("Unable to decode simulation log.")
    cases, summary = parse_log(log_text)
    if not cases:
        raise RuntimeError("No RESULT lines found in simulation log.")

    markdown = render_markdown(cases, summary)
    args.out.write_text(markdown, encoding="utf-8")


if __name__ == "__main__":
    main()
