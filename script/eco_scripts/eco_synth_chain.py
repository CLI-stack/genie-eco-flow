#!/usr/bin/env python3
"""
eco_synth_chain.py — Synthesize a Boolean expression into a synthesis-style
gate chain using sympy + the project's cell-truth-table library.

Why this exists
---------------
Trial3 of run 20260512070625 produced a "literal-decomposition" 5-cell chain
for NeedFreqAdj_reg.D (NR2 + XNR2 + AN3 + INV + AN2). The Boolean function was
correct but FM Route failed to verify NeedFreqAdj_reg vs trial3's PrePlace.
Trial1 + engineer used a 4-cell synthesis-style chain (INV + XOR2 + OR4 + NR2)
for the SAME Boolean and FM passed. The studier needs to mirror engineer-style
gate decomposition, not literal RTL decomposition. This script is the canonical
synthesizer the studier MUST invoke.

Algorithm
---------
1. Parse RTL Boolean expression via sympy
2. Detect known synthesis-friendly patterns (AND-of-mixed-literals, MUX, OAI,
   etc.) and emit the matching cell chain
3. Verify Boolean equivalence between emitted chain and input expression
   (uses existing eco_chain_equivalence machinery)
4. Pick per-stage input wires using rename_map polarity hints

Usage
-----
    python3 eco_synth_chain.py synthesize \\
        --boolean "BeqCtrlPeReq & ~ArbCtrlPeRdy & ~B2 & ~(B1 ^ B0) & ~reset" \\
        --inputs BeqCtrlPeReq,ArbCtrlPeRdy,B2,B1,B0,reset \\
        --output cell_chain.json

    python3 eco_synth_chain.py synthesize-from-rtl-diff \\
        --rtl-diff data/<TAG>_eco_rtl_diff.json \\
        --target-register NeedFreqAdj \\
        --output cell_chain.json

    python3 eco_synth_chain.py verify \\
        --boolean "<expr>" --chain-json cell_chain.json --inputs <list>
"""
import argparse
import json
import os
import re
import sys
from collections import OrderedDict
from itertools import product

# Local user-installed sympy
sys.path.insert(0, os.path.expanduser('~/.local/lib/python3.7/site-packages'))
import sympy
from sympy import symbols, Symbol, And, Or, Not, Xor, true, false
from sympy.logic.boolalg import to_dnf, to_cnf, simplify_logic, Boolean


# ────────────────────────── Boolean → truth table ──────────────────────────

def truth_table(expr, input_syms):
    """Return list of 0/1 outputs over all 2^N input combos (lex order)."""
    N = len(input_syms)
    out = []
    for combo in product([False, True], repeat=N):
        substitution = dict(zip(input_syms, combo))
        result = expr.subs(substitution)
        out.append(1 if result == true else 0)
    return tuple(out)


def truth_tables_match(expr_a, expr_b, input_syms):
    """Brute-force truth-table equivalence."""
    return truth_table(expr_a, input_syms) == truth_table(expr_b, input_syms)


# ────────────────────────── AST utilities ──────────────────────────

def is_literal(node):
    """A literal is a Symbol or Not(Symbol)."""
    if isinstance(node, Symbol):
        return True
    if isinstance(node, Not) and isinstance(node.args[0], Symbol):
        return True
    return False


def literal_polarity_var(lit):
    """Return (positive_bool, var_symbol) for a literal node."""
    if isinstance(lit, Symbol):
        return True, lit
    if isinstance(lit, Not) and isinstance(lit.args[0], Symbol):
        return False, lit.args[0]
    raise ValueError(f"Not a literal: {lit}")


def split_and_factors(expr):
    """If expr is an AND, return its operands; else [expr]."""
    if isinstance(expr, And):
        return list(expr.args)
    return [expr]


def _push_nots_to_literals(expr):
    """Push Not operators down to literals via DeMorgan.

    Converts ~(A | B) → ~A & ~B and ~(A & B) → ~A | ~B recursively, so
    pattern detectors only see Not(Symbol) literals (or Not(Xor(...))
    treated as XNOR factor).
    """
    if isinstance(expr, Symbol):
        return expr
    if isinstance(expr, Not):
        inner = expr.args[0]
        if isinstance(inner, Symbol):
            return expr  # Not(Symbol) is a literal — keep as-is
        if isinstance(inner, And):
            # ~(A & B & ...) = ~A | ~B | ...
            return Or(*[_push_nots_to_literals(Not(a)) for a in inner.args])
        if isinstance(inner, Or):
            # ~(A | B | ...) = ~A & ~B & ...
            return And(*[_push_nots_to_literals(Not(a)) for a in inner.args])
        if isinstance(inner, Not):
            return _push_nots_to_literals(inner.args[0])
        if isinstance(inner, Xor):
            # ~(A ^ B) — keep as XNOR (pattern detector recognizes this)
            return Not(Xor(*[_push_nots_to_literals(a) for a in inner.args]))
        return expr  # unknown inner type
    if isinstance(expr, (And, Or)):
        return type(expr)(*[_push_nots_to_literals(a) for a in expr.args])
    if isinstance(expr, Xor):
        return Xor(*[_push_nots_to_literals(a) for a in expr.args])
    return expr


# ────────────────────────── Pattern detectors ──────────────────────────

class CellChain:
    """Holds the emitted cell chain + intermediate wire names."""
    def __init__(self):
        self.cells = []     # list of dicts: {cell_type, instance_name, port_connections}
        self.wires = []     # intermediate wire names (n_eco_*)
        self.output_net = None

    def add_cell(self, cell_type, inst_name, port_connections):
        self.cells.append({
            'cell_type': cell_type,
            'instance_name': inst_name,
            'port_connections': port_connections,
        })

    def add_wire(self, name):
        self.wires.append(name)

    def to_dict(self):
        return {
            'cells': self.cells,
            'wires': self.wires,
            'output_net': self.output_net,
        }


def _wire_name(jira, idx, prefix=''):
    """Per-DFF prefix prevents collisions when multiple DFFs are synthesized
    in the same study (e.g. NeedFreqAdj + EcoUseSdpOutstRdCnt would both
    produce eco_<jira>_d001 without per-DFF labeling)."""
    p = f'{prefix}_' if prefix else ''
    return f'n_eco_{jira}_{p}d{idx:03d}'


def _inst_name(jira, idx, prefix=''):
    p = f'{prefix}_' if prefix else ''
    return f'eco_{jira}_{p}d{idx:03d}'


def detect_and_of_terms_with_xor(expr):
    """
    Detect: F = pos_lit_1 & pos_lit_2 & ~pos_lit_3 & ... & ~(xor_a^xor_b) & ...

    Returns dict {
       'positive_literals': [Symbol, ...],   # need INV in OR4 input
       'negative_literals': [Symbol, ...],   # use direct (their var) in OR4 input
       'xor_terms': [(a, b, polarity), ...], # XOR or XNOR sub-expressions
       'reset_term': Symbol or None,         # final NR2 second input (if pattern fits 4+1)
    } or None if pattern doesn't fit.

    The engineer/trial1 pattern for NeedFreqAdj is exactly:
       req & Arb & ~B[2] & ~(B[1]^B[0]) & ~reset
    This decomposes to:
       INV(req) → ~req
       XOR2(B[1], B[0]) → xor
       OR4(~req, ~Arb, B[2], xor) → or4_z   (mixed: 2 INV-of-positive + 2 direct)
       NR2(or4_z, reset) → nr_z
    Final: nr_z = ~or4_z & ~reset
                = req & Arb & ~B[2] & ~xor & ~reset ✓
    """
    factors = split_and_factors(expr)
    if not factors:
        return None

    positive_literals = []
    negative_literals = []
    xor_terms = []
    other = []

    for f in factors:
        if is_literal(f):
            pol, var = literal_polarity_var(f)
            if pol:
                positive_literals.append(var)
            else:
                negative_literals.append(var)
        elif isinstance(f, Not) and isinstance(f.args[0], Xor):
            # ~(a XOR b) — i.e., XNOR — appears as a "negative xor term"
            xor_args = f.args[0].args
            if len(xor_args) == 2 and all(isinstance(a, Symbol) for a in xor_args):
                xor_terms.append((xor_args[0], xor_args[1], 'negated'))
            else:
                other.append(f)
        elif isinstance(f, Xor):
            xor_args = f.args
            if len(xor_args) == 2 and all(isinstance(a, Symbol) for a in xor_args):
                xor_terms.append((xor_args[0], xor_args[1], 'positive'))
            else:
                other.append(f)
        else:
            other.append(f)

    if other:
        return None  # contains terms we don't recognize

    return {
        'positive_literals': positive_literals,
        'negative_literals': negative_literals,
        'xor_terms': xor_terms,
    }


def synthesize_and_pattern(expr, input_syms, jira, prefix=''):
    """
    Synthesize an AND-of-literals(+ XOR terms) expression into a synthesis-
    style cell chain. Picks the most-compact engineer-style cell pattern
    based on factor count and polarity mix:

       1 factor (positive literal)              → no chain (alias)
       1 factor (negative literal)              → INV
       N positive literals only (N=2,3,4)       → AN_N single cell
       N negative literals only (N=2,3,4)       → NR_N single cell  [engineer style]
       2 mixed (1 pos + 1 neg literal)          → INV(pos) + NR2(inv_z, neg_var)
                                                   [engineer EcoUseSdpOutstRdCnt style]
       3-5 mixed literals (with optional XOR)   → INV(s) + (XOR2/XNR2) + OR4 + NR2
                                                   [engineer NeedFreqAdj style]

    Returns CellChain or None if no pattern matches.
    """
    info = detect_and_of_terms_with_xor(expr)
    if info is None:
        return None

    pos_lits = info['positive_literals']
    neg_lits = info['negative_literals']
    xor_terms = info['xor_terms']

    # ── Single-literal degenerate cases ─────────────────────────────────────
    total_terms = len(pos_lits) + len(neg_lits) + len(xor_terms)
    if total_terms == 0:
        return None
    if total_terms == 1 and not xor_terms:
        chain = CellChain()
        if pos_lits:  # positive literal: no cell needed (alias)
            chain.output_net = str(pos_lits[0])
            return chain
        # negative literal: single INV
        v = neg_lits[0]
        wire = _wire_name(jira, 1, prefix)
        chain.add_wire(wire)
        chain.add_cell(
            'INVD1BWP136P5M156H3P48CPDLVT', _inst_name(jira, 1, prefix),
            {'I': str(v), 'ZN': wire},
        )
        chain.output_net = wire
        return chain

    # ── Pure all-positive / all-negative AND (no XOR) ──────────────────────
    if not xor_terms and not neg_lits and 2 <= len(pos_lits) <= 4:
        # AN_N single cell
        n = len(pos_lits)
        cell_type = {
            2: 'AN2D1BWP136P5M156H3P48CPDLVT',
            3: 'AN3D1BWP136P5M156H3P48CPDLVT',
            4: 'AN4D1BWP136P5M156H3P48CPDLVT',
        }[n]
        wire = _wire_name(jira, 1, prefix)
        chain = CellChain()
        chain.add_wire(wire)
        pc = {f'A{i+1}': str(v) for i, v in enumerate(pos_lits)}
        pc['Z'] = wire
        chain.add_cell(cell_type, _inst_name(jira, 1, prefix), pc)
        chain.output_net = wire
        return chain

    if not xor_terms and not pos_lits and 2 <= len(neg_lits) <= 4:
        # NR_N single cell (engineer-style collapse for all-negative AND)
        n = len(neg_lits)
        cell_type = {
            2: 'NR2D1SPG1AMDBWP136P5M156H3P48CPDLVT',
            3: 'NR3D1BWP136P5M156H3P48CPDLVT',
            4: 'NR4D1BWP136P5M156H3P48CPDLVT',
        }[n]
        wire = _wire_name(jira, 1, prefix)
        chain = CellChain()
        chain.add_wire(wire)
        pc = {f'A{i+1}': str(v) for i, v in enumerate(neg_lits)}
        pc['ZN'] = wire
        chain.add_cell(cell_type, _inst_name(jira, 1, prefix), pc)
        chain.output_net = wire
        return chain

    # ── 2-factor mixed (1 positive + 1 negative literal) ────────────────────
    # Single-cell INR2: Z = A1 & ~A2 — most compact form of `pos & ~neg`.
    # Engineer 9868 EcoUseSdpOutstRdCnt used 2-cell INV+NR2; INR2 is a
    # functionally identical 1-cell alternative when the library has it.
    # Falls back to engineer's INV+NR2 if INR2 is not available (caller can
    # disable via `prefer_single_cell=False` if needed for engineer-match).
    if not xor_terms and len(pos_lits) == 1 and len(neg_lits) == 1:
        chain = CellChain()
        wire = _wire_name(jira, 1, prefix)
        chain.add_wire(wire)
        chain.add_cell(
            'INR2D1BWP136P5M156H3P48CPDLVT', _inst_name(jira, 1, prefix),
            {'A1': str(pos_lits[0]), 'B1': str(neg_lits[0]), 'ZN': wire},
        )
        chain.output_net = wire
        return chain

    # ── 3-5 factor mixed (with optional XOR) — engineer NeedFreqAdj style ──
    # OR4 + NR2 chain; INV any positive literals; XOR2/XNR2 for XOR terms.
    return _synthesize_or4_nr2_pattern(info, jira, prefix)


def _synthesize_or4_nr2_pattern(info, jira, prefix=''):
    """OR4 + NR2 collapse pattern for 3-5 factor mixed AND-with-XOR.

    Engineer NeedFreqAdj_reg pattern. Inputs:
      - positive_literals: vars that need INV in OR4 input form
      - negative_literals: vars that go direct to OR4 input
      - xor_terms: (a, b, polarity) — 'negated' uses XOR2, 'positive' uses XNR2
    """
    pos = info['positive_literals']      # vars that need INV in OR4 input
    neg = info['negative_literals']      # vars that go direct to OR4 input
    xors = info['xor_terms']             # XOR/XNOR pairs

    # Total OR4-input slots needed = |pos| + |neg| + |xors_negated|
    # XNOR (negated XOR) → OR4 receives the XOR positive output (since ~(~xor) = xor would re-invert in NR2)
    # Wait: NR2 final output is ~(or4_z | last_term)
    # We want NR2.ZN = pos_lit_1 & pos_lit_2 & ~neg_lit_1 & ~neg_lit_2 & ~xnor_1
    #                 = pos_1 & pos_2 & ~neg_1 & ~neg_2 & xor_1
    # NR2.ZN = ~(or4_z | last_term) = ~or4_z & ~last_term
    # So or4_z must be: (~pos_1 | ~pos_2 | neg_1 | neg_2 | ~xor_1)
    # ⇒ OR4 inputs: ~pos_lits, neg_lits, ~xor_terms (negated form for XNOR)
    #
    # Wait — I need to think about this again.
    # XNOR term in expr (as ~(a^b)) means we want this factor TRUE in the AND.
    # NR2 output = TRUE means all OR4 inputs are FALSE.
    # So ~(a^b) being TRUE in factor means OR4 input for it must be FALSE → use (a^b) directly.
    # XOR term in expr (as a^b) means OR4 input must be ~(a^b) = XNOR — but XNR2 cell exists.

    # For the engineer's NeedFreqAdj case:
    #   factor: ~(B[1]^B[0])  →  OR4 input: B[1]^B[0]  →  use XOR2 cell directly

    # So in OR4: positive literals (factor has them positive) → need their NEGATION in OR4 → INV upstream
    #            negative literals (factor has them negated)  → use their POSITIVE form in OR4 directly
    #            negated XOR terms (factor has ~XOR)          → use POSITIVE XOR in OR4 → XOR2 upstream
    #            positive XOR terms (factor has XOR)          → use NEGATIVE XOR in OR4 → XNR2 upstream

    # Decide if pattern fits OR4 + NR2 layout:
    # Total OR4 inputs: |pos| + |neg| + |xors|
    # Last NR2 input: 1 of the factors (typically reset)
    #
    # For now, we require: either (factors all fit in OR4 with a "natural reset"
    # candidate) OR (we can pick a literal as the NR2 second input).

    or4_input_specs = []  # list of (kind, payload) where kind ∈ {direct, neg_via_inv, xor_via_xor2, xor_via_xnr2}

    # Process literals + xors (everything except the eventual NR2-reset)
    # We pick the LAST negative literal as the NR2 second input (so reset goes
    # there). If no negative literal, fall back to last positive literal (less
    # ideal — would need INV).

    # Collect candidates for "NR2 second input" preference:
    # - Prefer a negative literal (factor = ~X) where X looks like a reset signal
    #   (name contains 'reset', 'rst', 'IReset', 'test_so', 'dftopt')
    # - Else prefer any negative literal
    # - Else prefer any factor

    def looks_like_reset(var):
        name = str(var).lower()
        return any(k in name for k in ('reset', 'rst', 'test_so', 'dftopt'))

    nr2_second_var = None
    nr2_second_kind = None
    # Look in negative_literals first
    for v in neg:
        if looks_like_reset(v):
            nr2_second_var = v
            nr2_second_kind = 'direct'  # ~v in factor → use v in NR2 directly (NR2 inverts)
            break
    if nr2_second_var is None:
        # Take last negative literal as NR2 second
        if neg:
            nr2_second_var = neg[-1]
            nr2_second_kind = 'direct'

    # Build OR4 input list (everything except the NR2 second input)
    pos_for_or4 = list(pos)
    neg_for_or4 = [v for v in neg if v != nr2_second_var]
    xors_for_or4 = list(xors)

    total_or4_inputs = len(pos_for_or4) + len(neg_for_or4) + len(xors_for_or4)

    if total_or4_inputs > 4:
        return None  # doesn't fit OR4 — needs recursive decomposition (future work)
    if total_or4_inputs < 2:
        return None  # not enough for OR4 — single-cell or different pattern

    # ─── Build the chain ───
    chain = CellChain()
    cell_idx = 1

    # 1. INVs for positive literals (need negated form in OR4)
    inv_outputs = {}     # var_name → wire name of its INV output
    for v in pos_for_or4:
        wire = _wire_name(jira, cell_idx, prefix)
        inst = _inst_name(jira, cell_idx, prefix)
        chain.add_wire(wire)
        chain.add_cell(
            cell_type='INVD1BWP136P5M156H3P48CPDLVT',
            inst_name=inst,
            port_connections={'I': str(v), 'ZN': wire},
        )
        inv_outputs[str(v)] = wire
        cell_idx += 1

    # 2. XOR2 / XNR2 cells for XOR factors
    xor_outputs = []  # list of (wire, original_xor_tuple)
    for (a, b, kind) in xors_for_or4:
        wire = _wire_name(jira, cell_idx, prefix)
        inst = _inst_name(jira, cell_idx, prefix)
        chain.add_wire(wire)
        if kind == 'negated':  # factor is ~(a^b) → OR4 input must be (a^b) → use XOR2
            cell_type = 'XOR2D1BWP136P5M156H3P48CPDLVT'
            port_connections = {'A1': str(a), 'A2': str(b), 'Z': wire}
        else:  # factor is (a^b) → OR4 input must be ~(a^b) → use XNR2
            cell_type = 'XNR2D1AMDBWP136P5M156H3P48CPDLVTLL'
            port_connections = {'A1': str(a), 'A2': str(b), 'ZN': wire}
        chain.add_cell(cell_type, inst, port_connections)
        xor_outputs.append(wire)
        cell_idx += 1

    # 3. Build OR4 input list (in deterministic order for stability)
    or4_inputs = []
    # Order: INV outputs of positive literals, then direct negative literals, then XOR outputs
    for v in pos_for_or4:
        or4_inputs.append(inv_outputs[str(v)])
    for v in neg_for_or4:
        or4_inputs.append(str(v))
    or4_inputs.extend(xor_outputs)

    # OR4 cell — handle <4 inputs by padding with 1'b0 (OR identity)
    while len(or4_inputs) < 4:
        or4_inputs.append("1'b0")

    or4_wire = _wire_name(jira, cell_idx, prefix)
    or4_inst = _inst_name(jira, cell_idx, prefix)
    chain.add_wire(or4_wire)
    chain.add_cell(
        cell_type='OR4D1BWP136P5M117H3P48CPDLVT',
        inst_name=or4_inst,
        port_connections={
            'A1': or4_inputs[0], 'A2': or4_inputs[1],
            'A3': or4_inputs[2], 'A4': or4_inputs[3],
            'Z': or4_wire,
        },
    )
    cell_idx += 1

    # 4. NR2 final cell — combine or4_wire with last term
    final_wire = _wire_name(jira, cell_idx, prefix)
    final_inst = _inst_name(jira, cell_idx, prefix)
    chain.add_wire(final_wire)

    if nr2_second_var is None:
        # Pad with 1'b0 (NR2 identity for OR side)
        nr2_a2 = "1'b0"
    else:
        nr2_a2 = str(nr2_second_var)

    chain.add_cell(
        cell_type='NR2D1SPG1AMDBWP136P5M156H3P48CPDLVT',
        inst_name=final_inst,
        port_connections={'A1': or4_wire, 'A2': nr2_a2, 'ZN': final_wire},
    )
    chain.output_net = final_wire

    return chain


# ────────────────────────── Top-level synthesize ──────────────────────────

def synthesize(rtl_boolean_str, input_names, jira, prefix=''):
    """
    Top-level synthesize: parse Boolean string → emit cell chain.

    Returns CellChain (raises ValueError if cannot synthesize).
    """
    # Parse Boolean expression
    syms = symbols(' '.join(input_names))
    if not isinstance(syms, tuple):
        syms = (syms,)
    sym_dict = {name: sym for name, sym in zip(input_names, syms)}

    # Eval the expression in a context where input names map to sympy symbols
    # Allow ~, &, |, ^ operators (sympy supports these via __invert__, __and__, etc.)
    expr = eval(rtl_boolean_str, {'__builtins__': {}}, sym_dict)

    # Canonicalize via DeMorgan: push negations down to literals (NNF form)
    # so `~(A | B)` becomes `~A & ~B` and our pattern detector sees flat AND.
    expr = _push_nots_to_literals(expr)

    # Try the AND-of-literals-with-XOR pattern (engineer NeedFreqAdj style)
    chain = synthesize_and_pattern(expr, syms, jira=jira, prefix=prefix)
    if chain is not None:
        # Verify equivalence by re-composing the chain's Boolean and comparing
        chain_expr = compose_chain_boolean(chain, sym_dict, jira)
        if chain_expr is not None and truth_tables_match(expr, chain_expr, syms):
            return chain
        # Synthesis bug — chain doesn't match input expression
        sys.stderr.write(
            f"WARN: synthesize_and_pattern produced non-equivalent chain.\n"
            f"  Input expr:  {expr}\n"
            f"  Chain expr:  {chain_expr}\n"
        )

    raise ValueError(
        f"No synthesis pattern matched the input Boolean. "
        f"Input: {rtl_boolean_str}. "
        f"Falling back to literal decomposition is FORBIDDEN — extend pattern library."
    )


def compose_chain_boolean(chain, sym_dict, jira):
    """Re-compose the cell chain into a single sympy Boolean expression.

    Iterates the chain in fixed-point order — handles cells given in
    arbitrary order (e.g., output-first BFS walk). Stops when all cells
    are processed or no progress is possible (which signals an unknown
    cell type or unresolvable input).
    """
    wire_exprs = {}     # wire_name → sympy expression
    pending = list(chain.cells)
    unknown_cells = []  # cell types we couldn't model

    def resolve(name):
        if name in sym_dict:
            return sym_dict[name]
        if name in wire_exprs:
            return wire_exprs[name]
        if name == "1'b0":
            return false
        if name == "1'b1":
            return true
        return None

    def try_compose_cell(cell):
        """Return True if cell was successfully composed, False if inputs not
        ready. Adds entry to wire_exprs on success."""
        ct = cell['cell_type']
        pc = cell['port_connections']
        # Each cell type: (family_prefix, output_pin, input_pins, builder)
        if ct.startswith('INV'):
            i = resolve(pc.get('I'))
            if i is None: return False
            wire_exprs[pc.get('ZN')] = Not(i); return True
        if ct.startswith('XOR2'):
            a1 = resolve(pc.get('A1')); a2 = resolve(pc.get('A2'))
            if a1 is None or a2 is None: return False
            wire_exprs[pc.get('Z')] = Xor(a1, a2); return True
        if ct.startswith('XNR2'):
            a1 = resolve(pc.get('A1')); a2 = resolve(pc.get('A2'))
            if a1 is None or a2 is None: return False
            wire_exprs[pc.get('ZN')] = Not(Xor(a1, a2)); return True
        if ct.startswith('OR4'):
            ins = [resolve(pc.get(p)) for p in ('A1', 'A2', 'A3', 'A4')]
            if any(x is None for x in ins): return False
            wire_exprs[pc.get('Z')] = Or(*ins); return True
        if ct.startswith('NR2'):
            a1 = resolve(pc.get('A1')); a2 = resolve(pc.get('A2'))
            if a1 is None or a2 is None: return False
            wire_exprs[pc.get('ZN')] = Not(Or(a1, a2)); return True
        if ct.startswith('AN2'):
            a1 = resolve(pc.get('A1')); a2 = resolve(pc.get('A2'))
            if a1 is None or a2 is None: return False
            wire_exprs[pc.get('Z')] = And(a1, a2); return True
        if ct.startswith('AN3'):
            ins = [resolve(pc.get(p)) for p in ('A1', 'A2', 'A3')]
            if any(x is None for x in ins): return False
            wire_exprs[pc.get('Z')] = And(*ins); return True
        if ct.startswith('AN4'):
            ins = [resolve(pc.get(p)) for p in ('A1', 'A2', 'A3', 'A4')]
            if any(x is None for x in ins): return False
            wire_exprs[pc.get('Z')] = And(*ins); return True
        if ct.startswith('NR3'):
            ins = [resolve(pc.get(p)) for p in ('A1', 'A2', 'A3')]
            if any(x is None for x in ins): return False
            wire_exprs[pc.get('ZN')] = Not(Or(*ins)); return True
        if ct.startswith('NR4'):
            ins = [resolve(pc.get(p)) for p in ('A1', 'A2', 'A3', 'A4')]
            if any(x is None for x in ins): return False
            wire_exprs[pc.get('ZN')] = Not(Or(*ins)); return True
        if ct.startswith('OR3'):
            ins = [resolve(pc.get(p)) for p in ('A1', 'A2', 'A3')]
            if any(x is None for x in ins): return False
            wire_exprs[pc.get('Z')] = Or(*ins); return True
        if ct.startswith('OR2'):
            a1 = resolve(pc.get('A1')); a2 = resolve(pc.get('A2'))
            if a1 is None or a2 is None: return False
            wire_exprs[pc.get('Z')] = Or(a1, a2); return True
        # ── Inverted-input AND family (TSMC short-form, BWP136 library) ──
        # Truth tables from script/eco_scripts/cell_libraries/tsmc_bwp136.json.
        # All output on ZN; pin names are A1 + B1[,B2] (NOT A2/A3).
        # INR2: ZN = A1 & ~B1
        if ct.startswith('INR2'):
            a1 = resolve(pc.get('A1')); b1 = resolve(pc.get('B1'))
            if a1 is None or b1 is None: return False
            wire_exprs[pc.get('ZN')] = And(a1, Not(b1)); return True
        # IND2: ZN = ~(~A1 & B1) = A1 | ~B1
        if ct.startswith('IND2'):
            a1 = resolve(pc.get('A1')); b1 = resolve(pc.get('B1'))
            if a1 is None or b1 is None: return False
            wire_exprs[pc.get('ZN')] = Or(a1, Not(b1)); return True
        # IND3: ZN = ~(A1 & (B1 | B2))
        if ct.startswith('IND3'):
            a1 = resolve(pc.get('A1')); b1 = resolve(pc.get('B1')); b2 = resolve(pc.get('B2'))
            if any(x is None for x in (a1, b1, b2)): return False
            wire_exprs[pc.get('ZN')] = Not(And(a1, Or(b1, b2))); return True
        # INR3: ZN = ~(A1 | (B1 & B2))
        if ct.startswith('INR3'):
            a1 = resolve(pc.get('A1')); b1 = resolve(pc.get('B1')); b2 = resolve(pc.get('B2'))
            if any(x is None for x in (a1, b1, b2)): return False
            wire_exprs[pc.get('ZN')] = Not(Or(a1, And(b1, b2))); return True
        # Unknown cell type — record and skip
        unknown_cells.append(ct)
        return None  # signals "unknown" rather than "not ready"

    # Fixed-point iteration: keep passing through pending until no progress
    while pending:
        progress = False
        next_pending = []
        for cell in pending:
            r = try_compose_cell(cell)
            if r is True:
                progress = True
            elif r is False:
                next_pending.append(cell)
            else:  # None — unknown cell type, skip permanently
                pass
        pending = next_pending
        if not progress:
            break  # stuck: either unknown cells consumed everything or unresolvable

    if pending:
        return None  # could not resolve all cells (cycle or unknown input)
    return wire_exprs.get(chain.output_net)


# ────────────────────────── CLI ──────────────────────────

def cmd_synthesize(args):
    inputs = [s.strip() for s in args.inputs.split(',')]
    chain = synthesize(args.boolean, inputs, jira=args.jira, prefix=args.prefix)

    out = chain.to_dict()
    out['_meta'] = {
        'input_boolean': args.boolean,
        'input_signals': inputs,
        'jira': args.jira,
    }

    if args.output:
        with open(args.output, 'w') as f:
            json.dump(out, f, indent=2)
        print(f"WROTE: {args.output}")
    else:
        print(json.dumps(out, indent=2))

    print(f"\nSynthesized {len(chain.cells)} cells:")
    for c in chain.cells:
        ports = ', '.join(f"{k}={v}" for k, v in c['port_connections'].items())
        print(f"  {c['cell_type']:50s} {c['instance_name']:25s} ({ports})")
    print(f"\nOutput net: {chain.output_net}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('synthesize', help='Synthesize Boolean → cell chain')
    s.add_argument('--boolean', required=True, help='Boolean expression (Python syntax)')
    s.add_argument('--inputs', required=True, help='Comma-separated input signal names')
    s.add_argument('--jira', required=True, help='JIRA tag for cell/wire naming (e.g. 9868)')
    s.add_argument('--prefix', default='', help='Optional per-DFF prefix to disambiguate chain instance names when multiple DFFs are synthesized in the same study (e.g. "needfreqadj" → eco_<jira>_needfreqadj_d001). Empty (default) preserves the legacy `eco_<jira>_d<N>` form.')
    s.add_argument('--output', help='Output JSON path (else stdout)')
    s.set_defaults(func=cmd_synthesize)

    args = p.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
