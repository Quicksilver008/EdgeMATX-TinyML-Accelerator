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


def render_markdown(cases, summary):
    lines = []
    lines.append("# RISC-V Custom-Instruction Integration Results")
    lines.append("")
    lines.append("## Verification Summary")
    lines.append("")
    lines.append("| Test | Pass | Accelerator Cycles |")
    lines.append("|---|---:|---:|")
    for case in cases:
        lines.append(
            f"| `{case['test']}` | {case['pass']} | {case['accel_cycles']} |"
        )
    lines.append("")
    if summary is not None:
        lines.append(f"Overall pass rate: **{summary['pass']} / {summary['total']}**")
        lines.append("")

    lines.append("## Covered Behaviors")
    lines.append("")
    lines.append("- Custom instruction decode match and accept pulse generation.")
    lines.append("- CPU stall assertion while accelerator operation is in flight.")
    lines.append("- Busy-window protection (instruction re-issue while busy is ignored).")
    lines.append("- Correct matrix output compared against a golden model.")
    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append(
        "- This is an integration stub simulation, not full pipeline CPU execution."
    )
    lines.append(
        "- Next milestone is replacing the instruction stub source with an actual CPU fetch/decode stream."
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
        raise RuntimeError("No RESULT lines found in integration simulation log.")

    markdown = render_markdown(cases, summary)
    args.out.write_text(markdown, encoding="utf-8")


if __name__ == "__main__":
    main()
