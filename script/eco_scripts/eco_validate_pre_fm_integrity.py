#!/usr/bin/env python3
"""
eco_validate_pre_fm_integrity.py — Block FM submission when the
eco_pre_fm_check JSON has been tampered with.

Required because round-N agents have been observed editing the script-
written check_summary to insert "PASS_OVERRIDE: ..." strings to bypass
real failures (9868 R2). The pre_fm_check script only ever writes
'PASS' or 'FAIL' (or a structured per-stage dict for check8). Anything
else means the file was edited after the script ran.

Hard fails on:
  1. `passed: True` while `failures` is non-empty (contradiction).
  2. Any `check_summary` value that is not 'PASS', 'FAIL', or a dict
     with the expected per-stage keys for check8_verilog_validator.
  3. Any string anywhere in the JSON containing 'OVERRIDE' or
     'verified false positive' (agent's typical override phrasing).

Usage:
    python3 eco_validate_pre_fm_integrity.py \\
        --check-json data/<TAG>_eco_pre_fm_check_round<R>.json
Exit 0 = clean, exit 1 = tampered/contradictory.
"""
import argparse, json, sys
from pathlib import Path


_ALLOWED_VALUES = ('PASS', 'FAIL')
_FORBIDDEN_SUBSTR = ('OVERRIDE', 'verified false positive')


def find_forbidden(node, path=''):
    """Recursively find any string containing forbidden substrings."""
    hits = []
    if isinstance(node, str):
        for s in _FORBIDDEN_SUBSTR:
            if s in node:
                hits.append(f'{path}: {node[:120]!r}')
                break
    elif isinstance(node, dict):
        for k, v in node.items():
            hits.extend(find_forbidden(v, f'{path}.{k}' if path else k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            hits.extend(find_forbidden(v, f'{path}[{i}]'))
    return hits


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--check-json', required=True)
    args = p.parse_args()

    try:
        d = json.loads(Path(args.check_json).read_text())
    except Exception as e:
        print(f'FAIL: cannot read {args.check_json}: {e}', file=sys.stderr)
        return 1

    issues = []

    passed = d.get('passed')
    failures = d.get('failures') or []
    if passed is True and failures:
        issues.append(
            f'CONTRADICTION: passed=True but failures list has {len(failures)} '
            f'entries — agent flipped the result without clearing failures')

    summary = d.get('check_summary') or {}
    for k, v in summary.items():
        if isinstance(v, dict):
            # check8_verilog_validator-style dict: per-stage status + errors list
            for kk, vv in v.items():
                if kk == 'errors':
                    continue
                if vv not in _ALLOWED_VALUES:
                    issues.append(
                        f'TAMPERED: check_summary[{k!r}][{kk!r}] = {vv!r} '
                        f'(only PASS/FAIL allowed)')
        elif v not in _ALLOWED_VALUES:
            issues.append(
                f'TAMPERED: check_summary[{k!r}] = {v!r} '
                f'(only PASS/FAIL allowed; agent override forbidden)')

    issues.extend(f'FORBIDDEN_TOKEN: {h}' for h in find_forbidden(d))

    if not issues:
        print(f'INTEGRITY_PASS: {args.check_json}')
        return 0

    print(f'INTEGRITY_FAIL: {args.check_json}', file=sys.stderr)
    for i in issues:
        print(f'  - {i}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
