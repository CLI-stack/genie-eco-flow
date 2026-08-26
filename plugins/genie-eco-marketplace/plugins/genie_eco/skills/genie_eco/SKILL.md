---
description: Use when the user asks to run, analyze, or drive an ECO for a TileBuilder tile ("analyze eco", "run eco", "eco flow for <tile> <jira>"). Launches the Genie AI ECO phase flow.
---

# Genie AI ECO Flow

Drives the Genie AI ECO flow end to end for a single RTL change: from an RTL diff to a
Formality-verified, per-stage (Synthesize / PrePlace / Route) gate-level netlist ECO.

## What it does
A multi-phase state machine with hard gates:
- **STUDY** (Steps 1-3): RTL diff analysis -> Step-2 fenets (FM find_equivalent_nets, per-stage net
  resolution) -> Step-3 netlist study (gate emission + validators + functional precheck).
- **APPLY** (Steps 4-6): apply the study to the netlist -> pre-FM checks -> Formality verification.
- **ROUND**: on FM failure, analyze failing points, re-study only the failing entries, re-apply, re-FM
  (up to 10 rounds).
- **FINAL**: summary + email.

Between phases, two spawn-level gates must pass before APPLY: the Step-3 validator
(`eco_validate_step3.json`, structural completeness) AND the functional precheck
(`eco_functional_precheck.json`, independent netlist-sim oracle).

## How to invoke
Preferred: the slash command **`/eco-analyze <ref_dir> <tile> <jira>`**.
That validates inputs, emits the analyze signal, and hands the phase machine to the
`eco_orchestrator` agent (both provided by this plugin).

## Architecture (thin launcher)
This plugin ships only the command + orchestrator agent. The 62 ECO scripts and 13 sub-agent
definitions run in place from the genie_agent repo at:
```
/home/abinbaba/eco_flow
```
It also relies on that repo's PD environment (TileBuilder / Formality / LSF, `genie_cli.py`,
per-user `users/$USER/` layout). It is NOT a standalone/portable ECO tool — it launches the
existing flow.
