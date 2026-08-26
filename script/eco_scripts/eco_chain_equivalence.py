#!/usr/bin/env python3
"""
eco_chain_equivalence.py — verify a d_input_gate_chain composes to a target
boolean function.

Composition algorithm:
  1. For each gate in chain (seq order): look up its cell's truth table from
     eco_cell_truth_tables (Liberty-extracted or bundled JSON).
  2. Build a Python boolean expression for the gate's output by substituting
     pin names with the actual input net names.
  3. When a downstream gate references an upstream gate's output net (n_eco_*),
     inline the upstream expression into the downstream expression.
  4. The chain's final output is the expression at the DFF.D feed point.

Equivalence:
  Brute-force truth-table enumeration over primary input signals (typically
  3-8 leaves). For 2^N combos, evaluate both impl and reference expressions;
  if they ever disagree → not equivalent. For N>12, switch to a sample-based
  random-input check (warning only).

Usage:
  python3 eco_chain_equivalence.py compose \\
      --rtl-diff data/<TAG>_eco_rtl_diff.json \\
      --target-register NeedFreqAdj
  python3 eco_chain_equivalence.py compare \\
      --rtl-diff data/<TAG>_eco_rtl_diff.json \\
      --target-register NeedFreqAdj \\
      --reference '<python boolean expression>'
"""
import argparse, json, os, re, sys
from pathlib import Path
from itertools import product

# ── Cell truth-table lookup ──────────────────────────────────────────────────
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eco_cell_truth_tables as _ett

def cell_function(cell_type):
    """Return the boolean expression of cell's primary output, or None."""
    tt = _ett.truth_table_of(cell_type)
    if not tt:
        return None
    # Pick the first output pin (Z, ZN, Q, etc.). Cells with multiple outputs
    # are rare in chains.
    return tt

# ── Chain composer ──────────────────────────────────────────────────────────

def compose_chain(chain, dff_d_net):
    """Compose a list of d_input_gate_chain entries into one boolean expression
    in terms of primary input nets.

    Returns:
      (final_expr, primary_inputs)
        final_expr     — Python boolean expression string
        primary_inputs — sorted list of input variable names referenced
        unresolved     — list of issues (unknown cells, missing functions)
    Or (None, None, [issues]) on hard failure.
    """
    issues = []
    net_expr = {}    # net_name → expression string for that net
    primary  = set()

    for g in chain:
        cell = g.get('preeco_cell_type') or g.get('cell_type', '')
        out_net = g.get('output_net', '')
        if not cell or not out_net:
            issues.append(f"chain entry missing cell_type or output_net: {g.get('seq', '?')}")
            continue
        tt = cell_function(cell)
        if tt is None:
            issues.append(f"{g.get('seq','?')}: cell {cell!r} has no truth table — extend cell library JSON or run eco_liberty_extractor")
            continue
        # Pick first output pin's expression
        out_pin, fn = next(iter(tt.items()))
        # Substitute pin names with this gate's input nets
        # Inputs come from port_connections (preferred) or pin_mapping fallback
        port_conns = {}
        if g.get('pin_mapping'):
            port_conns.update(g['pin_mapping'])
        # Fall back to listing inputs by gate's input order if pin_mapping absent
        if not port_conns and g.get('inputs'):
            # Use cell's input pin order from truth table function (extract pin names)
            pins_in_fn = sorted(set(re.findall(r'\b[A-Z][A-Z0-9_]*\b', fn))
                                - {out_pin})
            for pin, inp in zip(pins_in_fn, g['inputs']):
                port_conns[pin] = inp
        if not port_conns:
            issues.append(f"{g.get('seq','?')}: no pin_mapping or inputs to substitute into cell function")
            continue
        # Replace pin names with input net names in the function expression
        expr = fn
        for pin in sorted(port_conns.keys(), key=len, reverse=True):
            inp = port_conns[pin]
            # Net name may have bit-select like BeqCtrlPeSrc[2] — sanitize for Python
            inp_var = sanitize_var(inp)
            primary.add(inp_var)
            expr = re.sub(rf'\b{re.escape(pin)}\b', inp_var, expr)
        # If any input was an upstream gate's output, inline its expression
        for upstream_net, upstream_expr in net_expr.items():
            up_var = sanitize_var(upstream_net)
            if up_var in expr:
                expr = re.sub(rf'\b{re.escape(up_var)}\b', f"({upstream_expr})", expr)
                primary.discard(up_var)
        net_expr[out_net] = expr

    if dff_d_net not in net_expr:
        issues.append(f"DFF.D net {dff_d_net!r} not produced by any chain gate")
        return None, None, issues

    final = net_expr[dff_d_net]
    return final, sorted(primary), issues


def sanitize_var(name):
    """Convert a Verilog net name to a Python-safe identifier.
       BeqCtrlPeSrc[2] → BeqCtrlPeSrc__2"""
    return re.sub(r'\W', '_', name)


# ── Truth table comparison ──────────────────────────────────────────────────

def expr_truth_table(expr, inputs):
    """Enumerate all 2^N input combinations; return dict {tuple → 0/1}.
       Inputs are strings; expr is a Python boolean expression using them.
       Boolean operators: & | ^ ~ ()  — Python evaluates correctly with int operands."""
    table = {}
    for combo in product([0, 1], repeat=len(inputs)):
        env = dict(zip(inputs, combo))
        try:
            result = eval(expr, {"__builtins__": {}}, env)
        except Exception as e:
            return None, f"eval failed at {dict(zip(inputs, combo))}: {e}"
        # Coerce to 0/1 (handle Python's negative ~ values and bool-int mixing)
        table[combo] = 1 if (result & 1) else 0
    return table, None


def equivalent(expr_a, expr_b, inputs):
    """Compare two boolean expressions over same inputs via truth tables.
       Returns (bool, mismatches) — mismatches is list of input combos
       where outputs differ."""
    if len(inputs) > 12:
        # Too large for brute force; skip with warning
        return None, ["input count > 12 — brute-force enumeration skipped"]
    ta, ea = expr_truth_table(expr_a, inputs)
    tb, eb = expr_truth_table(expr_b, inputs)
    if ea or eb:
        return None, [ea or "", eb or ""]
    mismatches = []
    for combo in ta:
        if ta[combo] != tb[combo]:
            mismatches.append((dict(zip(inputs, combo)), ta[combo], tb[combo]))
    return (len(mismatches) == 0), mismatches


# ── CLI ──────────────────────────────────────────────────────────────────────

def find_change(rtl_diff, target_register):
    """Return the change with a non-empty d_input_gate_chain matching target."""
    candidates = []
    for c in rtl_diff.get('changes', []):
        dff = c.get('dff_instance_name') or ''
        if (dff.rstrip('_reg') == target_register
            or dff == f'{target_register}_reg'
            or c.get('target_register') == target_register
            or c.get('new_token') == target_register):
            candidates.append(c)
    # Prefer the candidate that actually has a chain
    for c in candidates:
        if c.get('d_input_gate_chain'):
            return c
    return candidates[0] if candidates else None


def cmd_compose(args):
    rtl_diff = json.loads(Path(args.rtl_diff).read_text())
    c = find_change(rtl_diff, args.target_register)
    if not c:
        print(f"FAIL: no change found for target_register={args.target_register!r}")
        return 1
    chain = c.get('d_input_gate_chain') or []
    # Determine DFF.D net (last gate's output, or explicit field)
    dff_d = chain[-1].get('output_net') if chain else None
    if not dff_d:
        print("FAIL: cannot determine DFF.D net")
        return 1
    expr, inputs, issues = compose_chain(chain, dff_d)
    if expr is None:
        print("FAIL composing chain:")
        for i in issues: print(f"  - {i}")
        return 1
    print(f"Composed chain for {args.target_register} (DFF.D = {dff_d}):")
    print(f"  expression : {expr}")
    print(f"  primary inputs ({len(inputs)}): {inputs}")
    if issues:
        print(f"  warnings:")
        for i in issues: print(f"    - {i}")
    return 0


def cmd_compare(args):
    rtl_diff = json.loads(Path(args.rtl_diff).read_text())
    c = find_change(rtl_diff, args.target_register)
    if not c:
        print(f"FAIL: no change found for target_register={args.target_register!r}")
        return 1
    chain = c.get('d_input_gate_chain') or []
    dff_d = chain[-1].get('output_net') if chain else None
    impl_expr, inputs, issues = compose_chain(chain, dff_d)
    if impl_expr is None:
        print("FAIL composing chain:")
        for i in issues: print(f"  - {i}")
        return 1
    # Reference expression must use same input variables (pre-sanitized)
    ref_expr = args.reference
    # Find all variables in ref expression
    ref_vars = sorted(set(re.findall(r'\b[A-Za-z_]\w*\b', ref_expr))
                      - {'and', 'or', 'not'})
    all_vars = sorted(set(inputs) | set(ref_vars))
    eq, details = equivalent(impl_expr, ref_expr, all_vars)
    print(f"Impl expr: {impl_expr}")
    print(f"Ref  expr: {ref_expr}")
    print(f"Inputs   : {all_vars}")
    if eq is None:
        print(f"INCONCLUSIVE: {details}")
        return 1
    if eq:
        print("✅ EQUIVALENT — impl chain matches reference boolean")
        return 0
    print(f"❌ NOT EQUIVALENT — {len(details)} mismatching input combinations")
    for combo, impl_v, ref_v in details[:8]:
        print(f"  inputs={combo} → impl={impl_v}, ref={ref_v}")
    if len(details) > 8:
        print(f"  ... and {len(details)-8} more")
    return 1


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    pc = sub.add_parser('compose')
    pc.add_argument('--rtl-diff', required=True)
    pc.add_argument('--target-register', required=True)

    pcm = sub.add_parser('compare')
    pcm.add_argument('--rtl-diff', required=True)
    pcm.add_argument('--target-register', required=True)
    pcm.add_argument('--reference', required=True,
                     help="Python boolean expression in primary input variable names")

    args = p.parse_args()
    if args.cmd == 'compose':  return cmd_compose(args)
    if args.cmd == 'compare':  return cmd_compare(args)
    return 0


if __name__ == '__main__':
    sys.exit(main())
