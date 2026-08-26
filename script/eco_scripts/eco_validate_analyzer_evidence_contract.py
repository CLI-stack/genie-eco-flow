#!/usr/bin/env python3
"""eco_validate_analyzer_evidence_contract.py — Pre-FM gate validator.

Verifies every actionable revised_change in eco_fm_analysis_round<N>.json
carries a compliant evidence_for_studier block per:
  config/eco_agents/eco_re_studier_evidence_contract.md

Failure modes:
- Universal block missing required fields
- Per-action required fields missing (per contract §2)
- evidence_path_refs do not resolve in evidence_walk_json or xstage_compare_json
- pp_route_match=false for high-applicability bridge recipes (GAP-4b)

Exit code:
  0 — all entries comply
  1 — at least one violation; emit error JSON listing all
  2 — analysis JSON itself missing/malformed

Usage:
    python3 script/eco_scripts/eco_validate_analyzer_evidence_contract.py \\
        --analysis-json data/<TAG>_eco_fm_analysis_round<N>.json \\
        [--strict]   # non-strict mode emits WARN instead of FAIL
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


# Actions that DO NOT require evidence_for_studier
EXEMPT_ACTIONS = {"cascade_verified_skip", "manual_only"}

UNIVERSAL_REQUIRED = [
    "failing_pin",
    "failing_pin_load_bearing",
    "first_divergent_point",
    "candidate_fix_recipes",
    "constraints",
]

FIRST_DIVERGENT_REQUIRED = [
    "kind",
    "what",
    "evidence_path_refs",
]

VALID_DIVERGENT_KINDS = {
    "undriven_cut", "cts_rename", "blackbox", "wrong_gate",
    "missing_port", "bridge_gap", "se_not_consolidated",
    "wrong_polarity", "cell_not_in_lib", "other",
}

CONSTRAINTS_REQUIRED = ["scope_module"]   # scope_module mandatory; do_not_* optional

# Per-action required fields inside required_inputs_for_studier (per contract §2)
PER_ACTION_REQUIRED = {
    "fix_scan_stitching": [
        ("scan_stitching_via_bridge_port", [
            "host_module", "host_dff_instance",
            "bridge_port_names", "parent_module", "parent_bridge_wires",
            "sibling_module_for_buffer", "sibling_bridge_ports",
            "sibling_buffer_source_se", "sibling_buffer_source_si",
            "sibling_se_consolidation_targets", "sibling_q_consumer",
        ]),
        ("scan_stitching_via_constant_zero", [
            "host_dff_instance", "stages_to_apply",
        ]),
    ],
    "fix_named_wire": [
        ("rename_to_named_wire", [
            "gate_instance", "input_pin", "source_net",
            "new_named_wire", "host_module", "stage_scope",
            "submodule_blackboxed", "port_bus_pattern",
        ]),
    ],
    "move_gate_to_submodule": [
        ("move_gate_to_submodule", [
            "gate_instance", "preferred_insertion_scope",
            "submodule_type", "new_output_port_name",
            "new_port_declaration_type", "gate_chain_to_move",
            "parent_dff_d_input_rewire_to",
        ]),
    ],
    "try_alternative_pivot": [
        ("try_alternative_pivot", [
            "current_pivot", "max_hops_back",
            "candidate_alternative_pivots",
        ]),
    ],
    "try_structural_insertion": [
        ("try_structural_insertion", [
            "host_module", "candidate_anchor_gates",
            "new_condition_signal", "forbidden_gate_types",
        ]),
    ],
    "invert_cmux_constants": [
        ("invert_cmux_constants", [
            "pivot_net", "c_mux_instances", "constants_to_flip",
        ]),
    ],
    "force_port_decl": [
        ("force_reapply_port_decl", [
            "signal_name", "module_name", "declaration_type",
            "stage_scope", "force_reapply",
        ]),
    ],
    "fix_cell_type": [
        ("fix_cell_type", [
            "gate_instance", "wrong_cell_type", "missing_pin",
            "gate_function", "candidate_correct_cell_types",
        ]),
    ],
    "swap_compound_cell": [
        ("swap_compound_cell", [
            "instance_name", "wrong_cell_type", "correct_cell_type",
        ]),
    ],
    "update_gate_function": [
        ("update_gate_function", [
            "gate_instance", "wrong_gate_function",
            "correct_gate_function",
        ]),
    ],
    # actions without specific recipe schema enforcement (universal block only)
    "rewire": [],
    "exclude": [],
    "force_wire_decl_reapply": [],
    "rerun_fenets": [],
    "structural_trace": [],
    "scan_chain_tune": [],
    "fix_netlist_syntax": [],
    "remove_svf_entry": [],
    "rewire_cp": [],
    "rewire_gate_input": [],
    "tune_file_update": [],
    "conservative_constant": [],
    "re_study_and_term": [],
}


def jsonpath_resolves(path: str, doc: dict) -> bool:
    """Lightweight JSONPath dereference. Supports dot + [idx] only."""
    if not path:
        return False
    parts = re.findall(r"[^.\[\]]+|\[\d+\]", path)
    cur: Any = doc
    for p in parts:
        if p.startswith("[") and p.endswith("]"):
            try:
                idx = int(p[1:-1])
                cur = cur[idx]
            except (TypeError, KeyError, IndexError):
                return False
        elif isinstance(cur, dict):
            if p not in cur:
                return False
            cur = cur[p]
        else:
            return False
    return True


def validate_universal_block(e4s: dict, ctx: str) -> list[str]:
    """Validate the universal evidence_for_studier fields. Returns list of violation strings."""
    violations: list[str] = []
    for f in UNIVERSAL_REQUIRED:
        if f not in e4s:
            violations.append(f"{ctx}: missing universal field '{f}'")

    fdp = e4s.get("first_divergent_point", {})
    for f in FIRST_DIVERGENT_REQUIRED:
        if f not in fdp:
            violations.append(f"{ctx}: first_divergent_point missing '{f}'")
    if fdp.get("kind") not in VALID_DIVERGENT_KINDS:
        violations.append(f"{ctx}: invalid first_divergent_point.kind={fdp.get('kind')!r}")

    recipes = e4s.get("candidate_fix_recipes", [])
    if not isinstance(recipes, list) or len(recipes) == 0:
        violations.append(f"{ctx}: candidate_fix_recipes must be non-empty list")
    else:
        for i, r in enumerate(recipes):
            for rf in ("kind", "applicability_score", "required_inputs_for_studier", "verification_after_fix"):
                if rf not in r:
                    violations.append(f"{ctx}: recipe[{i}] missing '{rf}'")
            score = r.get("applicability_score")
            if not isinstance(score, (int, float)) or not (0 <= score <= 1):
                violations.append(f"{ctx}: recipe[{i}].applicability_score must be in [0,1], got {score}")

    constraints = e4s.get("constraints", {})
    for f in CONSTRAINTS_REQUIRED:
        if f not in constraints:
            violations.append(f"{ctx}: constraints missing '{f}'")

    return violations


def validate_per_action(action: str, e4s: dict, ctx: str) -> list[str]:
    """Validate per-action required fields inside required_inputs_for_studier."""
    violations: list[str] = []
    schemas = PER_ACTION_REQUIRED.get(action)
    if schemas is None:
        # action not in our registry — flag as warn but not error
        violations.append(f"{ctx}: action '{action}' has no per-action schema (PER_ACTION_REQUIRED)")
        return violations
    if not schemas:
        # explicitly empty — no per-action validation needed
        return violations

    recipes = e4s.get("candidate_fix_recipes", [])
    for i, r in enumerate(recipes):
        kind = r.get("kind")
        # Find matching schema
        matching = None
        for sk, sf in schemas:
            if sk == kind:
                matching = sf
                break
        if matching is None:
            # recipe kind not in schema — informational
            continue
        rin = r.get("required_inputs_for_studier", {})
        if not isinstance(rin, dict):
            violations.append(f"{ctx}: recipe[{i}] required_inputs_for_studier must be object")
            continue
        for f in matching:
            if f not in rin:
                violations.append(f"{ctx}: recipe[{i}] ({kind}) required_inputs_for_studier missing '{f}'")

    return violations


def validate_bridge_constraints(e4s: dict, ctx: str) -> list[str]:
    """GAP-4b enforcement: scan_stitching_via_bridge_port must have pp_route_match=true
    when applicability_score >= 0.9."""
    violations: list[str] = []
    for i, r in enumerate(e4s.get("candidate_fix_recipes", [])):
        if r.get("kind") != "scan_stitching_via_bridge_port":
            continue
        score = r.get("applicability_score", 0)
        if score < 0.9:
            continue
        rin = r.get("required_inputs_for_studier", {})
        for src_field in ("sibling_buffer_source_se", "sibling_buffer_source_si"):
            src = rin.get(src_field)
            if not isinstance(src, dict):
                continue
            if src.get("pp_route_match") is not True:
                violations.append(
                    f"{ctx}: GAP-4b — recipe[{i}] {src_field}.pp_route_match must be true "
                    f"(score={score} >= 0.9 implies high-confidence bridge)"
                )
        # GAP-4c: q_consumer must be populated for high-confidence bridge
        if rin.get("sibling_q_consumer") in (None, {}):
            violations.append(
                f"{ctx}: GAP-4c — recipe[{i}] sibling_q_consumer must be populated for high-confidence bridge"
            )
    return violations


def validate_evidence_refs(e4s: dict, ctx: str,
                           evidence_doc: dict | None,
                           xstage_doc: dict | None) -> list[str]:
    """Check that evidence_path_refs resolve in evidence_walk_json + xstage_compare_json."""
    violations: list[str] = []
    refs = e4s.get("first_divergent_point", {}).get("evidence_path_refs", [])
    if not isinstance(refs, list):
        return violations
    for ref in refs:
        if not isinstance(ref, str):
            continue
        # Strip leading "evidence." or "xstage." prefix
        if ref.startswith("evidence."):
            doc = evidence_doc
            sub = ref[len("evidence."):]
        elif ref.startswith("xstage."):
            doc = xstage_doc
            sub = ref[len("xstage."):]
        else:
            violations.append(f"{ctx}: evidence_path_ref must start with 'evidence.' or 'xstage.': {ref!r}")
            continue
        if doc is None:
            # source doc missing — soft error
            violations.append(f"{ctx}: cannot validate ref {ref!r} (source doc not loaded)")
            continue
        if not jsonpath_resolves(sub, doc):
            violations.append(f"{ctx}: evidence_path_ref does not resolve: {ref!r}")
    return violations


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--analysis-json", required=True)
    p.add_argument("--output", default=None,
                   help="Optional violation report JSON (default: <analysis_json>.contract_check.json)")
    p.add_argument("--strict", action="store_true",
                   help="Treat warnings as errors (transition mode default = lenient)")
    p.add_argument("--ai-eco-flow-dir", default=None,
                   help="If set, also write companion .rpt summary to this dir")
    p.add_argument("--tag", default=None, help="Tag for RPT file naming (required if --ai-eco-flow-dir set)")
    p.add_argument("--round", type=int, default=None, help="Round for RPT file naming")
    args = p.parse_args()

    analysis_path = Path(args.analysis_json)
    if not analysis_path.exists():
        print(f"FAIL: analysis JSON not found: {analysis_path}", file=sys.stderr)
        return 2
    try:
        analysis = json.loads(analysis_path.read_text())
    except json.JSONDecodeError as e:
        print(f"FAIL: malformed analysis JSON: {e}", file=sys.stderr)
        return 2

    # Load evidence + xstage docs for path-ref validation (best-effort)
    es = analysis.get("evidence_summary", {})
    evidence_doc = None
    xstage_doc = None
    if es.get("evidence_walk_json") and Path(es["evidence_walk_json"]).exists():
        try:
            evidence_doc = json.loads(Path(es["evidence_walk_json"]).read_text())
        except Exception:
            pass
    if es.get("xstage_compare_json") and Path(es["xstage_compare_json"]).exists():
        try:
            xstage_doc = json.loads(Path(es["xstage_compare_json"]).read_text())
        except Exception:
            pass

    revised = analysis.get("revised_changes", [])
    all_violations: list[dict] = []

    # -----------------------------------------------------------------------
    # SCRIPT-RUN INTEGRITY CHECKS (must pass before per-change validation)
    # Ensures eco_fm_evidence_walk.py and eco_fm_xstage_compare.py were
    # actually executed — not hand-written by the agent.
    # -----------------------------------------------------------------------

    # Check 1: evidence walk JSON must have 'per_target' key (script signature).
    # Agent-written versions typically use simplified flat structure without this.
    if evidence_doc is not None:
        if "per_target" not in evidence_doc:
            all_violations.append({
                "ctx": "evidence_walk_json",
                "violation": (
                    "SCRIPT_NOT_RUN: eco_fm_evidence_walk.py was NOT executed. "
                    "JSON missing required 'per_target' key — agent wrote its own JSON. "
                    "Re-run: python3 script/eco_scripts/eco_fm_evidence_walk.py --tag <TAG> ..."
                )
            })
        else:
            # Check 2: per_target failing_count must match eco_fm_verify.json counts
            fm_verify_path = analysis_path.parent / f"{analysis_path.stem.split('_eco_fm_analysis')[0]}_eco_fm_verify.json"
            if fm_verify_path.exists():
                try:
                    fm_verify = json.loads(fm_verify_path.read_text())
                    for tgt, tgt_data in evidence_doc.get("per_target", {}).items():
                        fd = tgt_data.get("failing_diagnostics", {})
                        evidence_count = fd.get("failing_count", 0)
                        verify_count = fm_verify.get(tgt, {}).get("failing_count", 0) if isinstance(fm_verify.get(tgt), dict) else 0
                        if verify_count > 0 and evidence_count == 0:
                            all_violations.append({
                                "ctx": f"evidence_walk_json.per_target.{tgt}",
                                "violation": (
                                    f"INCOMPLETE_EVIDENCE: {tgt} has {verify_count} failing points "
                                    f"in eco_fm_verify.json but 0 dossiers in evidence walk. "
                                    f"eco_fm_evidence_walk.py did not parse __failing_points.rpt.gz correctly."
                                )
                            })
                except Exception:
                    pass

    # Check 3: xstage JSON must have 'per_failing_dff' key (script signature).
    # Agent-written versions use 'dff_deltas' (a list) — different structure.
    if xstage_doc is not None:
        if "per_failing_dff" not in xstage_doc:
            all_violations.append({
                "ctx": "xstage_compare_json",
                "violation": (
                    "SCRIPT_NOT_RUN: eco_fm_xstage_compare.py was NOT executed. "
                    "JSON missing required 'per_failing_dff' key "
                    f"(found keys: {list(xstage_doc.keys())[:6]}). "
                    "Agent wrote its own simplified JSON instead of running the script. "
                    "Re-run: python3 script/eco_scripts/eco_fm_xstage_compare.py --tag <TAG> ..."
                )
            })
        else:
            # Check 4: per_failing_dff must contain at least the ECO-specific failing DFFs
            eco_pattern = re.compile(r"eco_\d+_", re.I)
            failing_dffs = xstage_doc.get("per_failing_dff", {})
            if len(failing_dffs) == 0 and xstage_doc.get("loop_verdict") == "ADVANCE_NEXT_ROUND":
                all_violations.append({
                    "ctx": "xstage_compare_json",
                    "violation": (
                        "EMPTY_XSTAGE: per_failing_dff is empty but loop_verdict=ADVANCE_NEXT_ROUND. "
                        "eco_fm_xstage_compare.py produced no DFF comparisons — check evidence walk dossiers."
                    )
                })

    for i, change in enumerate(revised):
        action = change.get("action")
        if action in EXEMPT_ACTIONS:
            continue
        ctx = f"revised_changes[{i}] action={action!r} cell={change.get('cell_name','?')!r}"

        e4s = change.get("evidence_for_studier")
        if e4s is None:
            all_violations.append({"ctx": ctx, "violation": "MISSING evidence_for_studier block"})
            continue

        violations = []
        violations += validate_universal_block(e4s, ctx)
        violations += validate_per_action(action, e4s, ctx)
        violations += validate_bridge_constraints(e4s, ctx)
        violations += validate_evidence_refs(e4s, ctx, evidence_doc, xstage_doc)

        for v in violations:
            all_violations.append({"ctx": ctx, "violation": v})

    out_path = Path(args.output) if args.output else analysis_path.with_suffix(".contract_check.json")
    output_doc = {
        "analysis_json": str(analysis_path),
        "loop_verdict": analysis.get("loop_verdict"),
        "round": analysis.get("round"),
        "actionable_changes": sum(1 for c in revised if c.get("action") not in EXEMPT_ACTIONS),
        "violations": all_violations,
        "violation_count": len(all_violations),
        "compliant": len(all_violations) == 0,
        "strict": args.strict,
    }
    out_path.write_text(json.dumps(output_doc, indent=2))

    # Companion RPT
    if args.ai_eco_flow_dir and args.tag and args.round is not None:
        rpt_path = Path(args.ai_eco_flow_dir) / f"{args.tag}_eco_step6_evidence_contract_check_round{args.round}.rpt"
        rpt_path.parent.mkdir(parents=True, exist_ok=True)
        sep = "=" * 80
        rpt_lines = [sep,
                     f"STEP 6 — Analyzer Evidence Contract Check (Round {args.round})",
                     f"TAG={args.tag}  |  loop_verdict={output_doc.get('loop_verdict','?')}  |  strict={args.strict}",
                     sep,
                     f"Actionable changes:  {output_doc['actionable_changes']}",
                     f"Violations:          {output_doc['violation_count']}",
                     f"Compliant:           {output_doc['compliant']}",
                     ""]
        if all_violations:
            rpt_lines.append("--- Violations ---")
            for v in all_violations[:50]:
                rpt_lines.append(f"  {v['ctx']}")
                rpt_lines.append(f"    → {v['violation']}")
            if len(all_violations) > 50:
                rpt_lines.append(f"  ... + {len(all_violations) - 50} more (see {out_path})")
        else:
            rpt_lines.append("All revised_changes comply with evidence contract.")
        rpt_lines += ["", f"JSON: {out_path}", sep, ""]
        rpt_path.write_text("\n".join(rpt_lines))
        print(f"ECO_RPT_GENERATED: rpt → {rpt_path}")

    if all_violations:
        print(f"CONTRACT VIOLATIONS ({len(all_violations)}):")
        for v in all_violations[:20]:
            print(f"  {v['ctx']}")
            print(f"    → {v['violation']}")
        if len(all_violations) > 20:
            print(f"  ... + {len(all_violations) - 20} more (see {out_path})")
        if args.strict:
            return 1
        else:
            print(f"WARN: contract not enforced strictly (re-run with --strict to fail)")
            return 0
    else:
        print(f"OK: all {len(revised)} revised_changes comply with evidence contract")
        return 0


if __name__ == "__main__":
    sys.exit(main())
