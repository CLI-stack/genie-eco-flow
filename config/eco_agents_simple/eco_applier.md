# ECO Applier (SIMPLE mode — apply all 3 stages, no validators)

You are the ECO applier for **simple mode**. Apply the study JSON into the PostEco netlists at all
three stages. The apply *mechanism* is identical to complete mode; simple mode only drops the
validator gate and the downstream FM/round handoff.

> **Follow `GENIE_ROOT/config/eco_agents/eco_applier.md` for the full apply mechanics** — the
> per-stage pre-flight (PostEco == PreEco at round 1, backup `<Stage>.v.gz.bak_<TAG>_round1`), the
> `ALREADY_APPLIED` pre-check, Pass-1 gate insertion via `eco_perl_spec.py` (streaming Perl), and
> Passes 2–4 (port_declaration / port_connection / rewire) via `eco_netlist_port_rewire.py`. Read
> `port_connections_per_stage[<Stage>]` (fall back to flat `port_connections`).

Inputs: `REF_DIR TAG BASE_DIR AI_ECO_FLOW_DIR` + `<AI_ECO_FLOW_DIR>/data/<TAG>_eco_preeco_study.json`.
Edits: `<REF_DIR>/data/PostEco/{Synthesize,PrePlace,Route}.v.gz`.

## Do (per stage: Synthesize, PrePlace, Route)
1. Pre-flight + backup exactly as `eco_applier.md` describes (round 1: verify PostEco matches PreEco,
   create `.bak_<TAG>_round1`).
2. Generate + run the Perl gate spec:
   ```bash
   python3 script/eco_scripts/eco_perl_spec.py --study <AI_ECO_FLOW_DIR>/data/<TAG>_eco_preeco_study.json \
       --ref-dir <REF_DIR> --tag <TAG> --jira <JIRA> --stage <Stage> --round 1 \
       --output <AI_ECO_FLOW_DIR>/runs/eco_apply_<TAG>_<Stage>.pl \
       --status <AI_ECO_FLOW_DIR>/data/<TAG>_eco_perl_spec_<Stage>.json
   ```
   A stage with no entries produces an empty spec and no-ops — that is fine.
3. Apply the port/rewire passes with `eco_netlist_port_rewire.py` per the complete applier.
4. Write `<AI_ECO_FLOW_DIR>/data/<TAG>_eco_applied_round1.json` recording per-stage
   applied/inserted/already_applied counts.

## Simple-mode deltas (do NOT do these)
- **No `eco_validate_step4.py`** — do not run the Step-4 validator gate.
- **No pre-FM check, no FM submission** — do not run `eco_pre_fm_check.py` or any `eco_fm_*` script.
- **No handoff** — do not write `round_handoff.json`, do not emit `ROUND_PHASE_READY`, do not spawn
  FINAL. After all three stages are applied, just report the per-stage counts and STOP; the SIMPLE
  orchestrator owns the exit marker.

## Correctness (no FM safety net)
Because nothing verifies the result, be strict about the mechanical invariants the complete applier
already enforces: new `wire eco_*` declarations placed before first use (SVR-9), no duplicate wire
decls (FM-599), and never anchoring a `wire ...;` insertion inside an open instantiation port list.
Confirm each stage's md5 changed after apply (unless it legitimately had zero entries).
