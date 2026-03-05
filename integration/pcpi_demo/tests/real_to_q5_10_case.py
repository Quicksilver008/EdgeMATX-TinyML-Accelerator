#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

Q5_10_SCALE = 1024
S16_MIN = -32768
S16_MAX = 32767
GENERATED_BY = "real_to_q5_10"
CUSTOM_PREFIX = "custom_"


def now_utc_stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")


def now_utc_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    # Accept Windows-authored UTF-8 files that include BOM.
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, data):
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def parse_number(value, field_name, idx):
    if isinstance(value, (int, float)):
        return float(value)
    raise ValueError(f"{field_name}[{idx}] must be numeric, got {type(value)!r}")


def flatten_4x4(values, field_name):
    if not isinstance(values, list) or len(values) != 4:
        raise ValueError(f"{field_name} must be a 4x4 matrix (4 rows).")
    flat = []
    for r, row in enumerate(values):
        if not isinstance(row, list) or len(row) != 4:
            raise ValueError(f"{field_name}[{r}] must contain exactly 4 values.")
        for c, elem in enumerate(row):
            flat.append(parse_number(elem, f"{field_name}[{r}]", c))
    return flat


def vector_16(values, field_name):
    if not isinstance(values, list) or len(values) != 16:
        raise ValueError(f"{field_name} must contain exactly 16 values.")
    return [parse_number(v, field_name, i) for i, v in enumerate(values)]


def get_real_matrix(data, flat_key, matrix_key):
    if flat_key in data:
        return vector_16(data[flat_key], flat_key)
    if matrix_key in data:
        return flatten_4x4(data[matrix_key], matrix_key)
    raise ValueError(f"Missing matrix input. Provide '{flat_key}' or '{matrix_key}'.")


def to_q5_10(values, matrix_name):
    out = []
    for i, real_val in enumerate(values):
        q = round(real_val * Q5_10_SCALE)
        if q < S16_MIN or q > S16_MAX:
            raise ValueError(
                f"{matrix_name}[{i}]={real_val} converts to {q}, outside signed16 range [{S16_MIN}, {S16_MAX}]."
            )
        out.append(int(q))
    return out


def row_chunks(values):
    return [values[i : i + 4] for i in range(0, 16, 4)]


def default_notes():
    return "Generated from real-valued matrix input using Q5.10 conversion."


def is_generated_case(case_obj):
    name = str(case_obj.get("name", ""))
    meta = case_obj.get("meta", {})
    generated_by = str(meta.get("generated_by", ""))
    return generated_by == GENERATED_BY or name.startswith(CUSTOM_PREFIX)


def load_cases_file(path):
    p = Path(path)
    if not p.exists():
        return {"cases": []}
    data = json.loads(p.read_text(encoding="utf-8"))
    if "cases" not in data or not isinstance(data["cases"], list):
        raise ValueError(f"Invalid schema in {path}: expected top-level 'cases' list.")
    return data


def build_case(case_name, notes, a_q5_10, b_q5_10, input_source):
    return {
        "name": case_name,
        "notes": notes,
        "a_q5_10": a_q5_10,
        "b_q5_10": b_q5_10,
        "meta": {
            "generated_by": GENERATED_BY,
            "created_at_utc": now_utc_iso(),
            "input_source": input_source,
        },
    }


def print_case_preview(case_entry, a_real, b_real):
    print("=== Real to Q5.10 conversion preview ===")
    print(f"Case name: {case_entry['name']}")
    print(f"Notes: {case_entry['notes']}")
    print("")
    print("A real (4x4):")
    for row in row_chunks(a_real):
        print("  " + ", ".join(f"{v:g}" for v in row))
    print("A q5_10 (4x4):")
    for row in row_chunks(case_entry["a_q5_10"]):
        print("  " + ", ".join(str(v) for v in row))
    print("")
    print("B real (4x4):")
    for row in row_chunks(b_real):
        print("  " + ", ".join(f"{v:g}" for v in row))
    print("B q5_10 (4x4):")
    for row in row_chunks(case_entry["b_q5_10"]):
        print("  " + ", ".join(str(v) for v in row))
    print("")
    print("JSON case object:")
    print(json.dumps(case_entry, indent=2))


def clear_generated_cases(custom_cases_path, dry_run):
    data = load_cases_file(custom_cases_path)
    original = data["cases"]
    kept = [c for c in original if not is_generated_case(c)]
    removed = [c for c in original if is_generated_case(c)]

    print(f"Custom cases file: {custom_cases_path}")
    print(f"Total cases: {len(original)}")
    print(f"Generated-tagged removable cases: {len(removed)}")
    if removed:
        print("Cases marked for removal:")
        for c in removed:
            print(f"  - {c.get('name', '<unnamed>')}")
    if dry_run:
        print("Dry-run mode enabled. No file changes written.")
        return

    data["cases"] = kept
    write_json(custom_cases_path, data)
    print(f"Removed {len(removed)} generated custom case(s).")


def main():
    parser = argparse.ArgumentParser(
        description="Convert real-valued 4x4 matrices to Q5.10 and optionally append to custom_cases.json."
    )
    parser.add_argument("--input-json", help="Input JSON containing a_real/b_real or a_real_4x4/b_real_4x4.")
    parser.add_argument("--print-only", action="store_true", help="Print conversion preview (default behavior).")
    parser.add_argument("--append-custom", action="store_true", help="Append generated case to custom cases file.")
    parser.add_argument(
        "--custom-cases",
        default=str(Path(__file__).resolve().parent / "custom_cases.json"),
        help="Path to custom cases JSON file.",
    )
    parser.add_argument("--name", help="Case name. Default: timestamped custom_<UTCSTAMP>.")
    parser.add_argument("--notes", help="Optional notes text for the generated case.")
    parser.add_argument("--clear-generated", action="store_true", help="Remove generated custom cases from custom file.")
    parser.add_argument(
        "--dry-run-clear", action="store_true", help="When used with --clear-generated, only print removals."
    )
    args = parser.parse_args()

    if args.clear_generated:
        clear_generated_cases(args.custom_cases, args.dry_run_clear)
        return

    if not args.input_json:
        raise ValueError("--input-json is required unless --clear-generated is used.")

    if args.dry_run_clear:
        raise ValueError("--dry-run-clear can only be used with --clear-generated.")

    input_data = load_json(args.input_json)
    a_real = get_real_matrix(input_data, "a_real", "a_real_4x4")
    b_real = get_real_matrix(input_data, "b_real", "b_real_4x4")
    a_q5_10 = to_q5_10(a_real, "A")
    b_q5_10 = to_q5_10(b_real, "B")

    case_name = args.name or f"{CUSTOM_PREFIX}{now_utc_stamp()}"
    notes = args.notes or input_data.get("notes") or default_notes()
    input_source = str(args.input_json)

    case_entry = build_case(case_name, notes, a_q5_10, b_q5_10, input_source)
    print_case_preview(case_entry, a_real, b_real)

    if args.append_custom:
        data = load_cases_file(args.custom_cases)
        existing_names = {str(c.get("name", "")) for c in data["cases"]}
        if case_name in existing_names:
            raise ValueError(f"Case name '{case_name}' already exists in {args.custom_cases}.")
        data["cases"].append(case_entry)
        write_json(args.custom_cases, data)
        print(f"Appended case '{case_name}' to {args.custom_cases}")
    else:
        print("Print-only mode: no changes written. Use --append-custom to persist.")


if __name__ == "__main__":
    main()
