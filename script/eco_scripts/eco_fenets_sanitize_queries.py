#!/usr/bin/env python3
"""
eco_fenets_sanitize_queries.py — Collapse duplicate scope components in the
Step 2 net-query plan before submitting it to FM.

Single rule: `umccmd/umccmd/IReset` → `umccmd/IReset`. Agents sometimes
prefix a `scope` field to a `net_path` that already contains that scope;
the duplicate prefix makes FM return FM-036 every time.

Other quality issues (UNCONNECTED placeholders, hallucinated port names,
bus-bit expansion) are handled by the agent prompt in
`config/eco_agents/eco_fenets_runner.md` STEP A — see that file for the
contract.

Usage:
    python3 eco_fenets_sanitize_queries.py \\
        --queries-in   data/<TAG>_eco_fenets_queries_raw.json \\
        --queries-out  data/<TAG>_eco_fenets_queries.json
"""
import argparse, json, sys
from pathlib import Path


def collapse_dup_scope(net_path):
    """`umccmd/umccmd/IReset` → `umccmd/IReset`. Returns (clean_path, fired_bool)."""
    parts = net_path.split('/')
    out = []
    for p in parts:
        if out and p == out[-1]:
            continue
        out.append(p)
    new = '/'.join(out)
    return new, (new != net_path)


def sanitize(queries):
    kept = []
    fired = 0
    for q in queries:
        net_path = q.get('net_path') or ''
        clean, did = collapse_dup_scope(net_path)
        if did:
            fired += 1
            q = dict(q, net_path=clean, sanitize_note='DUP_SCOPE_COLLAPSED')
        kept.append(q)
    return kept, fired


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--queries-in',  required=True)
    p.add_argument('--queries-out', required=True)
    args = p.parse_args()

    queries = json.loads(Path(args.queries_in).read_text())
    if isinstance(queries, dict) and 'queries' in queries:
        queries = queries['queries']
    kept, fired = sanitize(queries)
    Path(args.queries_out).write_text(json.dumps(kept, indent=2))

    # Marker file proves the script actually ran (not just that queries.json
    # exists). Validators can check for this marker to enforce the orchestrator
    # invoked the deterministic sanitize step rather than the agent producing
    # queries.json by other means.
    import datetime
    marker_path = args.queries_out.replace('.json', '_sanitize_marker.txt')
    Path(marker_path).write_text(
        f'ECO_FENETS_SANITIZE_RAN\n'
        f'timestamp:        {datetime.datetime.now().isoformat()}\n'
        f'queries_in:       {args.queries_in}\n'
        f'queries_out:      {args.queries_out}\n'
        f'queries_count:    {len(queries)}\n'
        f'dup_scope_fixed:  {fired}\n'
    )

    print(f'ECO_RPT_GENERATED: sanitized queries → {args.queries_out}')
    print(f'  in:               {len(queries)}')
    print(f'  dup_scope_fixed:  {fired}')
    print(f'  marker:           {marker_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
