#!/usr/bin/env python3
"""
eco_pick_bridge_dffs.py — Deterministic Mode-S anchor + bridge plumbing picker.

Given a sibling module body (extracted from PreEco netlist), returns:
  1. anchor_dff             — one DFF in the sibling whose .SE is the most-common scan-en wire
  2. consolidation_target_dffs — all DFFs sharing the same .SE-net cluster
  3. q_consumer_dff         — the DFF picked from consolidation list whose original .SI is
                              the most "redundant" (most-common SI net), best candidate to
                              rewire .SI to ECO_<jira>_Q_in
  4. candidate_bridge_source_se — most-common .SE wire (bridge SE buffer .I source)
  5. candidate_bridge_source_si — most-common .SI wire (bridge SI buffer .I source)

No hardcoded signal/port names. Pure structural analysis from netlist text.

Usage:
    python3 eco_pick_bridge_dffs.py \\
        --netlist     <REF_DIR>/data/PreEco/Route.v.gz \\
        --sibling-mod <module_name>     # exact, or with _0/_1/prefix-tile suffix \\
        --output      data/<TAG>_eco_bridge_pick.json
"""
import argparse, gzip, json, re, sys
from collections import Counter
from pathlib import Path


def _open_text(path):
    if str(path).endswith('.gz'):
        return gzip.open(path, 'rt')
    return open(path, 'r')


def find_module_body(lines, sibling_mod):
    """Return list of body lines (start to endmodule) for the named module.
    Tries exact, _0, _1, and tile-prefix-suffix variants."""
    candidates = [
        re.compile(rf'^module\s+{re.escape(sibling_mod)}\b'),
        re.compile(rf'^module\s+{re.escape(sibling_mod)}_0\b'),
        re.compile(rf'^module\s+{re.escape(sibling_mod)}_1\b'),
        re.compile(rf'^module\s+\S+_{re.escape(sibling_mod)}\b'),
    ]
    for i, line in enumerate(lines):
        if any(p.match(line) for p in candidates):
            # Walk to endmodule
            depth = 0
            for j in range(i, len(lines)):
                if re.match(r'^\s*module\s+', lines[j]):
                    depth += 1
                elif re.match(r'^\s*endmodule', lines[j]):
                    depth -= 1
                    if depth == 0:
                        return lines[i:j + 1]
    return []


# DFF cell types we recognize: anything starting with SDF (single-bit) or MB...SDF (multibit)
DFF_CELL_RE = re.compile(r'^\s*(SDF\w+|MB\w*SDF\w+)\s+([A-Za-z_][A-Za-z_0-9]+)\s*\(')
SE_PIN_RE   = re.compile(r'\.\s*SE\s*\(\s*([A-Za-z_][A-Za-z_0-9\[\]]*)\s*\)')
SI_PIN_RE   = re.compile(r'\.\s*SI\s*\(\s*([A-Za-z_][A-Za-z_0-9\[\]]*)\s*\)')


def collect_dff_pins(body_lines):
    """For each DFF instance in body, collect its .SE and .SI net names.
    Returns list of (cell_type, instance_name, se_net, si_net) tuples."""
    out = []
    i = 0
    while i < len(body_lines):
        m = DFF_CELL_RE.match(body_lines[i])
        if not m:
            i += 1
            continue
        cell_type = m.group(1)
        inst      = m.group(2)
        # Walk forward up to ~30 lines or until ');' to grab .SE and .SI
        block = ''
        depth = 0
        j = i
        while j < len(body_lines) and j < i + 30:
            block += body_lines[j]
            for ch in body_lines[j].split('//')[0]:
                if ch == '(': depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        break
            if depth == 0 and j > i:
                break
            j += 1
        se_m = SE_PIN_RE.search(block)
        si_m = SI_PIN_RE.search(block)
        se_net = se_m.group(1) if se_m else None
        si_net = si_m.group(1) if si_m else None
        if se_net or si_net:
            out.append((cell_type, inst, se_net, si_net))
        i = j + 1 if j > i else i + 1
    return out


def cluster_by_prefix(net_names, prefix_chars=20):
    """Group nets by their first `prefix_chars` characters. The dominant
    cluster (most members) is the scan-en cluster after CTS branching."""
    if not net_names:
        return {}
    groups = Counter()
    for n in net_names:
        groups[n[:prefix_chars]] += 1
    return dict(groups)


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--netlist',     required=True)
    p.add_argument('--sibling-mod', required=True)
    p.add_argument('--output',      required=True)
    p.add_argument('--prefix-chars', type=int, default=20,
                   help='cluster nets by their first N characters (default 20)')
    p.add_argument('--target-count', type=int, default=10,
                   help='target consolidation set size (default 10). Picker takes the '
                        'top-N DFFs from the most-frequent specific .SE wires within the '
                        'dominant prefix cluster — bounds the bridge load.')
    args = p.parse_args()

    with _open_text(args.netlist) as f:
        all_lines = f.readlines()
    body = find_module_body(all_lines, args.sibling_mod)
    if not body:
        print(f'FAIL: sibling module {args.sibling_mod!r} not found in {args.netlist}',
              file=sys.stderr)
        return 1

    dffs = collect_dff_pins(body)
    if not dffs:
        print(f'FAIL: no DFF cells found in {args.sibling_mod}', file=sys.stderr)
        return 1

    se_nets = [d[2] for d in dffs if d[2]]
    si_nets = [d[3] for d in dffs if d[3]]

    se_clusters = cluster_by_prefix(se_nets, args.prefix_chars)
    si_clusters = cluster_by_prefix(si_nets, args.prefix_chars)

    # Dominant SE cluster = candidate bridge source SE
    if not se_clusters:
        print('FAIL: no .SE pins found on any DFF', file=sys.stderr)
        return 1
    dom_se_prefix = max(se_clusters, key=se_clusters.get)
    dom_si_prefix = max(si_clusters, key=si_clusters.get) if si_clusters else None

    # Find DFFs whose .SE belongs to the dominant cluster — bound the size
    # by selecting from the most-frequent specific .SE wires within the cluster
    # until target_count is reached. Avoids ballooning bridge load.
    in_cluster = [
        {'cell_type': ct, 'instance_name': inst, 'original_se': se, 'original_si': si}
        for (ct, inst, se, si) in dffs
        if se and se.startswith(dom_se_prefix)
    ]
    se_freq_in_cluster = Counter(d['original_se'] for d in in_cluster)
    # Select DFFs from highest-frequency wires until target_count reached
    consolidation = []
    for wire, _ in se_freq_in_cluster.most_common():
        for d in in_cluster:
            if d['original_se'] == wire:
                consolidation.append(d)
                if len(consolidation) >= args.target_count:
                    break
        if len(consolidation) >= args.target_count:
            break

    # Anchor DFF: just the first one in the consolidation list
    anchor = consolidation[0] if consolidation else None

    # Q-closure DFF: pick from consolidation list, prefer SI in the dominant SI cluster
    # (most "redundant" SI — its original SI is part of a shared scan-chain branch).
    # Fallback: any DFF in consolidation.
    q_consumer = None
    if consolidation:
        if dom_si_prefix:
            for d in consolidation:
                if d['original_si'] and d['original_si'].startswith(dom_si_prefix):
                    q_consumer = d
                    break
        if q_consumer is None:
            q_consumer = consolidation[0]

    # Candidate bridge source wires = the most-frequent specific .SE / .SI within the cluster
    se_specific = Counter(d['original_se'] for d in consolidation if d['original_se'])
    bridge_source_se = se_specific.most_common(1)[0][0] if se_specific else None
    si_in_cluster = [d['original_si'] for d in consolidation if d['original_si']]
    si_specific = Counter(si_in_cluster)
    bridge_source_si = si_specific.most_common(1)[0][0] if si_specific else None

    out = {
        'sibling_module':              args.sibling_mod,
        'netlist':                     args.netlist,
        'dff_count_in_sibling':        len(dffs),
        'dominant_se_cluster_prefix':  dom_se_prefix,
        'dominant_se_cluster_size':    se_clusters[dom_se_prefix],
        'consolidation_target_dffs':   [d['instance_name'] for d in consolidation],
        'consolidation_detail':        consolidation,
        'anchor_dff':                  anchor['instance_name'] if anchor else None,
        'q_consumer_dff':              q_consumer['instance_name'] if q_consumer else None,
        'q_consumer_original_si':      q_consumer['original_si'] if q_consumer else None,
        'candidate_bridge_source_se':  bridge_source_se,
        'candidate_bridge_source_si':  bridge_source_si,
    }
    Path(args.output).write_text(json.dumps(out, indent=2))

    print('ECO_RPT_GENERATED: bridge_pick → ' + args.output)
    print(f'  sibling_module: {args.sibling_mod}')
    print(f'  total DFFs:     {len(dffs)}')
    print(f'  consolidation:  {len(consolidation)} DFFs (cluster prefix={dom_se_prefix!r})')
    print(f'  anchor_dff:     {anchor["instance_name"] if anchor else "(none)"}')
    print(f'  q_consumer:     {q_consumer["instance_name"] if q_consumer else "(none)"}')
    print(f'  bridge SE src:  {bridge_source_se}')
    print(f'  bridge SI src:  {bridge_source_si}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
