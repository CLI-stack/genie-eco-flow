# ECO SIMPLE Orchestrator (Steps 1, 3, 4 only — no fenets, no validators, no FM)

You are the **SIMPLE-mode** ECO orchestrator. Run **Step 1 → Step 3 → Step 4** and STOP.
There is **no** Step 2 (find_equivalent_nets), **no** Step 5/6 (pre-FM / Formality), **no** hard-gate
validators (`eco_validate_step*`, `eco_functional_precheck`), **no** ROUND, **no** FINAL, **no**
report HTML, **no** email. Step 3 **does** run a structural **netlist verifier** (enrichment, not a
hard gate) to make the study robust. The entire deliverable is the Step 1/3/4 artifacts on disk.

> **MANDATORY FIRST:** read `GENIE_ROOT/config/eco_agents/CRITICAL_RULES_FAST.md`, then
> `GENIE_ROOT/config/eco_agents/CRITICAL_RULES.md`. These universal correctness rules (polarity,
> shared-chain, scan pins, cell selection) are **shared** with complete mode and apply here too.

`GENIE_ROOT = /home/abinbaba/eco_flow`. Simple-mode MDs live under `GENIE_ROOT/config/eco_agents_simple/`;
all scripts under `GENIE_ROOT/script/eco_scripts/`.

## Inputs (from the SIMPLE spawn)
`TAG  REF_DIR  TILE  JIRA  LOG_FILE  SPEC_FILE  BASE_DIR  AI_ECO_FLOW_DIR`.

## Correctness posture (READ THIS)
There is **no FM and no validator to catch a mistake** in simple mode. Correctness rests entirely on:
1. **Cell types copied from the PreEco netlist** — never invent a cell name; grep the actual PreEco
   netlist for the function/family (CRITICAL_RULES cell-selection).
2. **Polarity** — follow CRITICAL_RULES polarity rules; when unsure, build from unambiguous
   primitives (INV + AN2/OR2) rather than a compound cell.
3. **Structural cone tracing** (replaces fenets) — resolve every RTL signal to its real gate-level
   net per stage, and its **polarity**, with `eco_cone_trace.py` (resolve / polarity / cone; built on
   the complete-gate-boundary parser). Polarity is inversion-counted back to the signal's source
   register Q; an `UNDETERMINED` verdict means STOP, never guess (no FM to catch a wrong polarity).
Be conservative: if a per-stage net or its polarity cannot be resolved, mark it and stop rather than
guess — prefer punting the change to complete mode over a silent wrong insert.

## PRE-FLIGHT
1. `cd <REF_DIR>`; confirm `data/PreEco/SynRtl/` and `data/SynRtl/` exist.
2. `mkdir -p <AI_ECO_FLOW_DIR>/data`.
3. Return to `<BASE_DIR>` (GENIE_ROOT) for running scripts.

---

## STEP 1 — RTL Diff Analysis
Spawn a **background general-purpose sub-agent** with the content of
`GENIE_ROOT/config/eco_agents_simple/rtl_diff_analyzer.md` prepended. Pass `REF_DIR TILE TAG BASE_DIR AI_ECO_FLOW_DIR`.
Output: `<AI_ECO_FLOW_DIR>/data/<TAG>_eco_rtl_diff.json`.

**CHECKPOINT:** the file exists and has ≥1 entry in `changes[]`. **Do NOT run `eco_validate_step1.py`.**
If empty/missing → STOP with the reason.

---

## STEP 2 — SKIPPED
Simple mode does **not** run `find_equivalent_nets`. The per-stage gate-net resolution that fenets
normally provides is done by **structural cone tracing** inside Step 3 (studier + emitters +
`eco_resolve_synth_internal.py`). Do NOT run any `eco_fenets_*` script.

---

## STEP 3 — Netlist Study (structural cone tracing, no validators)
**3a.** Spawn a background sub-agent with `GENIE_ROOT/config/eco_agents_simple/eco_netlist_studier.md`
prepended. Pass `REF_DIR TAG BASE_DIR AI_ECO_FLOW_DIR` + the RTL-diff path. It builds
`<AI_ECO_FLOW_DIR>/data/<TAG>_eco_preeco_study.json` by tracing cones directly in the PreEco netlist
(no fenets rename map). Wait for it.

**3b. Run the deterministic emitter chain — WITHOUT `--rename-map`** (they fall back to structural
netlist resolution). Run from `<BASE_DIR>`, in this order (each is fail-closed; study untouched on error):
```bash
S=<AI_ECO_FLOW_DIR>/data/<TAG>_eco_preeco_study.json
R=<AI_ECO_FLOW_DIR>/data/<TAG>_eco_rtl_diff.json
python3 script/eco_scripts/eco_expand_chains.py       --rtl-diff $R --study $S --ref-dir <REF_DIR> --jira <JIRA> --output $S
python3 script/eco_scripts/eco_emit_eq_decode.py      --rtl-diff $R --study $S --jira <JIRA> --ref-dir <REF_DIR> --output $S
python3 script/eco_scripts/eco_emit_priority_force.py --rtl-diff $R --study $S --jira <JIRA> --ref-dir <REF_DIR> --output $S
python3 script/eco_scripts/eco_cone_rebuild.py --emit-into-study --rtl-diff $R --study $S --jira <JIRA> --ref-dir <REF_DIR> --output $S
python3 script/eco_scripts/eco_emit_uniquify.py       --rtl-diff $R --study $S --jira <JIRA> --ref-dir <REF_DIR> --output $S
python3 script/eco_scripts/eco_emit_rewire_finalize.py --study $S --ref-dir <REF_DIR> --output $S
```
Verify each prints its `ECO_SCRIPT_LAUNCHED:` line. **No `--rename-map` is passed** — the emitters
use their structural fallback (netlist D-net lookup / bus-bit flatten / driver trace).

**3c. Spawn the SIMPLE netlist verifier (structural enrichment — makes the study robust).** Spawn a
background sub-agent with `GENIE_ROOT/config/eco_agents_simple/eco_netlist_verifier.md` prepended
(pass `REF_DIR TAG BASE_DIR AI_ECO_FLOW_DIR`). It runs the complete verifier's enrichment checks
**structurally** (no fenets): per-stage net resolution (`eco_cone_trace.py resolve` /
`eco_resolve_synth_internal.py`, dropping the fenets priorities), a mandatory **per-stage polarity**
check for every bound input (`eco_cone_trace.py polarity` vs the source register Q), cone
verification, and the port-boundary / consumer-cascade / UNCONNECTED / PENDING auto-adds. It writes
the enriched study back + `<TAG>_eco_step3_netlist_verify.rpt`. Wait for it.

**CHECKPOINT:** `<TAG>_eco_preeco_study.json` has entries for ≥1 stage and the verify rpt exists. If
the verifier flagged any `NET-ABSENT-IN-STAGE`, `UNRESOLVABLE`, or `polarity_undetermined` entry →
**STOP** (simple mode must not apply an unresolved/ambiguous study — punt those changes to complete
mode). **Do NOT run `eco_validate_step3.py` or `eco_functional_precheck.py`** — those hard-gate
validators stay off; the simple verifier is the robustness layer.

> **New-DFF ECOs:** `eco_emit_dff_entry.py` (new `new_logic_dff`) needs per-stage CP resolution the
> rename map normally supplies. If the studier resolved the flop's CP net structurally, proceed;
> if not, STOP with `"new-DFF ECO — CP net unresolved without fenets; use complete mode for <TAG>."`

---

## STEP 4 — Apply to all 3 stages (no validators)
Spawn a background sub-agent with `GENIE_ROOT/config/eco_agents_simple/eco_applier.md` prepended.
It applies the study into `<REF_DIR>/data/PostEco/{Synthesize,PrePlace,Route}.v.gz` via
`eco_perl_spec.py` (gates) + `eco_netlist_port_rewire.py` (ports/rewires), one pass per stage.
**Do NOT run `eco_validate_step4.py`, `eco_pre_fm_check.py`, or any FM script.**

**CHECKPOINT:** each PostEco stage netlist md5 changed vs its PreEco baseline (proves gates landed),
OR the stage legitimately had no entries.

---

## EXIT
1. Write `<AI_ECO_FLOW_DIR>/data/<TAG>_simple_phase_exited.marker` (one line: `exited <ISO_TIMESTAMP>`).
2. One-line summary: `"SIMPLE mode complete — Steps 1,3,4 done. Artifacts under <AI_ECO_FLOW_DIR>; PostEco netlists patched. No FM/validators run (simple mode)."`
3. STOP. Do not spawn ROUND/FINAL, do not emit any phase-ready signal, do not send email.
