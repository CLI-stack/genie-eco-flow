#!/usr/bin/env python3
"""
eco_find_drvsub_target.py

Deterministically finds the correct driver_substitution target net for a
wire_swap ECO change. Walks the backward cone from a target register's DFF.D
pin and returns the first stage-stable net whose driver is a simple functional
gate (NOT a compound AOI/OAI consumer, NOT a MUX, NOT synthesis-internal).

This replaces the LLM's manual cone-tracing — which produced wrong targets in
every run — with a single reliable grep-and-walk algorithm.

Usage:
    python3 eco_find_drvsub_target.py \
        --ref-dir  <tile_ref_dir>          \
        --register <target_register_name>  \
        --jira     <jira_number>           \
        [--max-hops 30]                    \
        [--output   <result.json>]

Output JSON:
    {
      "driver_sub_target_net":       "ctmn_2084955",
      "driver_sub_target_cell_type": "XNR2D1BWP...",
      "driver_sub_target_instance":  "ctmi_...",
      "driver_sub_renamed_to":       "ECO_9899_net_orig",
      "stage_stable":                true,
      "stage_counts":                {"Synthesize": 4, "PrePlace": 3, "Route": 3},
      "cone_path":                   ["SEQMAP_NET_2948", "N2328807", ...],
      "module":                      "ddrss_umccmd_t_umccmdarb",
      "dff_d_net":                   "SEQMAP_NET_2948"
    }
"""

import argparse
import gzip
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Classification helpers
# ---------------------------------------------------------------------------

# Synthesis-internal net names — never valid driver_sub targets
_SYNTH_INTERNAL = re.compile(r'^(N\d{5,}|phfnn_\d+|rep_\d+|clock_gate_logic_\d+)$')

# Pivot nets (DFF.D chain) — never valid targets
_PIVOT_NET = re.compile(r'^SEQMAP_NET_')

# MUX gates — their outputs sit between pivot and the old-expression gate;
# not valid targets (renaming a MUX output breaks the MUX select logic)
_MUX_CELL = re.compile(r'^MUX', re.I)

# Compound consumer gates (AOI/OAI) — they aggregate multiple signals;
# the correct target is one of their INPUTS, not their output
_COMPOUND = re.compile(r'^(AOI|OAI|AO[0-9]|OA[0-9])', re.I)

# Output pin names recognised as the cell output.
# Order matters — check ZN/Z before Q/QN/CO/Y.
# Exclude 'S': it is the MUX select (input) and scan-enable input, NOT an output.
_OUTPUT_PINS = {'ZN', 'Z', 'Q', 'QN', 'CO', 'Y'}


def _is_synth_internal(net):
    return bool(_SYNTH_INTERNAL.match(net))

def _is_pivot(net):
    return bool(_PIVOT_NET.match(net))

def _is_mux(cell_type):
    return bool(_MUX_CELL.match(cell_type))

def _is_compound(cell_type):
    return bool(_COMPOUND.match(cell_type))

def _is_simple_driver(cell_type):
    """True for simple functional gates: XNR, XNOR, AND, OR, INV, NR, ND, INR, etc."""
    if _is_mux(cell_type) or _is_compound(cell_type):
        return False
    # Exclude flip-flops / latches
    ct = cell_type.upper()
    if ct.startswith(('SDF', 'DFF', 'LAT', 'SDFQ', 'SDFF')):
        return False
    return True


# ---------------------------------------------------------------------------
# Verilog netlist parser
# ---------------------------------------------------------------------------

def _extract_module_text(gz_path, dff_instance):
    """
    Read gz_path and return (module_text, module_name) for the module
    that contains dff_instance.  Returns (None, None) if not found.
    """
    print(f'[INFO] Reading {gz_path} ...', file=sys.stderr)
    with gzip.open(gz_path, 'rt', errors='replace') as fh:
        text = fh.read()

    # Split on module boundaries; keep separator by using lookahead
    blocks = re.split(r'(?=^module\s)', text, flags=re.MULTILINE)
    for block in blocks:
        if re.search(r'\b' + re.escape(dff_instance) + r'\b', block):
            m = re.match(r'module\s+(\w+)', block)
            module_name = m.group(1) if m else 'unknown'
            end = block.find('endmodule')
            return (block[:end + len('endmodule')] if end >= 0 else block), module_name

    return None, None


def _parse_instances(module_text):
    """
    Parse all cell instantiations from module_text.

    Verilog format (Synopsys DC style):
        CELL_TYPE INST_NAME ( .PORT1 ( NET1 ) , .PORT2 ( NET2 ) , ... ) ;

    Returns dict: output_net -> {cell_type, instance, inputs, output_pin}
    """
    # Strip comments
    text = re.sub(r'//[^\n]*', '', module_text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)

    net_to_driver = {}

    # Each instantiation ends with ') ;' or ');'
    # We split on the end-of-instance marker and parse each chunk
    # Pattern: UPPERCASE_CELL_WORD  instance_word  ( ... ) ;
    inst_re = re.compile(
        r'\b([A-Z]\w+)\s+(\w+)\s*\('   # CELL_TYPE  INSTANCE (
        r'(.*?)'                         # port connections (lazy, DOTALL)
        r'\)\s*;',                       # ) ;
        re.DOTALL
    )
    port_re = re.compile(r'\.\s*(\w+)\s*\(\s*([^)]+?)\s*\)')

    _KEYWORDS = {
        'module', 'endmodule', 'input', 'output', 'inout',
        'wire', 'reg', 'assign', 'always', 'begin', 'end',
        'if', 'else', 'case', 'casex', 'casez', 'for', 'while',
        'initial', 'task', 'function', 'parameter', 'localparam',
    }

    for m in inst_re.finditer(text):
        cell_type = m.group(1)
        instance  = m.group(2)
        ports_str = m.group(3)

        if cell_type.lower() in _KEYWORDS:
            continue

        ports = {
            pm.group(1): pm.group(2).strip()
            for pm in port_re.finditer(ports_str)
        }

        # Identify output pin — check in priority order so ZN/Z wins over Q/Y.
        # Iterate _OUTPUT_PINS in order rather than relying on dict iteration order.
        output_net = output_pin = None
        for preferred in ('ZN', 'Z', 'Q', 'QN', 'CO', 'Y'):
            if preferred in ports:
                output_net = ports[preferred].strip()
                output_pin = preferred
                break
        if output_net is None:
            # Fallback: any recognised output pin
            for pin, net in ports.items():
                if pin.upper() in _OUTPUT_PINS:
                    output_net = net.strip()
                    output_pin = pin
                    break

        if output_net:
            net_to_driver[output_net] = {
                'cell_type':  cell_type,
                'instance':   instance,
                'output_pin': output_pin,
                'inputs': {
                    p: n.strip()
                    for p, n in ports.items()
                    if p != output_pin
                },
            }

    return net_to_driver


def _get_dff_d_net(module_text, dff_instance):
    """Extract the .D pin net of a DFF instance from module_text."""
    pat = re.compile(
        re.escape(dff_instance) + r'\s*\((.*?)\)\s*;',
        re.DOTALL
    )
    m = pat.search(module_text)
    if not m:
        return None
    for pm in re.finditer(r'\.\s*(\w+)\s*\(\s*([^)]+?)\s*\)', m.group(1)):
        if pm.group(1).upper() == 'D':
            return pm.group(2).strip()
    return None


# ---------------------------------------------------------------------------
# Stage stability check
# ---------------------------------------------------------------------------

def _stage_counts(net, ref_dir):
    """Return {stage: occurrence_count} for all 3 PreEco stages."""
    result = {}
    for stage in ('Synthesize', 'PrePlace', 'Route'):
        path = os.path.join(ref_dir, 'data', 'PreEco', f'{stage}.v.gz')
        if not os.path.exists(path):
            result[stage] = -1
            continue
        try:
            r = subprocess.run(
                f'zgrep -c "{re.escape(net)}" {path}',
                shell=True, capture_output=True, text=True, timeout=30
            )
            result[stage] = int(r.stdout.strip()) if r.stdout.strip().isdigit() else 0
        except Exception:
            result[stage] = 0
    return result


# ---------------------------------------------------------------------------
# Main cone walker
# ---------------------------------------------------------------------------

def find_drvsub_target(ref_dir, target_register, jira, max_hops=30):
    """
    Walk backward from target_register_reg.D and return the correct
    driver_substitution target net.
    """
    dff_name  = f'{target_register}_reg'
    synth_gz  = os.path.join(ref_dir, 'data', 'PreEco', 'Synthesize.v.gz')

    # ---- Step 1: Extract module containing the DFF ----
    print(f'\n[1] Locating module for {dff_name}...', file=sys.stderr)
    module_text, module_name = _extract_module_text(synth_gz, dff_name)
    if module_text is None:
        return {'error': f'{dff_name} not found in Synthesize.v.gz'}
    print(f'    Module: {module_name}', file=sys.stderr)

    # ---- Step 2: Parse all instances in that module ----
    print(f'[2] Parsing instances...', file=sys.stderr)
    net_to_driver = _parse_instances(module_text)
    print(f'    {len(net_to_driver)} output nets mapped', file=sys.stderr)

    # ---- Step 3: Get DFF.D net ----
    dff_d_net = _get_dff_d_net(module_text, dff_name)
    if not dff_d_net:
        return {'error': f'.D pin of {dff_name} not found', 'module': module_name}
    print(f'[3] DFF.D = {dff_d_net}', file=sys.stderr)

    # ---- Step 4: BFS backward cone walk ----
    print(f'[4] Walking backward cone (max {max_hops} hops)...', file=sys.stderr)
    visited    = set()
    queue      = [(dff_d_net, 0, [dff_d_net])]
    candidates = []

    while queue:
        net, hop, path = queue.pop(0)

        if hop > max_hops or net in visited:
            continue
        visited.add(net)

        # Skip constants
        if re.match(r"^\d*'b", net) or net in ('1', '0'):
            continue

        drv = net_to_driver.get(net)
        if drv is None:
            continue   # primary input / port — no driver in this scope

        ct = drv['cell_type']

        # Classify and decide
        ct_upper = ct.upper()
        if _is_pivot(net):
            reason = 'pivot net'
        elif _is_synth_internal(net):
            reason = 'synth-internal'
        elif ct_upper.startswith(('SDF', 'DFF', 'LAT', 'SDFF', 'SDFQ', 'SAFF')):
            reason = f'flip-flop ({ct[:25]}) — state boundary, stop here'
        elif _is_mux(ct):
            reason = f'MUX driver ({ct[:25]})'
        elif _is_compound(ct):
            reason = f'compound consumer ({ct[:25]})'
        else:
            reason = None   # valid candidate

        if reason:
            print(
                f'  hop={hop:2d}  {net:35s}  [{ct[:30]}]  SKIP: {reason}',
                file=sys.stderr
            )
            # Flip-flops are state boundaries — do NOT walk their inputs
            if 'flip-flop' in reason:
                continue
        else:
            # Valid candidate — check stage stability
            print(
                f'  hop={hop:2d}  {net:35s}  [{ct[:30]}]  → CANDIDATE',
                file=sys.stderr
            )
            sc     = _stage_counts(net, ref_dir)
            stable = all(v > 0 for v in sc.values() if v >= 0)
            print(f'         stages={sc}  stable={stable}', file=sys.stderr)

            candidates.append({
                'net':       net,
                'cell_type': ct,
                'instance':  drv['instance'],
                'hop':       hop,
                'path':      path,
                'stage_counts': sc,
                'stable':    stable,
            })

            if stable:
                # First stage-stable candidate with a simple driver — this is the answer
                break

        # Enqueue inputs for further walking (skip flip-flop inputs — handled above via continue)
        inputs = list(drv['inputs'].values())
        for inp in reversed(inputs):
            inp = inp.strip()
            if inp and inp not in visited and not re.match(r"^\d*'b", inp):
                queue.insert(0, (inp, hop + 1, path + [inp]))

    # ---- Step 5: Pick best candidate ----
    if not candidates:
        return {
            'error':            'No valid driver_sub_target_net found in backward cone',
            'target_register':  target_register,
            'module':           module_name,
            'dff_d_net':        dff_d_net,
        }

    best = next((c for c in candidates if c['stable']), candidates[0])

    return {
        'target_register':          target_register,
        'module':                   module_name,
        'dff_d_net':                dff_d_net,
        'driver_sub_target_net':    best['net'],
        'driver_sub_target_cell_type': best['cell_type'],
        'driver_sub_target_instance':  best['instance'],
        'driver_sub_renamed_to':    f'ECO_{jira}_net_orig',
        'driver_sub_target_hop':    best['hop'],
        'cone_path':                best['path'],
        'stage_counts':             best['stage_counts'],
        'stage_stable':             best['stable'],
        'all_candidates':           candidates,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description='Deterministically find driver_substitution target net'
    )
    ap.add_argument('--ref-dir',  required=True, help='Tile ref_dir (contains data/PreEco/)')
    ap.add_argument('--register', required=True, help='RTL register name (e.g. ToggleChn)')
    ap.add_argument('--jira',     required=True, help='JIRA number (e.g. 9899)')
    ap.add_argument('--max-hops', type=int, default=30, help='Max backward cone hops (default 30)')
    ap.add_argument('--output',   help='Write result JSON to this path')
    args = ap.parse_args()

    result = find_drvsub_target(args.ref_dir, args.register, args.jira, args.max_hops)

    out_str = json.dumps(result, indent=2)

    if args.output:
        with open(args.output, 'w') as fh:
            fh.write(out_str)
        print(f'[INFO] Written to {args.output}', file=sys.stderr)

    print(out_str)

    if 'error' in result:
        sys.exit(1)

    print(f'\n[RESULT]', file=sys.stderr)
    print(f'  driver_sub_target_net  = {result["driver_sub_target_net"]}', file=sys.stderr)
    print(f'  driver_sub_renamed_to  = {result["driver_sub_renamed_to"]}', file=sys.stderr)
    print(f'  cell_type              = {result["driver_sub_target_cell_type"]}', file=sys.stderr)
    print(f'  stage_stable           = {result["stage_stable"]}', file=sys.stderr)
    print(f'  stages                 = {result["stage_counts"]}', file=sys.stderr)


if __name__ == '__main__':
    main()
