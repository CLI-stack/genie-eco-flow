#!/usr/bin/env python3
"""
eco_pick_sibling.py — Deterministic sibling-module picker for Step 1 mode_s_anchor.

Given a host module name (e.g. "umcarbctrlsw"), enumerates peer module instances
under the same parent module, and ranks them by:
  1. DFF count in peer module body
  2. Dominant .SE-net cluster size (most-common SE wire prefix has ≥N members)

Returns the top-ranked peer that is NOT the host module itself. Step 1 agent
reads this output and emits as `mode_s_anchor.sibling_module`.

Usage:
    python3 eco_pick_sibling.py \\
        --netlist     <REF_DIR>/data/PreEco/PrePlace.v.gz \\
        --host-module <module_name>             # e.g. umcarbctrlsw \\
        --output      data/<TAG>_eco_sibling_pick.json \\
        [--top 5]                                # report top N candidates
"""
import argparse, gzip, json, re, sys
from collections import Counter
from pathlib import Path


def _open_text(path):
    if str(path).endswith('.gz'):
        return gzip.open(path, 'rt')
    return open(path, 'r')


# Patterns
DFF_CELL_RE = re.compile(r'^\s*(SDF\w+|MB\w*SDF\w+)\s+([A-Za-z_][A-Za-z_0-9]+)\s*\(')
SE_PIN_RE   = re.compile(r'\.\s*SE\s*\(\s*([A-Za-z_][A-Za-z_0-9\[\]]*)\s*\)')
SI_PIN_RE   = re.compile(r'\.\s*SI\s*\(\s*([A-Za-z_][A-Za-z_0-9\[\]]*)\s*\)')
Q_PIN_RE    = re.compile(r'\.\s*Q\s*\(\s*([A-Za-z_][A-Za-z_0-9\[\]]*)\s*\)')
MOD_DEF_RE  = re.compile(r'^module\s+(\S+?)\s*\(')
MOD_END_RE  = re.compile(r'^\s*endmodule')
# Submodule instantiation:  "<module_name> <inst_name> ("
INST_RE     = re.compile(r'^\s*([A-Za-z_]\w+)\s+([A-Za-z_]\w+)\s*\(')


def find_module_children(lines, host_module):
    """Find host_module's body and list all submodule instantiations INSIDE it
    (children, not siblings). Used by --host-scope=down to escalate sibling
    pick when no peer at parent scope has a viable scan-en cluster but the
    host's own children might (e.g. tile-top umccmd → ARB/DCQARB which has
    hundreds of DFFs).

    Returns (host_module_name_actual, host_start, host_end, list_of_child_instantiations).
    Returns (None, None, None, []) if host body not found."""
    cur_mod = None
    cur_start = None
    # Match host_module exactly OR with _0/_1 uniquification suffix
    host_re = re.compile(rf'^module\s+{re.escape(host_module)}(_\d+)?\s*[(\s]')
    for i, line in enumerate(lines):
        m = MOD_DEF_RE.match(line)
        if m and host_re.match(line):
            cur_mod = m.group(1)
            cur_start = i
            # Walk forward to find this host's endmodule
            depth = 0
            for j in range(cur_start, len(lines)):
                if MOD_DEF_RE.match(lines[j]):
                    depth += 1
                elif MOD_END_RE.match(lines[j]):
                    depth -= 1
                    if depth == 0:
                        return cur_mod, cur_start, j, _list_instantiations(lines[cur_start:j+1])
            break
    return None, None, None, []


def find_module_instantiations_in_parent(lines, host_module):
    """Find any module body that instantiates host_module (or a _0/_1/prefix variant).
    Returns (parent_module_name, parent_start_line, parent_end_line, list_of_instantiated_modules).
    Returns (None, None, None, []) if host module instantiation not found."""

    host_pats = [
        re.compile(rf'^\s*{re.escape(host_module)}\s+\w+\s*\('),
        re.compile(rf'^\s*{re.escape(host_module)}_0\s+\w+\s*\('),
        re.compile(rf'^\s*{re.escape(host_module)}_1\s+\w+\s*\('),
        re.compile(rf'^\s*\S+_{re.escape(host_module)}\s+\w+\s*\('),
    ]

    # Walk modules; for each, scan body for host instantiation
    cur_mod = None
    cur_start = None
    candidates = []

    for i, line in enumerate(lines):
        m = MOD_DEF_RE.match(line)
        if m:
            cur_mod = m.group(1)
            cur_start = i
            continue
        if MOD_END_RE.match(line):
            cur_mod = None
            cur_start = None
            continue
        if cur_mod and any(p.match(line) for p in host_pats):
            # Found host instantiation inside cur_mod — this is the parent
            # Walk forward to find endmodule of this parent
            depth = 0
            for j in range(cur_start, len(lines)):
                if MOD_DEF_RE.match(lines[j]):
                    depth += 1
                elif MOD_END_RE.match(lines[j]):
                    depth -= 1
                    if depth == 0:
                        return cur_mod, cur_start, j, _list_instantiations(lines[cur_start:j+1])
            break
    return None, None, None, []


def _list_instantiations(parent_body_lines):
    """Within a module body, list all submodule instantiations — return list of
    (module_type, instance_name) tuples."""
    insts = []
    seen_inst_lines = set()  # avoid double-counting if instance spans multi-line
    for ln in parent_body_lines:
        m = INST_RE.match(ln)
        if not m:
            continue
        mod_type, inst_name = m.group(1), m.group(2)
        # Skip lines that are actually port_decls, wire decls, etc.
        if mod_type in ('input', 'output', 'inout', 'wire', 'reg', 'tri',
                        'assign', 'parameter', 'localparam', 'genvar',
                        'always', 'initial', 'function', 'task', 'module',
                        'endmodule', 'generate', 'endgenerate'):
            continue
        # Skip if mod_type starts with cell library prefix (single cell instance)
        # heuristic: cell types are usually all-uppercase + digits
        if re.match(r'^[A-Z][A-Z0-9_]*\d', mod_type) and len(mod_type) > 4:
            # Looks like a library cell (e.g. INVD1BWP...), skip
            continue
        # Skip synthesizer-emitted wrapper modules: <prefix>_wrap_<UPPERCASE_CELL>
        # (e.g. ddrss_umccmd_t_ipu_mmac_t_wrap_SDFQD1AMDBWP136P5M273H3P48CPDLVT).
        # These are thin wrappers around a single library cell, not real RTL
        # submodules — they always have 1-4 DFFs and never pass the viability
        # gate. On 9868 EcoUseSdpOutstRdCnt this filter drops 477 false peers
        # to ~10 real RTL submodules (cosmetic — picker already returned the
        # right verdict before, just with noisy output).
        if re.search(r'_wrap_[A-Z][A-Z0-9_]*\d', mod_type):
            continue
        if (mod_type, inst_name) not in seen_inst_lines:
            seen_inst_lines.add((mod_type, inst_name))
            insts.append((mod_type, inst_name))
    return insts


def find_instance_path_to_module(all_lines, target_module, tile_module=None):
    """Walk the netlist and return the FM-resolvable instance hierarchy from
    tile-down to target_module type — e.g. for sibling=ddrss_umccmd_t_umcdcqarb_0
    instantiated as DCQARB inside ddrss_umccmd_t_umcarb (which is instantiated as
    ARB inside the tile), returns 'ARB/DCQARB'.

    FM session is rooted at the tile module's internal scope; its instance path is
    therefore tile-relative. Returns the empty string when target_module is the
    tile itself (top-level — no prefix needed).

    Algorithm: walk modules; for each, scan body for `<target_module> <inst> (`.
    On hit, record (parent_mod, inst_name) and recurse with parent_mod as the new
    target. Stop when target_module == tile_module OR no parent is found.
    """
    if not target_module:
        return ''
    chain = []  # list of inst names from outer→inner
    cur = target_module
    visited = set()
    while True:
        if tile_module and cur == tile_module:
            break
        if cur in visited:
            break  # cycle guard
        visited.add(cur)
        # Find which module instantiates `cur`
        parent_mod = None
        parent_inst = None
        cur_mod = None
        cur_start = None
        inst_pat = re.compile(rf'^\s*{re.escape(cur)}\s+([A-Za-z_]\w*)\s*\(')
        for i, line in enumerate(all_lines):
            m = MOD_DEF_RE.match(line)
            if m:
                cur_mod = m.group(1); cur_start = i; continue
            if MOD_END_RE.match(line):
                cur_mod = None; cur_start = None; continue
            if cur_mod and cur_mod != cur:
                im = inst_pat.match(line)
                if im:
                    # Skip lines that are decls (input/output/wire/...)
                    parent_mod = cur_mod
                    parent_inst = im.group(1)
                    break
        if parent_mod is None:
            break  # cur is top — no parent
        chain.insert(0, parent_inst)
        cur = parent_mod
    return '/'.join(chain)


def find_module_body(lines, mod_name):
    """Find a module's body lines (start to endmodule). Tries exact, _0, _1,
    and tile-prefixed variants. Returns list of body lines.

    Linear-scan fallback. For high-fan-out parents (e.g. EcoUseSdpOutstRdCnt
    with 20+ peer candidates), prefer find_module_body_cached() with a prebuilt
    module index — single linear scan per netlist instead of one per candidate.
    """
    candidates = [
        re.compile(rf'^module\s+{re.escape(mod_name)}\s*\('),
        re.compile(rf'^module\s+{re.escape(mod_name)}_0\s*\('),
        re.compile(rf'^module\s+{re.escape(mod_name)}_1\s*\('),
        re.compile(rf'^module\s+\S+_{re.escape(mod_name)}\s*\('),
    ]
    for i, line in enumerate(lines):
        if any(p.match(line) for p in candidates):
            depth = 0
            for j in range(i, len(lines)):
                if re.match(r'^module\s+', lines[j]):
                    depth += 1
                elif MOD_END_RE.match(lines[j]):
                    depth -= 1
                    if depth == 0:
                        return lines[i:j+1]
    return []


def _build_module_index(lines):
    """Single-pass scan: return {module_name: (start_idx, end_idx)} for every
    module declaration in the netlist. Used to turn per-candidate O(N) module
    body lookups into O(1) dict reads — the dominant speedup for high-fan-out
    parents like EcoUseSdpOutstRdCnt where the picker evaluates 20+ peers and
    each peer used to re-scan the full Route netlist (~30-60 s decompressed)."""
    index = {}
    stack = []
    for i, line in enumerate(lines):
        m = MOD_DEF_RE.match(line)
        if m:
            stack.append((m.group(1), i))
            continue
        if MOD_END_RE.match(line) and stack:
            name, start = stack.pop()
            index[name] = (start, i)
    return index


def _build_inverse_inst_index(lines, mod_index):
    """For each module type, list every (parent_module, inst_name) where it is
    instantiated. Replaces the linear all-lines scan inside
    find_instance_path_to_module() with a depth-bounded dict walk."""
    inverse = {}
    for parent_mod, (start, end) in mod_index.items():
        body = lines[start:end + 1]
        for child_mod, inst_name in _list_instantiations(body):
            inverse.setdefault(child_mod, []).append((parent_mod, inst_name))
    return inverse


def find_module_body_cached(lines, mod_index, mod_name):
    """O(1) variant of find_module_body — uses a prebuilt module index.

    Honours the same fallback order as the linear scanner: exact name first,
    then _0/_1 variants, then tile-prefixed (_<mod>) variants. Returns an
    empty list when no candidate is in the index."""
    if mod_name in mod_index:
        s, e = mod_index[mod_name]
        return lines[s:e + 1]
    for variant in (f'{mod_name}_0', f'{mod_name}_1'):
        if variant in mod_index:
            s, e = mod_index[variant]
            return lines[s:e + 1]
    suffix = '_' + mod_name
    for k, (s, e) in mod_index.items():
        if k.endswith(suffix):
            return lines[s:e + 1]
    return []


def find_instance_path_to_module_cached(inv_index, target_module, tile_module=None):
    """O(depth) variant of find_instance_path_to_module — uses a prebuilt
    inverse instantiation index. Returns the tile-relative instance path."""
    if not target_module:
        return ''
    chain = []
    cur = target_module
    visited = set()
    while True:
        if tile_module and cur == tile_module:
            break
        if cur in visited:
            break
        visited.add(cur)
        parents = inv_index.get(cur, [])
        if not parents:
            break
        parent_mod, parent_inst = parents[0]
        chain.insert(0, parent_inst)
        cur = parent_mod
    return '/'.join(chain)


def _route_dff_pin_map(route_lines, sib_module, route_mod_index=None):
    """Walk Route-stage netlist body of sib_module and return:
       - dead: set of DFF instance names whose .SE is constant-tied (scan-dead)
       - alive: set of DFF instance names that are scan-alive in Route
       - pin_map: { inst_name: {'SI': route_si, 'SE': route_se, 'Q': route_q} }
         The Route-stage wire NAMES for each DFF (CTS-renamed in Route — they
         differ from PP-stage names). Studier needs these for Route bridge
         source selection; querying PP-stage names in Route returns FM-036.

    When route_mod_index is provided (recommended), the module body lookup is
    O(1). Without it, falls back to a linear scan — keep the fallback so the
    function stays callable from non-main contexts.
    """
    pin_map = {}
    if not route_lines or not sib_module:
        return set(), set(), pin_map
    if route_mod_index is not None:
        body = find_module_body_cached(route_lines, route_mod_index, sib_module)
    else:
        body = find_module_body(route_lines, sib_module)
    if not body:
        return set(), set(), pin_map
    dead = set(); alive = set()
    for i, line in enumerate(body):
        m = DFF_CELL_RE.match(line)
        if not m:
            continue
        inst = m.group(2)
        # Walk forward to find pins
        block = ''
        depth = 0
        for j in range(i, min(i + 30, len(body))):
            block += body[j]
            for ch in body[j].split('//')[0]:
                if ch == '(': depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        break
            if depth == 0 and j > i:
                break
        sm = SE_PIN_RE.search(block)
        si_m = SI_PIN_RE.search(block)
        q_m  = Q_PIN_RE.search(block)
        if sm:
            se = sm.group(1).strip()
            if se in ("1'b0", "1'b1", "0", "1"):
                dead.add(inst)
            else:
                alive.add(inst)
                pin_map[inst] = {
                    'SI': si_m.group(1) if si_m else None,
                    'SE': se,
                    'Q':  q_m.group(1) if q_m else None,
                }
    return dead, alive, pin_map


def analyze_module(body_lines, prefix_chars=20, route_lines=None, sib_module=None,
                   route_mod_index=None):
    """Return (dff_count, dominant_se_cluster_size, dominant_se_prefix,
               anchor_dff, anchor_si_wire, anchor_se_wire, anchor_q_wire,
               route_alive_count).

    For the chosen anchor (first DFF in dominant SE cluster), also extract its
    .SI / .SE / .Q wire names — these are what FM Cat 8 will query (FM accepts
    wires/output-pin nets, not arbitrary input pin paths).

    When route_lines is provided, pre-filters out any DFF whose .SE in Route is
    a constant (scan-dead). Anchor selection then prefers Route-alive DFFs
    within the dominant SE cluster — produces a bridge source wire that
    survives CTS optimization.
    """
    # Phase 1: identify Route-dead DFFs + collect Route-stage pin map (if route
    # data provided). Route pin map gives studier the CTS-renamed wire names so
    # bridge source picks can be Route-validated, not just PP-validated.
    route_dead, route_alive, route_pin_map = (set(), set(), {})
    if route_lines and sib_module:
        route_dead, route_alive, route_pin_map = _route_dff_pin_map(
            route_lines, sib_module, route_mod_index=route_mod_index)

    se_nets = []
    # net_prefix → list of (DFF instance, si_wire, se_wire, q_wire) — preserve
    # order so we can prefer Route-alive instances when picking anchor.
    dff_info_for_dom_se = {}
    for i, line in enumerate(body_lines):
        m = DFF_CELL_RE.match(line)
        if not m:
            continue
        inst = m.group(2)
        # Walk forward up to ~30 lines to find pin connections
        block = ''
        depth = 0
        for j in range(i, min(i + 30, len(body_lines))):
            block += body_lines[j]
            for ch in body_lines[j].split('//')[0]:
                if ch == '(': depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        break
            if depth == 0 and j > i:
                break
        sm = SE_PIN_RE.search(block)
        if sm:
            net = sm.group(1)
            # When Route data available, exclude DFFs that are scan-dead at
            # Route — their SE wire vanished, making them unusable as bridge
            # anchors. Cluster size and anchor selection both skip them so the
            # surviving cluster reflects bridge-viable DFFs only.
            if route_lines and inst in route_dead:
                continue
            se_nets.append(net)
            pfx = net[:prefix_chars]
            si_m = SI_PIN_RE.search(block)
            q_m  = Q_PIN_RE.search(block)
            entry = (inst, si_m.group(1) if si_m else None, net, q_m.group(1) if q_m else None)
            dff_info_for_dom_se.setdefault(pfx, []).append(entry)
    if not se_nets:
        return len(se_nets), 0, None, None, None, None, None, len(route_alive), {}
    cluster = Counter(n[:prefix_chars] for n in se_nets)
    dom_pfx, dom_size = cluster.most_common(1)[0]
    # Anchor = first Route-alive DFF in the dominant SE cluster.
    # When no route data, dff_info_for_dom_se[pfx][0] is just the first DFF.
    candidates = dff_info_for_dom_se.get(dom_pfx, [])
    anchor, si_w, se_w, q_w = None, None, None, None
    anchor_route_pins = {}  # SI/SE/Q wire NAMES at Route stage for the anchor
    for inst, sib_si, sib_se, sib_q in candidates:
        # Already filtered above: if route_lines provided, only Route-alive
        # instances entered the list. So just take the first.
        anchor, si_w, se_w, q_w = inst, sib_si, sib_se, sib_q
        anchor_route_pins = route_pin_map.get(inst, {})
        break
    return len(se_nets), dom_size, dom_pfx, anchor, si_w, se_w, q_w, len(route_alive), anchor_route_pins


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--netlist', required=True)
    p.add_argument('--host-module', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--top', type=int, default=5,
                   help='report top N candidates (default 5)')
    p.add_argument('--min-dffs', '--min-cluster', dest='min_dffs', type=int, default=10,
                   help='minimum SE-cluster size for a peer to be considered viable (default 10). '
                        'Studier MD §0b-MODE-S SIBLING ESCALATION: re-invoke with --min-cluster=5 '
                        'when default returns no viable peer.')
    p.add_argument('--host-scope', choices=('parent', 'down'), default='parent',
                   help='Search scope for candidates. "parent" (default): search peer modules under '
                        'the parent that instantiates host (engineer pattern). "down": search '
                        'host\'s OWN children — escalation when host is tile-top and no parent-scope '
                        'peer has a viable scan-en cluster (e.g. umccmd → ARB/FEI/REGCMD children, '
                        'each containing hundreds of DFFs). Studier MD §0b-MODE-S SIBLING ESCALATION '
                        'mandates this as step 1 before constant_zero fallback.')
    p.add_argument('--tile-module', default='',
                   help='Tile module (e.g. ddrss_umccmd_t_umccmd or umccmd). Used to compute '
                        'fm_scope (FM-resolvable instance path from tile-internal root down to '
                        'sibling). Without it, fm_scope walks all the way to top.')
    p.add_argument('--route-netlist', default='',
                   help='OPTIONAL Route-stage PreEco netlist (e.g. <REF_DIR>/data/PreEco/'
                        'Route.v.gz). When provided, picker excludes DFFs whose .SE pin is '
                        'tied to 1\'b0 / 1\'b1 in Route — those DFFs are scan-dead (CTS '
                        'optimized away their scan_enable path) and unusable as bridge anchors. '
                        'Without this flag, picker may select a DFF whose bridge SE wire '
                        'vanishes in Route → FM-036 / cone divergence.')
    args = p.parse_args()

    with _open_text(args.netlist) as f:
        all_lines = f.readlines()
    # Build module-body and inverse-instantiation indexes ONCE per netlist.
    # Without these, every peer candidate triggered a fresh full-file scan
    # (find_module_body + find_instance_path_to_module). For high-fan-out
    # parents like EcoUseSdpOutstRdCnt (~20 peers), that turned a 10-20 min
    # picker run into seconds.
    pre_mod_index = _build_module_index(all_lines)
    pre_inv_index = _build_inverse_inst_index(all_lines, pre_mod_index)

    route_lines = None
    route_mod_index = None
    if args.route_netlist:
        try:
            with _open_text(args.route_netlist) as f:
                route_lines = f.readlines()
            route_mod_index = _build_module_index(route_lines)
        except Exception as e:
            print(f'WARN: cannot read --route-netlist {args.route_netlist!r}: {e}',
                  file=sys.stderr)
            route_lines = None
            route_mod_index = None

    if args.host_scope == 'down':
        # Escalation path: search host's CHILDREN instead of parent's other children.
        # Useful when host is tile-top (no parent-scope peers) but host's own children
        # contain large DFF clusters (e.g. umccmd → ARB/DCQARB/FEI/REGCMD).
        parent_mod, parent_start, parent_end, instantiations = \
            find_module_children(all_lines, args.host_module)
        if parent_mod is None:
            print(f'FAIL: host module {args.host_module!r} body not found for --host-scope=down',
                  file=sys.stderr)
            return 1
        # In down scope, "peers" = direct children of host (no host-self filtering needed)
        peer_modules = []
        seen_mods = set()
        for mod_type, inst_name in instantiations:
            if mod_type in seen_mods:
                continue
            seen_mods.add(mod_type)
            peer_modules.append((mod_type, inst_name))
    else:
        parent_mod, parent_start, parent_end, instantiations = \
            find_module_instantiations_in_parent(all_lines, args.host_module)

        if parent_mod is None:
            print(f'FAIL: host module {args.host_module!r} not instantiated in any module body',
                  file=sys.stderr)
            return 1

        # Filter out host instantiations (peer scope only — children of parent, minus host)
        peer_modules = []
        seen_mods = set()
        for mod_type, inst_name in instantiations:
            # Strip _0/_1 suffix for comparison
            base = re.sub(r'_\d+$', '', mod_type)
            host_base = re.sub(r'_\d+$', '', args.host_module)
            if base == host_base or base.endswith('_' + host_base) or host_base.endswith('_' + base):
                continue
            if mod_type in seen_mods:
                continue
            seen_mods.add(mod_type)
            peer_modules.append((mod_type, inst_name))

    # Analyze each peer
    candidates = []
    for mod_type, inst_name in peer_modules:
        body = find_module_body_cached(all_lines, pre_mod_index, mod_type)
        if not body:
            candidates.append({
                'module': mod_type, 'inst': inst_name,
                'dff_count': 0, 'dominant_se_cluster_size': 0,
                'dominant_se_prefix': None, 'anchor_dff': None,
                'anchor_si_wire': None, 'anchor_se_wire': None, 'anchor_q_wire': None,
                'route_alive_dff_count': 0,
                'viable': False, 'note': 'module body not found',
            })
            continue
        dff_count, dom_size, dom_pfx, anchor, si_w, se_w, q_w, route_alive_n, route_pins = \
            analyze_module(body, route_lines=route_lines, sib_module=mod_type,
                           route_mod_index=route_mod_index)
        # Compute FM-resolvable instance hierarchy from tile-internal root down
        # to this sibling. FM queries MUST use instance names, not module types,
        # or every find_equivalent_nets returns FM-036 (Unknown name).
        fm_scope = find_instance_path_to_module_cached(pre_inv_index, mod_type, args.tile_module)
        candidates.append({
            'module': mod_type, 'inst': inst_name,
            'fm_scope': fm_scope,
            'route_alive_dff_count': route_alive_n,
            'dff_count': dff_count,
            'dominant_se_cluster_size': dom_size,
            'dominant_se_prefix': dom_pfx,
            'anchor_dff': anchor,
            # PP-stage anchor wire names (default — used when --route-netlist not given)
            'anchor_si_wire': si_w,
            'anchor_se_wire': se_w,
            'anchor_q_wire':  q_w,
            # Route-stage anchor wire names (CTS-renamed; only present when
            # --route-netlist provided AND anchor DFF found in Route body).
            # Studier MUST use these for Route-stage bridge source wires —
            # querying PP names in Route returns FM-036 because CTS renamed
            # them (run 20260511201004 root cause: PP HFSNET_99954 → Route
            # HFSNET_47864; querying PP name returned 1'b0 from FM).
            'anchor_si_wire_route': route_pins.get('SI'),
            'anchor_se_wire_route': route_pins.get('SE'),
            'anchor_q_wire_route':  route_pins.get('Q'),
            'viable': dom_size >= args.min_dffs,
        })

    # Rank: viable first, then by dominant cluster size desc, then by total DFF count desc
    candidates.sort(key=lambda c: (-int(c['viable']),
                                   -c['dominant_se_cluster_size'],
                                   -c['dff_count']))

    out = {
        'host_module':       args.host_module,
        'parent_module':     parent_mod,
        'peer_count_total':  len(peer_modules),
        'peer_count_viable': sum(1 for c in candidates if c['viable']),
        'top_candidates':    candidates[:args.top],
        'recommended_pick':  candidates[0] if candidates and candidates[0]['viable'] else None,
        'all_candidates':    candidates,
    }
    Path(args.output).write_text(json.dumps(out, indent=2))

    print(f'ECO_RPT_GENERATED: sibling_pick → {args.output}')
    print(f'  host_module:      {args.host_module}')
    print(f'  parent_module:    {parent_mod}')
    print(f'  peers found:      {len(peer_modules)} ({out["peer_count_viable"]} viable)')
    if out['recommended_pick']:
        rec = out['recommended_pick']
        print(f'  RECOMMENDED:      {rec["module"]} (inst={rec["inst"]}, fm_scope={rec.get("fm_scope","?")}, dff_count={rec["dff_count"]}, se_cluster_size={rec["dominant_se_cluster_size"]}, anchor_dff={rec["anchor_dff"]})')
    else:
        print(f'  RECOMMENDED:      <NONE viable> — increase --min-dffs threshold or pick different parent scope')
    print()
    print(f'  Top {args.top} candidates:')
    for c in candidates[:args.top]:
        flag = '✓' if c['viable'] else '✗'
        print(f'    {flag} {c["module"]:50s} dffs={c["dff_count"]:5d}  se_cluster={c["dominant_se_cluster_size"]:5d}  anchor={c["anchor_dff"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
